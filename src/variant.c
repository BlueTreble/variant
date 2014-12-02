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

#include "c.h"
#include "postgres.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "access/htup_details.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "utils/typcache.h"
#include "utils/lsyscache.h"
#include "variant.h"

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
	char						*outString;	/* Initial part of output string. NULL for input functions. */
} VariantCache;

#define GetCache(fcinfo) ((VariantCache *) fcinfo->flinfo->fn_extra)

static int variant_cmp_int(FunctionCallInfo fcinfo);
static VariantInt make_variant_int(Variant v, FunctionCallInfo fcinfo, IOFuncSelector func);
static Variant make_variant(VariantInt vi, FunctionCallInfo fcinfo, IOFuncSelector func);
static VariantCache * get_cache(FunctionCallInfo fcinfo, VariantInt vi, IOFuncSelector func);
static Oid getIntOid();
static Oid get_oid(Variant v, uint *flags);
static bool _SPI_conn();
static void _SPI_disc(bool pop);

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
 * - Cast to _variant._variant
 * - Extract type name and validate
 * 
 * TODO: use type's input function to convert type info to internal format. For
 * now, just store the raw _variant._variant Datum.
 */
PG_FUNCTION_INFO_V1(variant_in);
Datum
variant_in(PG_FUNCTION_ARGS)
{
	VariantCache	*cache;
	char					*input = PG_GETARG_CSTRING(0);
	bool					isnull;
	Oid						intTypeOid = InvalidOid;
	int32					typmod = 0;
	text					*orgType;
	text					*orgData;
	VariantInt		vi = palloc0(sizeof(*vi));

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

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

	parseTypeString(text_to_cstring(orgType), &vi->typid, &vi->typmod, false);

	cache = get_cache(fcinfo, vi, IOFunc_input);

	if (!vi->isnull)
		/* Actually need to be using stringTypeDatum(Type tp, char *string, int32 atttypmod) */
		vi->data = InputFunctionCall(&cache->proc, text_to_cstring(orgData), cache->typioparam, vi->typmod);

	PG_RETURN_VARIANT( make_variant(vi, fcinfo, IOFunc_input) );
}

/*
 * variant_cast_in: Cast an arbitrary type to a variant
 *
 * Arguments:
 * 	Original data
 * 	Original typmod
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

	Assert(!fcinfo->flinfo->fn_strict); /* Must be callable on NULL input */

	if (!OidIsValid(vi->typid))
		elog(ERROR, "could not determine data type of input");
	if( PG_ARGISNULL(1) )
		elog( ERROR, "Original typemod must not be NULL" );
	vi->typmod = PG_GETARG_INT32(1);

	if( !vi->isnull )
		vi->data = PG_GETARG_DATUM(0);

	/* Since we're casting in, we'll call for INFunc_input, even though we don't need it */
	PG_RETURN_VARIANT( make_variant(vi, fcinfo, IOFunc_input) );
}

PG_FUNCTION_INFO_V1(variant_out);
Datum
variant_out(PG_FUNCTION_ARGS)
{
	Variant				input = PG_GETARG_VARIANT(0);
	VariantCache	*cache;
	bool					need_quote;
	char					*tmp;
	char					*org_cstring;
	StringInfoData	out;
	VariantInt		vi;

	Assert(fcinfo->flinfo->fn_strict); /* Must be strict */

	vi = make_variant_int(input, fcinfo, IOFunc_output);
	cache = GetCache(fcinfo);

	/* Start building string */
	initStringInfo(&out);
	appendStringInfoString(&out, cache->outString);

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
			appendStringInfoString(&out, org_cstring);
		else
		{
			appendStringInfoChar(&out, '"');
			for (tmp = org_cstring; *tmp; tmp++)
			{
				char		ch = *tmp;

				if (ch == '"' || ch == '\\')
					appendStringInfoCharMacro(&out, ch);
				appendStringInfoCharMacro(&out, ch);
			}
			appendStringInfoChar(&out, '"');
		}
	}

	appendStringInfoChar(&out, ')');

	PG_RETURN_CSTRING(out.data);
}

