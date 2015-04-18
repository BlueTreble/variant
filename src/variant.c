/*
 *
 * variant.c:
 * 		I/O and support functions for the variant data type
 *
 * We use two different structures to represent variant types. VariantData is
 * the structure that is passed around to the rest of the database. It's geared
 * towards space efficiency rather than ease of access. VariantDataInt is an
 * easier-to-use structure that we use internally.
 *
 * Copyright (c) 2014 Jim Nasby, Blue Treble Consulting http://BlueTreble.com
 */

#include "variant.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "access/htup_details.h"
#include "nodes/nodeFuncs.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/array.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "utils/typcache.h"
#include "utils/lsyscache.h"
#include "catalog/pg_type.h"
#include "port.h"

/* fn_extra cache entry */
typedef struct VariantCache
{
	FmgrInfo				proc;				/* lookup result for typiofunc */
	/* Information for original type */
	Oid							typid;
	int							typmod;
	Oid							typioparam;
	int16 					typlen;
	bool 						typbyval;
	char						typalign;
	IOFuncSelector	IOfunc; /* We should always either be in or out; make sure we're not mixing. */
	char						*formatted_name;	/* Formatted type string. Only set when IOfunc is output/send */
} VariantCache;

#define GetCache(fcinfo) ((VariantCache *) fcinfo->flinfo->fn_extra)

static Variant variant_in_int(FunctionCallInfo fcinfo, char *input, int variant_typmod);
static char * variant_out_int(FunctionCallInfo fcinfo, Variant input);
static int variant_cmp_int(FunctionCallInfo fcinfo);
static char * variant_get_variant_name(int typmod, Oid org_typid, bool ignore_storage);
static VariantInt make_variant_int(Variant v, FunctionCallInfo fcinfo, IOFuncSelector func);
static Variant make_variant(VariantInt vi, FunctionCallInfo fcinfo, IOFuncSelector func);
static VariantCache * get_cache(FunctionCallInfo fcinfo, VariantInt vi, IOFuncSelector func);
static Oid getIntOid();
static Oid get_oid(Variant v, uint *flags);
static bool _SPI_conn();
static void _SPI_disc(bool pop);

static int32 get_fn_expr_argtypmod(FmgrInfo *flinfo, int argnum);
static int32 get_call_expr_argtypmod(Node *expr, int argnum);
static StringInfo quote_variant_name_cstring(const char *variant_name);

/*
 * You can include more files here if needed.
 * To use some types, you must include the
 * correct file here based on:
 * http://www.postgresql.org/docs/current/static/xfunc-c.html#XFUNC-C-TYPE-TABLE
 */

PG_MODULE_MAGIC;

/*
 * variant_in: Parse text representation of a variant
 *
 * - Cast to variant._variant
 * - Extract type name and validate
 * 
 * TODO: use type's input function to convert type info to internal format. For
 * now, just store the raw variant._variant Datum.
 */
PG_FUNCTION_INFO_V1(variant_in);
Datum
variant_in(PG_FUNCTION_ARGS)
{
	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */
	
	PG_RETURN_VARIANT( variant_in_int(fcinfo, PG_GETARG_CSTRING(0), PG_GETARG_INT32(2)) );
}

/*
 * variant_cast_in: Cast an arbitrary type to a variant
 *
 * Arguments:
 * 	Original data
 * 	Target typmod
 *
 * Returns:
 * 	Variant
 */
PG_FUNCTION_INFO_V1(variant_cast_in);
Datum
variant_cast_in(PG_FUNCTION_ARGS)
{
	VariantInt			vi = palloc0(sizeof(*vi));

	vi->isnull = PG_ARGISNULL(0);
	vi->typid = get_fn_expr_argtype(fcinfo->flinfo, 0);
	vi->typmod = get_fn_expr_argtypmod(fcinfo->flinfo, 0);

	Assert(!fcinfo->flinfo->fn_strict); /* Must be callable on NULL input */

	if (!OidIsValid(vi->typid))
		elog(ERROR, "could not determine data type of input");

	/* Validate that we're casting to a registered variant */
	if( PG_ARGISNULL(1) )
		elog( ERROR, "Target typemod must not be NULL" );
	variant_get_variant_name(PG_GETARG_INT32(1), vi->typid, false);

	if( !vi->isnull )
		vi->data = PG_GETARG_DATUM(0);

	/* Since we're casting in, we'll call for INFunc_input, even though we don't need it */
	PG_RETURN_VARIANT( make_variant(vi, fcinfo, IOFunc_input) );
}

PG_FUNCTION_INFO_V1(variant_out);
Datum
variant_out(PG_FUNCTION_ARGS)
{
	PG_RETURN_CSTRING( variant_out_int(fcinfo, PG_GETARG_VARIANT(0)) );
}

/*
 * variant_cast_out: Cast a variant to some other type
 *
 * The type to return is determined by the return type of the Postgres-defined
 * function that is calling us. There is a separate database cast function
 * defined for each type, but they all just call this C function.
 */
