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
	FmgrInfo	proc;				/* lookup result for typiofunc */
	/* Information for original type */
	Oid				typId;
	Oid				typIoParam;
	int16 		typLen;
	bool 			typByVal;
	char			typAlign;
	char			*outString;	/* Initial part of output string. NULL for input functions. */
} VariantCache;


typedef struct {
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	Oid		typeOid;			/* OID of original data type */
} VariantData;

typedef VariantData *Variant;

#define VHDRSZ				(sizeof(VariantData))
#define VDATAPTR(x)		( (Pointer) ( (x) + 1 ) )

static VariantCache * get_cache(FunctionCallInfo fcinfo, Oid origTypId, IOFuncSelector func);
static Oid getIntOid();


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
	Oid						orgTypeOid;
	text					*orgData;
	Size					len;
	Variant				var;
	Datum				  tmpDatum;
	Datum				  org_datum;

	/* Eventually getting rid of this crap, so segregate it */
		intTypeOid = getIntOid();

		FmgrInfo	 		proc;
		Datum						composite;
		HeapTupleHeader	composite_tuple;
		Oid							typIoParam;
		Oid							typIoFunc;

		/* Cast input data to our internal composite type */
		getTypeInputInfo(intTypeOid, &typIoFunc, &typIoParam);
		fmgr_info_cxt(typIoFunc, &proc, fcinfo->flinfo->fn_mcxt);
		composite=InputFunctionCall(&proc, input, typIoParam, typmod);

		/* Extract data from internal composite type */
		composite_tuple=DatumGetHeapTupleHeader(composite);
		orgTypeOid = (Oid) GetAttributeByNum( composite_tuple, 1, &isnull );
		if (isnull)
			elog(ERROR, "original_type of variant must not be NULL");
		orgData = (text *) GetAttributeByNum( composite_tuple, 2, &isnull );
	/* End crap */

	cache = get_cache(fcinfo, orgTypeOid, IOFunc_input);
	org_datum=InputFunctionCall(&cache->proc, text_to_cstring(orgData), cache->typIoParam, typmod); // TODO: Use real original typmod
	tmpDatum = datumCopy(org_datum, cache->typByVal, cache->typLen);
	len = datumGetSize(tmpDatum, cache->typByVal, cache->typLen);

	var = (Variant) MemoryContextAllocZero(fcinfo->flinfo->fn_mcxt, len + VHDRSZ);
	SET_VARSIZE(var, len + VHDRSZ);
	var->typeOid = orgTypeOid;

	Pointer ptr;
	ptr = VDATAPTR(var);

	/* We don't know what we could get passed, so best not to make this an asert */
	{
		Pointer ptr2 = (Pointer) att_align_pointer(ptr, cache->typAlign, cache->typLen, ptr);
		if( ptr != ptr2 )
			elog(ERROR, "ptr %p doesn't align to %p", ptr, ptr2);
	}

	if (cache->typByVal) {
		elog(LOG, "VDATAPTR %p, tmpDatum %p, len %zu, VHDRSZ %zu", (void *)VDATAPTR(var), &tmpDatum, len, VHDRSZ);
		memcpy(ptr, &tmpDatum, len);
	} else {
		elog(LOG, "VDATAPTR %p, tmpDatum %p, len %zu, VHDRSZ %zu", (void *)VDATAPTR(var), (Pointer) tmpDatum, len, VHDRSZ);
		memcpy(ptr, (Pointer) tmpDatum, len);
	}

	PG_RETURN_POINTER(var);
}

PG_FUNCTION_INFO_V1(variant_out);
Datum
variant_out(PG_FUNCTION_ARGS)
{
	VariantCache	*cache;
	Datum					input_datum = PG_GETARG_DATUM(0);
	Variant				input = (Variant) PG_DETOAST_DATUM_COPY(input_datum);
	Oid						orgTypeOid = input->typeOid;
	Datum					orig_datum;
	bool					need_quote;
	char					*tmp;
	char					*org_cstring;
	StringInfoData	out;

	cache = get_cache(fcinfo, orgTypeOid, IOFunc_output);
	if( cache->typByVal )
		orig_datum = *VDATAPTR(input);
	else
		orig_datum = (Datum) VDATAPTR(input);
	org_cstring = OutputFunctionCall(&cache->proc, orig_datum);

	/*
	 * Detect whether we need double quotes for this value
	 *
	 * Stolen then modified from record_out
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

	/* And emit the string */
	initStringInfo(&out);
	appendStringInfoString(&out, cache->outString);

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

	appendStringInfoChar(&out, ')');

	PG_RETURN_CSTRING(out.data);
}

/*
 * get_cache: get/set cached info
 */
static VariantCache *
get_cache(FunctionCallInfo fcinfo, Oid origTypId, IOFuncSelector func)
{
	VariantCache *cache = (VariantCache *) fcinfo->flinfo->fn_extra;

	if (cache == NULL || cache->typId != origTypId)
	{
		char						typDelim;
		Oid							typIoFunc;

		/*
		 * We can get different OIDs in one call, so don't needlessly Alloc
		 */
		if (cache == NULL)
			cache = (VariantCache *) MemoryContextAlloc(fcinfo->flinfo->fn_mcxt,
												   sizeof(VariantCache));

		cache->typId = origTypId;

		get_type_io_data(cache->typId,
							 func,
							 &cache->typLen,
							 &cache->typByVal,
							 &cache->typAlign,
							 &typDelim,
							 &cache->typIoParam,
							 &typIoFunc);
		fmgr_info_cxt(typIoFunc, &cache->proc, fcinfo->flinfo->fn_mcxt);

		if (func == IOFunc_output)
		{
			char *t = format_type_be(cache->typId);
			cache->outString = MemoryContextAlloc(fcinfo->flinfo->fn_mcxt, strlen(t) + 2);
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

	if (!SPI_connect()) {
		do_pop = true;
		SPI_push();
	}

	/*
	 * Get OID of our internal data type. This is necessary because record_in and
	 * record_out need it.
	 */
	if (!(ret = SPI_execute("SELECT '_variant._variant'::regtype::oid", true, 1)))
		elog( ERROR, "SPI_execute returned %s", SPI_result_code_string(ret));

	out = DatumGetObjectId( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull) );

	/* Remember this frees everything palloc'd since our connect/push call */
	if (do_pop)
		SPI_pop();
	else
		SPI_finish();

	return out;
}
// vi: noexpandtab sw=2 ts=2
