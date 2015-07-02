/*
 * All of this (other than find_oper()) is stolen from the backend code; mostly
 * backend/parser/parse_oper.c.
 */

#include "postgres.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"

#include "access/htup.h"
#include "access/htup_details.h"
#include "catalog/pg_operator.h"
#include "catalog/pg_type.h"
#include "parser/parse_func.h"
#include "utils/syscache.h"
#include "utils/lsyscache.h"
#include "utils/typcache.h"
#include "utils/inval.h"
#include "utils/hsearch.h"

#define MAX_CACHED_PATH_LEN		16

typedef struct OprCacheKey
{
	char		oprname[NAMEDATALEN];
	Oid			left_arg;		/* Left input OID, or 0 if prefix op */
	Oid			right_arg;		/* Right input OID, or 0 if postfix op */
	Oid			search_path[MAX_CACHED_PATH_LEN];
} OprCacheKey;

typedef struct OprCacheEntry
{
	/* the hash lookup key MUST BE FIRST */
	OprCacheKey key;

	Oid			opr_oid;		/* OID of the resolved operator */
} OprCacheEntry;

/* See backend/parser/parse_oper.c */
static HTAB *OprCacheHash = NULL;

static bool oper_is_ok(Oid operOid, Oid funcOid, bool retset);
static bool make_oper_cache_key(ParseState *pstate, OprCacheKey *key, List *opname,
					Oid ltypeId, Oid rtypeId, int location);
static Oid binary_oper_exact(List *opname, Oid arg1, Oid arg2);
static Oid find_oper_cache_entry(OprCacheKey *key);
static FuncDetailCode oper_select_candidate(int nargs,
					  Oid *input_typeids,
					  FuncCandidateList candidates,
					  Oid *operOid);		/* output argument */
static void op_error(ParseState *pstate, List *op, char oprkind,
		 Oid arg1, Oid arg2,
		 FuncDetailCode fdresult, int location);
static const char * op_signature_string(List *op, char oprkind, Oid arg1, Oid arg2);
static void InvalidateOprCacheCallBack(Datum arg, int cacheid, uint32 hashvalue);

/*
 * Find a suitable operator that won't recurse back to us.
 *
 * This is stolen from oper() with some bits from make_op()
 */
Form_pg_operator
find_oper(Oid funcOid, OpExpr *op_expr, Oid ltypeId, Oid rtypeId, bool retset, Oid rettype)
{
	ParseState			*pstate = (ParseState *) op_expr;
	Form_pg_operator	curOpForm, newOpForm;
	HeapTuple			tup;
	char				*oprname;
	List				*opname;
	OprCacheKey			key;
	bool				key_ok;
	FuncDetailCode fdresult = FUNCDETAIL_NOTFOUND;
	Oid					curOperOid, newOperOid;

	curOperOid = op_expr->opno;

	/*
	 * Figure out what our operator name is. We intentionally do NOT pull out the
	 * schema.
	 */
	tup = SearchSysCache1(OPEROID, ObjectIdGetDatum(curOperOid));
	Assert(HeapTupleIsValid(tup)); /* Better be able to find ourselves... */
	curOpForm = (Form_pg_operator) GETSTRUCT(tup);
	oprname = NameStr(curOpForm->oprname);
	opname = list_make1(makeString(oprname));

	/*
	 * Try to find the mapping in the lookaside cache. Note that since we're
	 * using custom logic we'll never put an entry in the cache.
	 */
	if(make_oper_cache_key(NULL, &key, opname, ltypeId, rtypeId, -1))
		newOperOid = find_oper_cache_entry(&key);

	/*
	 * Try for an "exact" match
	 */
	if(!OidIsValid(newOperOid))
		newOperOid = binary_oper_exact(opname, ltypeId, rtypeId);
	
	/*
	 * If we found something that's just going to come back here then keep
	 * looking.
	 */
	if (OidIsValid(newOperOid) &&
			!oper_is_ok(newOperOid, funcOid, retset))
		newOperOid = InvalidOid;

	if(!OidIsValid(newOperOid))
	{
		FuncCandidateList clist;
		
		/* TODO: Deal with prefix and postfix operators */
		clist = OpernameGetCandidates(opname, 'b', false);
		
		if (clist != NULL)
		{
			FuncCandidateList c, prev;

			/* Remove any candidates that would come back to this function */
			for (c = clist; c != NULL; c = c->next)
			{
				if(!oper_is_ok(c->oid, funcOid, retset))
				{
					prev->next = c->next;
					pfree(c);
					c = prev->next;
					continue;		/* prev mustn't advance */
				}

				prev = c;
			}

			Oid			inputOids[2];
			inputOids[0] = ltypeId;
			inputOids[1] = rtypeId;
			fdresult = oper_select_candidate(2, inputOids, clist, &newOperOid);
		}
	}

	if(OidIsValid(newOperOid))
		tup = SearchSysCache1(OPEROID, ObjectIdGetDatum(newOperOid));

	if(!HeapTupleIsValid(tup))
		op_error(pstate, opname, 'b', ltypeId, rtypeId, fdresult, op_expr->location );

	newOpForm = (Form_pg_operator) GETSTRUCT(tup);

	/* Check it's not a shell */
	if (!RegProcedureIsValid(newOpForm->oprcode))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_FUNCTION),
				 errmsg("operator is only a shell: %s",
						op_signature_string(opname,
											newOpForm->oprkind,
											newOpForm->oprleft,
											newOpForm->oprright)),
				 parser_errposition(pstate, op_expr->location)));

	return newOpForm;
}