PG_FUNCTION_INFO_V1(variant_cast_out);
Datum
variant_cast_out(PG_FUNCTION_ARGS)
{
	Oid							targettypid = get_fn_expr_rettype(fcinfo->flinfo);
	VariantInt			vi;
	Datum						out;

	if( PG_ARGISNULL(0) )
		PG_RETURN_NULL();

	/* No reason to format type name, so use IOFunc_input instead of IOFunc_output */
	vi = make_variant_int(PG_GETARG_VARIANT(0), fcinfo, IOFunc_input);

	/* If original was NULL then we MUST return NULL */
	if( vi->isnull )
		PG_RETURN_NULL();

	/* If our types match exactly we don't need to cast */
	if( vi->typid == targettypid )
		PG_RETURN_DATUM(vi->data);

	/* Keep cruft localized to just here */
	{
		bool						do_pop;
		int							ret;
		bool						isnull;
		MemoryContext		cctx = CurrentMemoryContext;
		HeapTuple				tup;
		StringInfoData	cmdd;
		StringInfo			cmd = &cmdd;
		char						*nulls = " ";

		do_pop = _SPI_conn();

		initStringInfo(cmd);
		appendStringInfo( cmd, "SELECT $1::%s", format_type_be(targettypid) );
		/* command, nargs, Oid *argument_types, *values, *nulls, read_only, count */
		if( (ret = SPI_execute_with_args( cmd->data, 1, &vi->typid, &vi->data, nulls, true, 0 )) != SPI_OK_SELECT )
			elog( ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

		/*
		 * Make a copy of result tuple in previous memory context. Copying the
		 * entire tuple is wasteful; it would be better to only copy the actual
		 * attribute; but in this case the difference isn't very large.
		 */
		MemoryContextSwitchTo(cctx);
		tup = heap_copytuple(SPI_tuptable->vals[0]);
		
		out = heap_getattr(tup, 1, SPI_tuptable->tupdesc, &isnull);
		// getTypeOutputInfo(typoid, &foutoid, &typisvarlena);

		/* Remember this frees everything palloc'd since our connect/push call */
		_SPI_disc(do_pop);
	}
	/* End cruft */

	PG_RETURN_DATUM(out);
}

PG_FUNCTION_INFO_V1(variant_typmod_in);
Datum
variant_typmod_in(PG_FUNCTION_ARGS)
{
	ArrayType	*arr = PG_GETARG_ARRAYTYPE_P(0);
	Datum	   	*elem_values;
	int				arr_nelem;
	char			*inputCString;
	Datum			inputDatum;
	Datum			out;

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

	deconstruct_array(arr, CSTRINGOID,
					  -2, false, 'c', /* elmlen, elmbyval, elmalign */
					  &elem_values, NULL, &arr_nelem); /* elements, nulls, number_of_elements */
	/* TODO: Sanity check array */
	/* PointerGetDatum is equivalent to TextGetDatum, which doesn't exist */
	inputCString = DatumGetCString(elem_values[0]);
	inputDatum = PointerGetDatum( cstring_to_text( inputCString ) );

	/* TODO: cache this stuff */
	/* Keep cruft localized to just here */
	{
		bool						do_pop = _SPI_conn();
		bool						isnull;
		int							ret;
		Oid							type = TEXTOID;
		/* This should arguably be FOR KEY SHARE. See comment in variant_get_variant_name() */
		char						*cmd = "SELECT variant_typmod, variant_enabled FROM variant._registered WHERE lower(variant_name) = lower($1)";

		/* command, nargs, Oid *argument_types, *values, *nulls, read_only, count */
		if( (ret = SPI_execute_with_args( cmd, 1, &type, &inputDatum, " ", true, 0 )) != SPI_OK_SELECT )
			elog( ERROR, "SPI_execute_with_args(%s) returned %s", cmd, SPI_result_code_string(ret));

		Assert( SPI_tuptable );
		if ( SPI_processed > 1 )
			ereport(ERROR,
				( errmsg( "Got %u records for variant.variant(%s)", SPI_processed, inputCString ),
					errhint( "This means _variant._registered is corrupted" )
				)
			);


		if ( SPI_processed < 1 )
			elog( ERROR, "variant.variant(%s) is not registered", inputCString );

		/* Note 0 vs 1 based numbering */
		Assert(SPI_tuptable->tupdesc->attrs[0]->atttypid == INT4OID);
		Assert(SPI_tuptable->tupdesc->attrs[1]->atttypid == BOOLOID);
		out = heap_getattr( SPI_tuptable->vals[0], 2, SPI_tuptable->tupdesc, &isnull );
		if( !DatumGetBool(out) )
			ereport( ERROR,
					( errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						errmsg( "variant.variant(%s) is disabled", inputCString )
					)
			);

		/* Don't need to copy the tuple because int is pass by value */
		out = heap_getattr( SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull );
		if( isnull )
			ereport( ERROR,
					( errmsg( "Found NULL variant_typmod for variant.variant(%s)", inputCString ),
						errhint( "This should never happen; is _variant._registered corrupted?" )
					)
			);

		_SPI_disc(do_pop);
	}

	PG_RETURN_INT32(out);
}

PG_FUNCTION_INFO_V1(variant_typmod_out);
Datum
variant_typmod_out(PG_FUNCTION_ARGS)
{
	StringInfo			out;
	char						*variant_name;

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

	/* TODO: cache this stuff */
	variant_name = variant_get_variant_name(PG_GETARG_INT32(0), InvalidOid, true);
	out = quote_variant_name_cstring(variant_name);
	pfree(variant_name);

	PG_RETURN_CSTRING(out->data);
}
PG_FUNCTION_INFO_V1(quote_variant_name);
Datum
quote_variant_name(PG_FUNCTION_ARGS)
{
	StringInfo			out;
	char						*variant_name;

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

	variant_name = text_to_cstring(PG_GETARG_TEXT_PP(0));

	out = quote_variant_name_cstring(variant_name);

	/* out is wrapped in () which is not what we want, so we don't return it directly */

	PG_RETURN_TEXT_P( cstring_to_text_with_len(out->data + 1, out->len-2) );
}


/*
 * text_(in|out): Same as variant_(in|out) except text instead of cstring
 */
PG_FUNCTION_INFO_V1(variant_text_in);
Datum
variant_text_in(PG_FUNCTION_ARGS)
{
	Assert(!fcinfo->flinfo->fn_strict);
	Assert(fcinfo->nargs == 2);


	PG_RETURN_VARIANT(
			variant_in_int(fcinfo,
				TextDatumGetCString(PG_GETARG_DATUM(0)),
				PG_ARGISNULL(1) ? -1 : PG_GETARG_INT32(1)
			)
	);
}
PG_FUNCTION_INFO_V1(variant_text_out);
Datum
variant_text_out(PG_FUNCTION_ARGS)
{
	PG_RETURN_DATUM( CStringGetTextDatum( variant_out_int(fcinfo, PG_GETARG_VARIANT(0)) ) );
}

PG_FUNCTION_INFO_V1(variant_type_out);
Datum
variant_type_out(PG_FUNCTION_ARGS)
{
	VariantCache	*cache;

	Assert(fcinfo->flinfo->fn_strict); /* Must not be callable on NULL input */
	make_variant_int(PG_GETARG_VARIANT(0), fcinfo, IOFunc_output);

	cache = GetCache(fcinfo);
	PG_RETURN_TEXT_P(cstring_to_text(cache->formatted_name));
}

/*
 * COMPARISON FUNCTIONS
 */
PG_FUNCTION_INFO_V1(variant_cmp);
Datum
variant_cmp(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(variant_cmp_int(fcinfo));
}

PG_FUNCTION_INFO_V1(variant_lt);
Datum
variant_lt(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret < 0);
}
PG_FUNCTION_INFO_V1(variant_le);
Datum
variant_le(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret <= 0);
}