/*
 * variant_cast_out: Cast a variant to some other type
 *
 * This function is defined as accepting (variant, anyelement). The second
 * argument is used strictly to determine what type we need to cast to. An
 * alternative would be to accept an OID input, but this seems cleaner.
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

	vi = make_variant_int(PG_GETARG_VARIANT(0), fcinfo, IOFunc_output);

	/* If original was NULL then we MUST return NULL */
	if( vi->isnull )
		PG_RETURN_NULL();

	/* If our types match exactly we can just return */
	if( vi->typid == targettypid )
		PG_RETURN_DATUM(vi->data);

	/* Keep cruft localized to just here */
		bool						do_pop;
		int							ret;
		bool						isnull;
		MemoryContext		cctx;
		HeapTuple				tup;
		StringInfoData	cmdd;
		StringInfo			cmd = &cmdd;
		char						*nulls = " ";

		cctx = CurrentMemoryContext;
		do_pop = _SPI_conn();

		initStringInfo(cmd);
		appendStringInfo( cmd, "SELECT $1::%s", format_type_be(targettypid) );
		/* command, nargs, Oid *argument_types, *values, *nulls, read_only, count */
		if( !(ret =SPI_execute_with_args( cmd->data, 1, &vi->typid, &vi->data, nulls, true, 0 )) )
			elog( ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

		/* Make a copy of result Datum in previous memory context */
		MemoryContextSwitchTo(cctx);
		tup = heap_copytuple(SPI_tuptable->vals[0]);
		
		out = heap_getattr(tup, 1, SPI_tuptable->tupdesc, &isnull);
		// getTypeOutputInfo(typoid, &foutoid, &typisvarlena);

		/* Remember this frees everything palloc'd since our connect/push call */
		_SPI_disc(do_pop);
	/* End cruft */

	PG_RETURN_DATUM(out);
}

PG_FUNCTION_INFO_V1(variant_cmp);
Datum
variant_cmp(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(variant_cmp_int(fcinfo));
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

/*
 * variant_cmp_int: Are two variants identical on a binary level?
 *
 * Returns true iff a variant completely identical to another; same type and
 * everything.
 */
static int
variant_cmp_int(FunctionCallInfo fcinfo)
{
	Variant			l = PG_GETARG_VARIANT(0);
	Variant			r = PG_GETARG_VARIANT(1);
	VariantInt	li;
	VariantInt	ri;
	int					result;

	/*
	 * Presumably if both inputs are binary equal then they are in fact equal.
	 * Note that we're not trying to play tricks with not detoasting or
	 * un-packing, unlike variant_image_eq().
	 */
	if(VARSIZE(l) == VARSIZE(r)
			&& memcmp(l, r, VARSIZE(l)) == 0)
		return 0;

	/*
	 * We don't care about IO function but must specify something
	 *
	 * TODO: Improve caching so it will handle more than just one type :(
	 */
	li = make_variant_int(l, fcinfo, IOFunc_input);
	ri = make_variant_int(r, fcinfo, IOFunc_input);

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

		cmd = "SELECT CASE WHEN $1 = $2 THEN 0 ELSE WHEN $1 < $2 THEN -1 ELSE 0 END::int";
		types[0] = li->typid;
		values[0] = li->data;
		nulls[0] = li->isnull;
		types[1] = ri->typid;
		values[1] = ri->data;
		nulls[1] = ri->isnull;

		if( !(ret = SPI_execute_with_args(
						cmd, 2, types, values, nulls,
						true, /* read-only */
						0 /* count */
					)) )
			elog( ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

		result = DatumGetObjectId( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &fcinfo->isnull) );

		_SPI_disc(do_pop);
	}

	return result;
}


/*
 * make_variant_int: Converts our external (Variant) representation to a VariantInt.
 */