static bool
oper_is_ok(Oid operOid, Oid funcOid, bool retset)
{
		HeapTuple	tup = SearchSysCache1(OPEROID, ObjectIdGetDatum(funcOid));
		if (HeapTupleIsValid(tup))
		{
			Form_pg_operator op = (Form_pg_operator) GETSTRUCT(tup);
			return (op->oprcode != funcOid &&
							get_func_retset(op->oprcode) == retset);
		}

		return false;
}

/*
 * make_oper_cache_key
 *		Fill the lookup key struct given operator name and arg types.
 *
 * Returns TRUE if successful, FALSE if the search_path overflowed
 * (hence no caching is possible).
 *
 * pstate/location are used only to report the error position; pass NULL/-1
 * if not available.
 */
static bool
make_oper_cache_key(ParseState *pstate, OprCacheKey *key, List *opname,
					Oid ltypeId, Oid rtypeId, int location)
{
	char	   *schemaname;
	char	   *opername;

	/* deconstruct the name list */
	DeconstructQualifiedName(opname, &schemaname, &opername);

	/* ensure zero-fill for stable hashing */
	MemSet(key, 0, sizeof(OprCacheKey));

	/* save operator name and input types into key */
	strlcpy(key->oprname, opername, NAMEDATALEN);
	key->left_arg = ltypeId;
	key->right_arg = rtypeId;

	if (schemaname)
	{
		ParseCallbackState pcbstate;

		/* search only in exact schema given */
		setup_parser_errposition_callback(&pcbstate, pstate, location);
		key->search_path[0] = LookupExplicitNamespace(schemaname, false);
		cancel_parser_errposition_callback(&pcbstate);
	}
	else
	{
		/* get the active search path */
		if (fetch_search_path_array(key->search_path,
								  MAX_CACHED_PATH_LEN) > MAX_CACHED_PATH_LEN)
			return false;		/* oops, didn't fit */
	}

	return true;
}

/* binary_oper_exact()
 * Check for an "exact" match to the specified operand types.
 *
 * If one operand is an unknown literal, assume it should be taken to be
 * the same type as the other operand for this purpose.  Also, consider
 * the possibility that the other operand is a domain type that needs to
 * be reduced to its base type to find an "exact" match.
 */
static Oid
binary_oper_exact(List *opname, Oid arg1, Oid arg2)
{
	Oid			result;
	bool		was_unknown = false;

	/* Unspecified type for one of the arguments? then use the other */
	if ((arg1 == UNKNOWNOID) && (arg2 != InvalidOid))
	{
		arg1 = arg2;
		was_unknown = true;
	}
	else if ((arg2 == UNKNOWNOID) && (arg1 != InvalidOid))
	{
		arg2 = arg1;
		was_unknown = true;
	}

	result = OpernameGetOprid(opname, arg1, arg2);
	if (OidIsValid(result))
		return result;

	if (was_unknown)
	{
		/* arg1 and arg2 are the same here, need only look at arg1 */
		Oid			basetype = getBaseType(arg1);

		if (basetype != arg1)
		{
			result = OpernameGetOprid(opname, basetype, basetype);
			if (OidIsValid(result))
				return result;
		}
	}

	return InvalidOid;
}

/*
 * find_oper_cache_entry
 *
 * Look for a cache entry matching the given key.  If found, return the
 * contained operator OID, else return InvalidOid.
 */