PG_FUNCTION_INFO_V1(variant_eq);
Datum
variant_eq(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret == 0);
}
PG_FUNCTION_INFO_V1(variant_ne);
Datum
variant_ne(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret != 0);
}

PG_FUNCTION_INFO_V1(variant_ge);
Datum
variant_ge(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret >= 0);
}
PG_FUNCTION_INFO_V1(variant_gt);
Datum
variant_gt(PG_FUNCTION_ARGS)
{
	int ret = variant_cmp_int(fcinfo);

	if(fcinfo->isnull)
		PG_RETURN_NULL();

	PG_RETURN_BOOL(ret > 0);
}

/*
 * variant_image_eq: Are two variants identical on a binary level?
 *
 * Returns true iff a variant completely identical to another; same type and
 * everything.
 */
PG_FUNCTION_INFO_V1(variant_image_eq);
Datum
variant_image_eq(PG_FUNCTION_ARGS)
{
	Variant	l = (Variant) PG_GETARG_DATUM(0);
	Variant	r = (Variant) PG_GETARG_DATUM(1);
	int			cmp;

	/*
	 * To avoid detoasting we use _ANY variations on VAR*, but that means we must
	 * make sure to use VARSIZE_ANY_EXHDR, *not* VARSIZE_ANY!
	 */
	if(VARSIZE_ANY_EXHDR(l) != VARSIZE_ANY_EXHDR(r))
		PG_RETURN_BOOL(false);
	
	/*
	 * At this point we need to detoast. We could theoretically leave data
	 * compressed, but since there's no direct support for that we don't bother.
	 */
	l = (Variant) PG_DETOAST_DATUM_PACKED(l);
	r = (Variant) PG_DETOAST_DATUM_PACKED(r);
	cmp = memcmp(VARDATA_ANY(l), VARDATA_ANY(r), VARSIZE_ANY_EXHDR(l));

	PG_FREE_IF_COPY(l, 0);
	PG_FREE_IF_COPY(r, 1);

	PG_RETURN_BOOL( cmp = 0 ? true : false);
}

/*
 ********************
 * SUPPORT FUNCTIONS
 ********************
 */