static VariantInt
make_variant_int(Variant v, FunctionCallInfo fcinfo, IOFuncSelector func)
{
	VariantCache	*cache;
	VariantInt		vi;
	long 					len; /* long instead of size_t because we're subtracting */
	Pointer 			ptr;
	uint					flags;

	
	/* Ensure v is fully detoasted */
	Assert(!VARATT_IS_EXTENDED(v));

	/* May need to be careful about what context this stuff is palloc'd in */
	vi = palloc0(sizeof(VariantDataInt));

	vi->typid = get_oid(v, &flags);
	vi->typmod = v->typmod;
	vi->isnull = (flags & VAR_ISNULL ? true : false);

	cache = get_cache(fcinfo, vi, func);

	/* by-value type, or fixed-length pass-by-reference */
	if( cache->typbyval || cache->typlen >= 1)
	{
		if(!vi->isnull)
			vi->data = fetch_att(VDATAPTR(v), cache->typbyval, cache->typlen);
		return vi;
	}

	/* Make sure we know we're dealing with either varlena or cstring */
	if (cache->typlen > -1 || cache->typlen < -2)
		elog(ERROR, "unknown typlen %i for typid %u", cache->typlen, cache->typid);

	/* we don't store a varlena header for varlena data; instead we compute
	 * it's size based on ours:
	 *
	 * Our size - our header size - overflow byte (if present)
	 *
	 * For cstring, we don't store the trailing NUL
	 */
	len = VARSIZE(v) - VHDRSZ - (flags & VAR_OVERFLOW ? 1 : 0);
	if( len < 0 )
		elog(ERROR, "Negative len %li", len);

	if (cache->typlen == -1) /* varlena */
	{
		ptr = palloc0(len + VARHDRSZ);
		SET_VARSIZE(ptr, len + VARHDRSZ);
		memcpy(VARDATA(ptr), VDATAPTR(v), len);
	}
	else /* cstring */
	{
		ptr = palloc0(len + 1); /* Need space for NUL terminator */
		memcpy(ptr, VDATAPTR(v), len);
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
	long					len, data_length; /* long because we subtract */
	Pointer				data_ptr = 0;
	uint					flags = 0;

	cache = get_cache(fcinfo, vi, func);
	Assert(cache->typid = vi->typid);

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
	else /* att_addlength_datum() sanity-checks for us */
	{
		data_length = VHDRSZ; /* Start with header size to make sure alignment is correct */
		data_length = att_align_datum(data_length, cache->typalign, cache->typlen, vi->data);
		data_length = att_addlength_datum(data_length, cache->typlen, vi->data);
		data_length -= VHDRSZ;

		if(!cache->typbyval) /* fixed length, pass by reference */
			data_ptr = DatumGetPointer(vi->data);
	}
	if( data_length < 0 )
		elog(ERROR, "Negative data_length %li", data_length);

	/* If typid is too large then we need an extra byte */
	len = VHDRSZ + data_length + (oid_overflow ? sizeof(char) : 0);
	if( len < 0 )
		elog(ERROR, "Negative len %li", len);

	v = palloc0(len);
	SET_VARSIZE(v, len);
	v->pOid = vi->typid;
	v->typmod = vi->typmod;

	if(oid_overflow)
	{
		flags |= VAR_OVERFLOW;

		/* Reset high pOid byte to zero */
		v->pOid &= 0x00FFFFFF;

		/* Store high byte of OID at the end of our structure */
		*((char *) v + len - sizeof(char)) = vi->typid >> 24;
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
			Pointer p = (char *) att_align_nominal(VDATAPTR(v), cache->typalign);
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
		o = v->pOid & 0x00FFFFFF;
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
			char *t = format_type_with_typemod(cache->typid, cache->typmod);
			cache->outString = MemoryContextAlloc(fcinfo->flinfo->fn_mcxt, strlen(t) + 3); /* "(", ",", and "\0" */
			sprintf(cache->outString, "(%s,", t);
		}
		else
			cache->outString="\0";

		fcinfo->flinfo->fn_extra = (void *) cache;
	}

	return cache;
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
	if (!(ret = SPI_execute("SELECT '_variant._variant'::regtype::oid", true, 1)))
		elog( ERROR, "SPI_execute returned %s", SPI_result_code_string(ret));

	out = DatumGetObjectId( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull) );

	/* Remember this frees everything palloc'd since our connect/push call */
	_SPI_disc(do_pop);

	return out;
}

static bool
_SPI_conn()
{
	if( SPI_connect() )
		return false;

	SPI_push();
	return true;
}

static void
_SPI_disc(bool pop)
{
	if(pop)
		SPI_pop();
	else
		SPI_finish();
}

// vi: noexpandtab sw=2 ts=2