static Oid
find_oper_cache_entry(OprCacheKey *key)
{
	OprCacheEntry *oprentry;

	if (OprCacheHash == NULL)
	{
		/* First time through: initialize the hash table */
		HASHCTL		ctl;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(OprCacheKey);
		ctl.entrysize = sizeof(OprCacheEntry);
		ctl.hash = tag_hash;
		OprCacheHash = hash_create("Operator lookup cache", 256,
								   &ctl, HASH_ELEM | HASH_FUNCTION);

		/* Arrange to flush cache on pg_operator and pg_cast changes */
		CacheRegisterSyscacheCallback(OPERNAMENSP,
									  InvalidateOprCacheCallBack,
									  (Datum) 0);
		CacheRegisterSyscacheCallback(CASTSOURCETARGET,
									  InvalidateOprCacheCallBack,
									  (Datum) 0);
	}

	/* Look for an existing entry */
	oprentry = (OprCacheEntry *) hash_search(OprCacheHash,
											 (void *) key,
											 HASH_FIND, NULL);
	if (oprentry == NULL)
		return InvalidOid;

	return oprentry->opr_oid;
}

/* oper_select_candidate()
 *		Given the input argtype array and one or more candidates
 *		for the operator, attempt to resolve the conflict.
 *
 * Returns FUNCDETAIL_NOTFOUND, FUNCDETAIL_MULTIPLE, or FUNCDETAIL_NORMAL.
 * In the success case the Oid of the best candidate is stored in *operOid.
 *
 * Note that the caller has already determined that there is no candidate
 * exactly matching the input argtype(s).  Incompatible candidates are not yet
 * pruned away, however.
 */
static FuncDetailCode
oper_select_candidate(int nargs,
					  Oid *input_typeids,
					  FuncCandidateList candidates,
					  Oid *operOid)		/* output argument */
{
	int			ncandidates;

	/*
	 * Delete any candidates that cannot actually accept the given input
	 * types, whether directly or by coercion.
	 */
	ncandidates = func_match_argtypes(nargs, input_typeids,
									  candidates, &candidates);

	/* Done if no candidate or only one candidate survives */
	if (ncandidates == 0)
	{
		*operOid = InvalidOid;
		return FUNCDETAIL_NOTFOUND;
	}
	if (ncandidates == 1)
	{
		*operOid = candidates->oid;
		return FUNCDETAIL_NORMAL;
	}

	/*
	 * Use the same heuristics as for ambiguous functions to resolve the
	 * conflict.
	 */
	candidates = func_select_candidate(nargs, input_typeids, candidates);

	if (candidates)
	{
		*operOid = candidates->oid;
		return FUNCDETAIL_NORMAL;
	}

	*operOid = InvalidOid;
	return FUNCDETAIL_MULTIPLE; /* failed to select a best candidate */
}

/*
 * op_error - utility routine to complain about an unresolvable operator
 */
static void
op_error(ParseState *pstate, List *op, char oprkind,
		 Oid arg1, Oid arg2,
		 FuncDetailCode fdresult, int location)
{
	if (fdresult == FUNCDETAIL_MULTIPLE)
		ereport(ERROR,
				(errcode(ERRCODE_AMBIGUOUS_FUNCTION),
				 errmsg("operator is not unique: %s",
						op_signature_string(op, oprkind, arg1, arg2)),
				 errhint("Could not choose a best candidate operator. "
						 "You might need to add explicit type casts."),
				 parser_errposition(pstate, location)));
	else
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_FUNCTION),
				 errmsg("operator does not exist: %s",
						op_signature_string(op, oprkind, arg1, arg2)),
		  errhint("No operator matches the given name and argument type(s). "
				  "You might need to add explicit type casts."),
				 parser_errposition(pstate, location)));
}

/*
 * op_signature_string
 *		Build a string representing an operator name, including arg type(s).
 *		The result is something like "integer + integer".
 *
 * This is typically used in the construction of operator-not-found error
 * messages.
 */
static const char *
op_signature_string(List *op, char oprkind, Oid arg1, Oid arg2)
{
	StringInfoData argbuf;

	initStringInfo(&argbuf);

	if (oprkind != 'l')
		appendStringInfo(&argbuf, "%s ", format_type_be(arg1));

	appendStringInfoString(&argbuf, NameListToString(op));

	if (oprkind != 'r')
		appendStringInfo(&argbuf, " %s", format_type_be(arg2));

	return argbuf.data;			/* return palloc'd string buffer */
}

/*
 * Callback for pg_operator and pg_cast inval events
 */
static void
InvalidateOprCacheCallBack(Datum arg, int cacheid, uint32 hashvalue)
{
	HASH_SEQ_STATUS status;
	OprCacheEntry *hentry;

	Assert(OprCacheHash != NULL);

	/* Currently we just flush all entries; hard to be smarter ... */
	hash_seq_init(&status, OprCacheHash);

	while ((hentry = (OprCacheEntry *) hash_seq_search(&status)) != NULL)
	{
		if (hash_search(OprCacheHash,
						(void *) &hentry->key,
						HASH_REMOVE, NULL) == NULL)
			elog(ERROR, "hash table corrupted");
	}
}
// vi: noexpandtab sw=4 ts=4