static Variant
variant_in_int(FunctionCallInfo fcinfo, char *input, int variant_typmod)
{
	VariantCache	*cache;
	bool					isnull;
	Oid						intTypeOid = InvalidOid;
	int32					typmod = 0;
	text					*orgType;
	text					*orgData;
	VariantInt		vi = palloc0(sizeof(*vi));

	/* Eventually getting rid of this crap, so segregate it */
		intTypeOid = getIntOid();

		FmgrInfo	 		proc;
		Datum						composite;
		HeapTupleHeader	composite_tuple;
		Oid							typioparam;
		Oid							typIoFunc;

		/* Cast input data to our internal composite type */
		getTypeInputInfo(intTypeOid, &typIoFunc, &typioparam);
		fmgr_info_cxt(typIoFunc, &proc, fcinfo->flinfo->fn_mcxt);
		composite=InputFunctionCall(&proc, input, typioparam, typmod);

		/* Extract data from internal composite type */
		composite_tuple=DatumGetHeapTupleHeader(composite);
		orgType = (text *) GetAttributeByNum( composite_tuple, 1, &isnull );
		if (isnull)
			elog(ERROR, "original_type of variant must not be NULL");
		orgData = (text *) GetAttributeByNum( composite_tuple, 2, &vi->isnull );
	/* End crap */

#ifdef LONG_PARSETYPE
	parseTypeString(text_to_cstring(orgType), &vi->typid, &vi->typmod, false);
#else
	parseTypeString(text_to_cstring(orgType), &vi->typid, &vi->typmod);
#endif

	/*
	 * Verify we've been handed a valid typmod
	 */
	variant_get_variant_name(variant_typmod, vi->typid, false);

	cache = get_cache(fcinfo, vi, IOFunc_input);

	if (!vi->isnull)
		/* Actually need to be using stringTypeDatum(Type tp, char *string, int32 atttypmod) */
		vi->data = InputFunctionCall(&cache->proc, text_to_cstring(orgData), cache->typioparam, vi->typmod);

	return make_variant(vi, fcinfo, IOFunc_input);
}

static char *
variant_out_int(FunctionCallInfo fcinfo, Variant input)
{
	VariantCache	*cache;
	bool					need_quote;
	char					*tmp;
	char					*org_cstring;
	StringInfoData	outd;
	StringInfo		out = &outd;
	VariantInt		vi;

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

	vi = make_variant_int(input, fcinfo, IOFunc_output);
	cache = GetCache(fcinfo);
	Assert(cache->formatted_name);

	/* Start building string */
	initStringInfo(out);
	appendStringInfoChar(out, '(');

	need_quote = false;
	for (tmp = cache->formatted_name; *tmp; tmp++)
	{
		char		ch = *tmp;

		if (ch == '"' || ch == '\\' ||
			ch == '(' || ch == ')' || ch == ',' ||
			isspace((unsigned char) ch))
		{
			need_quote = true;
			break;
		}
	}
	if(!need_quote)
		appendStringInfoString(out, cache->formatted_name);
	else
	{
		appendStringInfoChar(out, '"');
		for (tmp = cache->formatted_name; *tmp; tmp++)
		{
			char		ch = *tmp;

			if (ch == '"' || ch == '\\')
				appendStringInfoCharMacro(out, ch);
			appendStringInfoCharMacro(out, ch);
		}
		appendStringInfoChar(out, '"');
	}
	appendStringInfoChar(out, ',');

	if(!vi->isnull)
	{
		org_cstring = OutputFunctionCall(&cache->proc, vi->data);

		/*
		 * Detect whether we need double quotes for this value
		 *
		 * Stolen then modified from record_out.
		 */
		need_quote = (org_cstring[0] == '\0' ); /* force quotes for empty string */
		if( !need_quote )
		{
			for (tmp = org_cstring; *tmp; tmp++)
			{
				char		ch = *tmp;

				if (ch == '"' || ch == '\\' ||
					ch == '(' || ch == ')' || ch == ',' ||
					isspace((unsigned char) ch))
				{
					need_quote = true;
					break;
				}
			}
		}

		if (!need_quote)
			appendStringInfoString(out, org_cstring);
		else
		{
			appendStringInfoChar(out, '"');
			for (tmp = org_cstring; *tmp; tmp++)
			{
				char		ch = *tmp;

				if (ch == '"' || ch == '\\')
					appendStringInfoCharMacro(out, ch);
				appendStringInfoCharMacro(out, ch);
			}
			appendStringInfoChar(out, '"');
		}
	}

	appendStringInfoChar(out, ')');

	return out->data;
}

/*
 * variant_get_variant_name: Return the name of a named variant
 */
char *
variant_get_variant_name(int typmod, Oid org_typid, bool ignore_storage)
{
	Datum						values[2];
	MemoryContext		cctx = CurrentMemoryContext;
	bool						do_pop = _SPI_conn();
	bool						isnull;
	Oid							types[2] = {INT4OID, REGTYPEOID};
	char						*cmd;
	int							nargs;
	int							ret;
	Datum						result;
	char						*out;

	values[0] = Int32GetDatum(typmod);

	/*
	 * There's a race condition here; someone could be attempting to remove an
	 * allowed type from this registered variant or even remove it entirely. We
	 * could avoid that by taking a share/keyshare lock here and taking the
	 * appropriate blocking lock when modifying the registration record. Doing
	 * that would probably be quite bad though; not only are type IO and typmod
	 * IO routines assumed to be non-volatile, taking such a lock would end up
	 * generating a lot of lock updates to the registration rows.
	 *
	 * Since the whole purpose of registration is to handle the issue of someone
	 * attempting to drop a type that has made it into a variant in a table
	 * column, which we can't completely handle anyway, I don't think it's worth
	 * it to lock the rows.
	 */
	if(ignore_storage)
	{
		cmd = "SELECT variant_name, variant_enabled, storage_allowed FROM variant._registered WHERE variant_typmod = $1";
		nargs = 1;
	}
	else
	{
		cmd = "SELECT variant_name, variant_enabled, storage_allowed, allowed_types @> array[ $2 ] FROM variant._registered WHERE variant_typmod = $1";
		nargs = 2;
		values[1] = ObjectIdGetDatum(org_typid);
	}

	/* command, nargs, Oid *argument_types, *values, *nulls, read_only, count */
	if( (ret = SPI_execute_with_args( cmd, nargs, types, values, "  ", true, 0 )) != SPI_OK_SELECT )
		elog( ERROR, "SPI_execute_with_args(%s) returned %s", cmd, SPI_result_code_string(ret));
	Assert( SPI_tuptable );

	if ( SPI_processed > 1 )
		ereport(ERROR,
			( errmsg( "Got %u records for variant typmod %i", SPI_processed, typmod ),
				errhint( "This means _variant._registered is corrupted" )
			)
		);
	if ( SPI_processed < 1 )
		elog( ERROR, "invalid typmod %i", typmod );

	/* Note 0 vs 1 based numbering */
	Assert(SPI_tuptable->tupdesc->attrs[0]->atttypid == VARCHAROID);
	Assert(SPI_tuptable->tupdesc->attrs[1]->atttypid == BOOLOID);
	Assert(SPI_tuptable->tupdesc->attrs[2]->atttypid == BOOLOID);
	result = heap_getattr( SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull );
	if( isnull )
		ereport( ERROR,
				( errmsg( "Found NULL variant_name for typmod %i", typmod ),
					errhint( "This should never happen; is _variant._registered corrupted?" )
				)
		);

	MemoryContextSwitchTo(cctx);
	out = text_to_cstring(DatumGetTextP(result));

	result = heap_getattr( SPI_tuptable->vals[0], 2, SPI_tuptable->tupdesc, &isnull );
	if( !DatumGetBool(result) )
		ereport( ERROR,
				( errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					errmsg( "variant.variant(%s) is disabled", out )
				)
			);

	/*
	 * If storage is allowed, then throw an error if we don't know what our
	 * original type is, or if that type is not listed as allowed.
	 */
	if(!ignore_storage)
	{
		result = heap_getattr( SPI_tuptable->vals[0], 3, SPI_tuptable->tupdesc, &isnull );
		if( DatumGetBool(result) )
		{
			if( org_typid == InvalidOid)
				ereport( ERROR,
						( errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							errmsg( "Unable to determine original type" )
						)
					);

			result = heap_getattr( SPI_tuptable->vals[0], 4, SPI_tuptable->tupdesc, &isnull );
			if( !DatumGetBool(result) )
				ereport( ERROR,
						( errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							errmsg( "type %s is not allowed in variant.variant(%s)", format_type_be(org_typid), out ),
							errhint( "you can permanently allow a type to be used by calling variant.allow_type()" )
						)
					);
		}
	}

	_SPI_disc(do_pop); /* pfree's all SPI stuff */

	return out;
}

/*
 * variant_cmp_int: Compare two variants
 */
static int
variant_cmp_int(FunctionCallInfo fcinfo)
{
	Variant			l, r;
	VariantInt	li;
	VariantInt	ri;
	int					out;
	
	Assert(fcinfo->flinfo->fn_strict); /* Must not be callable on NULL input */
	l = PG_GETARG_VARIANT(0);
	r = PG_GETARG_VARIANT(1);

	/*
	 * Presumably if both inputs are binary equal then they are in fact equal.
	 * The only problem is two variants storing NULL would be binary equal but
	 * can't be treated as-such. Given that issue, it doesn't seem worth trying
	 * to optimize this.
	 *
	 * Note that we're not trying to play tricks with not detoasting or
	 * un-packing, unlike variant_image_eq().
	 */
#ifdef NOT_USED
	if(VARSIZE(l) == VARSIZE(r)
			&& memcmp(l, r, VARSIZE(l)) == 0)
		return 0;
#endif

	/*
	 * We don't care about IO function but must specify something
	 *
	 * TODO: Improve caching so it will handle more than just one type :(
	 */
	li = make_variant_int(l, fcinfo, IOFunc_input);
	ri = make_variant_int(r, fcinfo, IOFunc_input);

	/*
	 * We need to special-case IS DISTINCT, because it considers NULL to be the
	 * same as NULL.
	 */
	if(fcinfo->flinfo->fn_expr &&
			IsA(fcinfo->flinfo->fn_expr, DistinctExpr))
	{
		if( li->isnull && ri->isnull )
			return 0;
		else if( li->isnull || ri->isnull )
			return -1;
	}
	else if(li->isnull || ri->isnull )
		PG_RETURN_NULL();

	/* TODO: If both variants are of the same type try comparing directly */
		/* TODO: Support Transform_null_equals */

	/* Do comparison via SPI */
	/* TODO: cache this */
	{
		bool				do_pop;
		int					ret;
		char				*cmd;
		Oid					types[2];
		Datum				values[2];
		bool				nulls[2];

		do_pop = _SPI_conn();

		cmd = "SELECT CASE WHEN $1 = $2 THEN 0 WHEN $1 < $2 THEN -1 ELSE 1 END::int";
		types[0] = li->typid;
		values[0] = li->data;
		nulls[0] = li->isnull;
		types[1] = ri->typid;
		values[1] = ri->data;
		nulls[1] = ri->isnull;

		if( (ret = SPI_execute_with_args(
						cmd, 2, types, values, nulls,
						true, /* read-only */
						0 /* count */
					)) != SPI_OK_SELECT )
			elog( ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

		/* Note 0 vs 1 based numbering */
		Assert(SPI_tuptable->tupdesc->attrs[0]->atttypid == INT4OID);

		/* Don't need to copy the tuple because int is pass by value */
		out = DatumGetInt32( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &fcinfo->isnull) );

		_SPI_disc(do_pop);
	}

	return out;
}

/*
 * make_variant_int: Converts our external (Variant) representation to a VariantInt.
 */
static VariantInt
make_variant_int(Variant v, FunctionCallInfo fcinfo, IOFuncSelector func)
{
	VariantCache	*cache;
	VariantInt		vi;
	long 					data_length; /* long instead of size_t because we're subtracting */
	Pointer 			ptr;
	uint					flags;

	
	/* Ensure v is fully detoasted */
	Assert(!VARATT_IS_EXTENDED(v));

	/* May need to be careful about what context this stuff is palloc'd in */
	vi = palloc0(sizeof(VariantDataInt));

	vi->typid = get_oid(v, &flags);

#ifdef VARIANT_TEST_OID
	vi->typid -= OID_MASK;
#endif

	vi->typmod = v->typmod;
	vi->isnull = (flags & VAR_ISNULL ? true : false);

	cache = get_cache(fcinfo, vi, func);

	/*
	 * by-value type. We do special things with all pass-by-reference when we
	 * store, so we only use this for typbyval even though fetch_att supports
	 * pass-by-reference.
	 *
	 * Note that fetch_att sanity-checks typlen for us (because we're only passing typbyval).
	 */
	if(cache->typbyval)
	{
		if(!vi->isnull)
		{
			Pointer p = VDATAPTR_ALIGN(v, cache->typalign);
			vi->data = fetch_att(p, cache->typbyval, cache->typlen);
		}
		return vi;
	}

	/* we don't store a varlena header for varlena data; instead we compute
	 * it's size based on ours:
	 *
	 * Our size - our header size - overflow byte (if present)
	 *
	 * For cstring, we don't store the trailing NUL
	 */
	data_length = VARSIZE(v) - VHDRSZ - (flags & VAR_OVERFLOW ? 1 : 0);
	if( data_length < 0 )
		elog(ERROR, "Negative data_length %li", data_length);

	if (cache->typlen == -1) /* varlena */
	{
		ptr = palloc0(data_length + VARHDRSZ);
		SET_VARSIZE(ptr, data_length + VARHDRSZ);
		memcpy(VARDATA(ptr), VDATAPTR(v), data_length);
	}
	else if(cache->typlen == -2) /* cstring */
	{
		ptr = palloc(data_length + 1); /* Need space for NUL terminator */
		memcpy(ptr, VDATAPTR(v), data_length);
		*(ptr + data_length + 1) = '\0';
	}
	else /* Fixed size, pass by reference */
	{
		if(vi->isnull)
		{
			vi->data = (Datum) 0;
			return vi;
		}

		Assert(data_length == cache->typlen);
		ptr = palloc0(data_length);
		Assert(ptr == (char *) att_align_nominal(ptr, cache->typalign));
		memcpy(ptr, VDATAPTR(v), data_length);
	}
	vi->data = PointerGetDatum(ptr);

	return vi;
}

/*
 * Create an external variant from our internal representation
 */
static Variant
make_variant(VariantInt vi, FunctionCallInfo fcinfo, IOFuncSelector func)
{
	VariantCache	*cache;
	Variant				v;
	bool					oid_overflow=OID_TOO_LARGE(vi->typid);
	long					variant_length, data_length; /* long because we subtract */
	Pointer				data_ptr = 0;
	uint					flags = 0;

	cache = get_cache(fcinfo, vi, func);
	Assert(cache->typid = vi->typid);

#ifdef VARIANT_TEST_OID
	vi->typid += OID_MASK;
	oid_overflow=OID_TOO_LARGE(vi->typid);
#endif

	if(vi->isnull)
	{
		flags |= VAR_ISNULL;
		data_length = 0;
	}
	else if(cache->typlen == -1) /* varlena */
	{
		/*
		 * Short varlena is OK, but we need to make sure it's not external. It's OK
		 * to leave compressed varlena's alone too, but detoast_packed will
		 * uncompress them. We'll just follow rangetype.c's lead here.
		 */
		vi->data = PointerGetDatum( PG_DETOAST_DATUM_PACKED(vi->data) );
		data_ptr = DatumGetPointer(vi->data);

		/*
		 * Because we don't store varlena aligned or with it's header, our
		 * data_length is simply the varlena length.
		 */
		data_length = VARSIZE_ANY_EXHDR(vi->data);
		data_ptr = VARDATA_ANY(data_ptr);
	}
	else if(cache->typlen == -2) /* cstring */
	{
		data_length = strlen(DatumGetCString(vi->data)); /* We don't store NUL terminator */
		data_ptr = DatumGetPointer(vi->data);
	}
	else
	{
		Assert(cache->typlen >= 0);
		if(cache->typbyval)
		{
			data_length = VHDRSZ; /* Start with header size to make sure alignment is correct */
			data_length = (long) VDATAPTR_ALIGN(data_length, cache->typalign);
			data_length += cache->typlen;
			data_length -= VHDRSZ;
		}
		else /* fixed length, pass by reference */
		{
			data_length = cache->typlen;
			data_ptr = DatumGetPointer(vi->data);
		}
	}

	/* If typid is too large then we need an extra byte */
	variant_length = VHDRSZ + data_length + (oid_overflow ? sizeof(char) : 0);
	if( variant_length < 0 )
		elog(ERROR, "Negative variant_length %li", variant_length);

	v = palloc0(variant_length);
	SET_VARSIZE(v, variant_length);
	v->pOid = vi->typid;
	v->typmod = vi->typmod;

	if(oid_overflow)
	{
		flags |= VAR_OVERFLOW;

		/* Reset high pOid byte to zero */
		v->pOid &= 0x00FFFFFF;

		/* Store high byte of OID at the end of our structure */
		*((char *) v + VARSIZE(v) - 1) = vi->typid >> 24;
	}

	/*
	 * Be careful not to overwrite the valid OID data
	 */
	v->pOid |= flags;
	Assert( get_oid(v, &flags) == vi->typid );

	if(!vi->isnull)
	{
		if(cache->typbyval)
		{
			Pointer p = VDATAPTR_ALIGN(v, cache->typalign);
			store_att_byval(p, vi->data, cache->typlen);
		}
		else
			memcpy(VDATAPTR(v), data_ptr, data_length);
	}

	return v;
}

/*
 * get_oid: Returns actual Oid from a Variant
 */
static Oid
get_oid(Variant v, uint *flags)
{
	*flags = v->pOid & (~OID_MASK);

	if(*flags & VAR_OVERFLOW)
	{
		char	e;
		Oid		o;

		/* fetch the extra byte from datum's last byte */
		e = *((char *) v + VARSIZE(v) - 1);

		o = ((uint) e) << 24;
		o |= v->pOid & 0x00FFFFFF;
		return o;
	}
	else
		return v->pOid & OID_MASK;
}

/*
 * get_cache: get/set cached info
 */
static VariantCache *
get_cache(FunctionCallInfo fcinfo, VariantInt vi, IOFuncSelector func)
{
	VariantCache *cache = (VariantCache *) fcinfo->flinfo->fn_extra;

	/* IO type should always be the same, so assert that. But if we're not an assert build just force a reset. */
	if (cache != NULL && cache->typid == vi->typid && cache->typmod == vi->typmod && cache->IOfunc != func)
	{
		Assert(false);
		cache->typid ^= vi->typid;
	}

	if (cache == NULL || cache->typid != vi->typid || cache->typmod != vi->typmod)
	{
		char						typDelim;
		Oid							typIoFunc;

		/*
		 * We can get different OIDs in one call, so don't needlessly palloc
		 */
		if (cache == NULL)
			cache = (VariantCache *) MemoryContextAlloc(fcinfo->flinfo->fn_mcxt,
												   sizeof(VariantCache));

		cache->typid = vi->typid;
		cache->typmod = vi->typmod;
		cache->IOfunc = func;

		get_type_io_data(cache->typid,
							 func,
							 &cache->typlen,
							 &cache->typbyval,
							 &cache->typalign,
							 &typDelim,
							 &cache->typioparam,
							 &typIoFunc);
		fmgr_info_cxt(typIoFunc, &cache->proc, fcinfo->flinfo->fn_mcxt);

		if (func == IOFunc_output || func == IOFunc_send)
		{
			cache->formatted_name = MemoryContextStrdup(fcinfo->flinfo->fn_mcxt,
					format_type_with_typemod(cache->typid, cache->typmod));
		}
		else
			cache->formatted_name="\0";

		fcinfo->flinfo->fn_extra = (void *) cache;
	}

	return cache;
}


StringInfo
quote_variant_name_cstring(const char *variant_name)
{
	StringInfo			out = makeStringInfo();
	bool						need_quote;
	const char			*tmp;

	appendStringInfoChar(out, '(');
	need_quote = false;
	for (tmp = variant_name; *tmp; tmp++)
	{
		const char		ch = *tmp;

		if (ch == '"' || ch == '(' || ch == ')' || ch == ',' ||
			isspace((unsigned char) ch))
		{
			need_quote = true;
			break;
		}
	}
	if(!need_quote)
		appendStringInfoString(out, variant_name);
	else
	{
		appendStringInfoChar(out, '"');
		for (tmp = variant_name; *tmp; tmp++)
		{
			const char		ch = *tmp;

			if (ch == '"')
				appendStringInfoCharMacro(out, ch);
			appendStringInfoCharMacro(out, ch);
		}
		appendStringInfoChar(out, '"');
	}
	appendStringInfoChar(out, ')');

	return out;
}


Oid
getIntOid()
{
	Oid		out;
	int		ret;
	bool	isnull;
	bool	do_pop = false;

	do_pop = _SPI_conn();

	/*
	 * Get OID of our internal data type. This is necessary because record_in and
	 * record_out need it.
	 */
	if ( (ret = SPI_execute("SELECT 'variant._variant'::regtype::oid", true, 1)) != SPI_OK_SELECT )
		elog( ERROR, "SPI_execute returned %s", SPI_result_code_string(ret));

	/* Don't need to copy the tuple because Oid is pass by value */
	out = DatumGetObjectId( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull) );

	/* Remember this frees everything palloc'd since our connect/push call */
	_SPI_disc(do_pop);

	return out;
}

static bool
_SPI_conn()
{
	int		ret;

	if( SPI_connect() == SPI_OK_CONNECT )
		return false;

	SPI_push();
	if( (ret = SPI_connect()) != SPI_OK_CONNECT )
		elog( ERROR, "SPI_connect returned %s", SPI_result_code_string(ret));
	return true;
}

static void
_SPI_disc(bool pop)
{
	int		ret;

	if( (ret = SPI_finish()) != SPI_OK_FINISH )
		elog( ERROR, "SPI_finish returned %s", SPI_result_code_string(ret));
	if(pop)
		SPI_pop();
}

/*
 * Stolen from fmgr.c and modified for typmod
 */

/*
 * Get the actual type OID of a specific function argument (counting from 0)
 *
 * Returns InvalidOid if information is not available
 */
static int32
get_fn_expr_argtypmod(FmgrInfo *flinfo, int argnum)
{
	/*
	 * can't return anything useful if we have no FmgrInfo or if its fn_expr
	 * node has not been initialized
	 */
	if (!flinfo || !flinfo->fn_expr)
		return InvalidOid;

	return get_call_expr_argtypmod(flinfo->fn_expr, argnum);
}

/*
 * Get the actual type OID of a specific function argument (counting from 0),
 * but working from the calling expression tree instead of FmgrInfo
 *
 * Returns InvalidOid if information is not available
 */
static int32
get_call_expr_argtypmod(Node *expr, int argnum)
{
	List	   *args;
	int32			argtypmod;

	if (expr == NULL)
		return -1;

	if (IsA(expr, FuncExpr))
		args = ((FuncExpr *) expr)->args;
	else if (IsA(expr, OpExpr))
		args = ((OpExpr *) expr)->args;
	else if (IsA(expr, DistinctExpr))
		args = ((DistinctExpr *) expr)->args;
	else if (IsA(expr, ScalarArrayOpExpr))
		// See below
		// args = ((ScalarArrayOpExpr *) expr)->args;
		elog(ERROR, "castnig a variant as part of an ANY/ALL [array] expression is not supported" );
	else if (IsA(expr, ArrayCoerceExpr))
		// See below
		// args = list_make1(((ArrayCoerceExpr *) expr)->arg);
		elog(ERROR, "castnig a variant as part of an array cast is not supported" );
	else if (IsA(expr, NullIfExpr))
		args = ((NullIfExpr *) expr)->args;
	else if (IsA(expr, WindowFunc))
		args = ((WindowFunc *) expr)->args;
	else
		return -1;

	if (argnum < 0 || argnum >= list_length(args))
		return -1;

	argtypmod = exprTypmod((Node *) list_nth(args, argnum));

	/*
	 * get_call_expr_argtyp has these hacks in place. I don't know if they're
	 * needed for typmods or not. For now, punt.
	 *
	 * special hack for ScalarArrayOpExpr and ArrayCoerceExpr: what the
	 * underlying function will actually get passed is the element type of the
	 * array.
	 */
	if (IsA(expr, ScalarArrayOpExpr) &&
		argnum == 1)
		// argtypmod = get_base_element_type(argtypmod);
		elog(ERROR, "castnig a variant as part of an ANY/ALL [array] expression is not supported" );
	else if (IsA(expr, ArrayCoerceExpr) &&
			 argnum == 0)
		// argtypmod = get_base_element_type(argtypmod);
		elog(ERROR, "castnig a variant as part of an array cast is not supported" );

	return argtypmod;
}


// vi: noexpandtab sw=2 ts=2
