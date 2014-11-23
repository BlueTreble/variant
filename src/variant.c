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

static Oid getIntOid();
static char * get_cstring(Oid intTypeOid, MemoryContext ctx, Datum dat);
typedef struct {
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	Oid		typeOid;			/* OID of original data type */
} VariantData;

typedef VariantData *Variant;

#define VHDRSZ				(sizeof(VariantData))
#define VDATAPTR(x)		( (Pointer) ( (x) + 1 ) )


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
	char						*input = PG_GETARG_CSTRING(0);
	Datum						composite;
	HeapTupleHeader	composite_tuple;
	bool						isnull;
	Oid							intTypeOid = InvalidOid;
	int32						typmod = 0;
	Oid							orgTypeOid;
	char						*orgTypeName;
	text						*orgData;
	bool						do_pop = false;
	Size						len;
	Variant					var;
	char						*tmp;
	Datum					  tmpDatum;
	Datum					  org_datum;
	FmgrInfo	 			proc;
	int16 					typLen;
	bool 						typByVal;
	char						typAlign;
	char						typDelim;
	Oid							typIoParam;
	Oid							typIoFunc;

	if (!SPI_connect()) {
		do_pop = true;
		SPI_push();
	}

	intTypeOid = getIntOid();

	/* Cast input data to our internal composite type */
	getTypeInputInfo(intTypeOid, &typIoFunc, &typIoParam);
	fmgr_info_cxt(typIoFunc, &proc, fcinfo->flinfo->fn_mcxt);
	composite=InputFunctionCall(&proc, input, typIoParam, typmod);

	/* Extract data from internal composite type */
	composite_tuple=DatumGetHeapTupleHeader(composite);
	orgTypeOid = (Oid) GetAttributeByNum( composite_tuple, 1, &isnull );

	if (isnull)
		elog(ERROR, "original_type of variant must not be NULL");

	orgTypeName = format_type_be(orgTypeOid);
	orgData = (text *) GetAttributeByNum( composite_tuple, 2, &isnull );

	get_type_io_data(orgTypeOid,
						 IOFunc_input,
						 &typLen,
						 &typByVal,
						 &typAlign,
						 &typDelim,
						 &typIoParam,
						 &typIoFunc);


	fmgr_info_cxt(typIoFunc, &proc, fcinfo->flinfo->fn_mcxt);
	org_datum=InputFunctionCall(&proc, text_to_cstring(orgData), typIoParam, typmod);
	tmpDatum = datumCopy(org_datum, typByVal, typLen);
	len = datumGetSize(tmpDatum, typByVal, typLen);

	var = (Variant) MemoryContextAllocZero(fcinfo->flinfo->fn_mcxt, len + VHDRSZ);
	SET_VARSIZE(var, len + VHDRSZ);
	var->typeOid = orgTypeOid;

	Pointer ptr;
	ptr = VDATAPTR(var);

	/* We don't know what we could get passed, so best not to make this an asert */
	Pointer ptr2 = (Pointer) att_align_pointer(ptr, typAlign, typLen, ptr);
	if( ptr != ptr2 )
		elog(ERROR, "ptr %p doesn't align to %p", ptr, ptr2);

	if (typByVal) {
		elog(LOG, "VDATAPTR %p, tmpDatum %p, len %zu, VHDRSZ %zu", (void *)VDATAPTR(var), &tmpDatum, len, VHDRSZ);
		memcpy(ptr, &tmpDatum, len);
	} else {
		elog(LOG, "VDATAPTR %p, tmpDatum %p, len %zu, VHDRSZ %zu", (void *)VDATAPTR(var), (Pointer) tmpDatum, len, VHDRSZ);
		memcpy(ptr, (Pointer) tmpDatum, len);
	}

  if (do_pop)
		SPI_pop();
	else
		SPI_finish();

	PG_RETURN_POINTER(var);
}

char *
get_cstring(Oid intTypeOid, MemoryContext ctx, Datum dat)
{
	char					 *output;
	Oid							typIoFunc;
	bool						isvarlena;
	FmgrInfo	 			proc;

	getTypeOutputInfo(intTypeOid, &typIoFunc, &isvarlena);
	fmgr_info_cxt(typIoFunc, &proc, ctx);
	output = OutputFunctionCall(&proc, dat);

	return output;
}

PG_FUNCTION_INFO_V1(variant_out);
Datum
variant_out(PG_FUNCTION_ARGS)
{
	Datum						input_datum = PG_GETARG_DATUM(0);
	Variant					input = (Variant) PG_DETOAST_DATUM_COPY(input_datum);
	Oid							intTypeOid = InvalidOid;
	Oid							orgTypeOid = input->typeOid;
	Datum						orig_datum;
	bool						isvarlena;
	bool						need_quote;
	FmgrInfo	 			proc;
	char						*tmp;
	char						*org_cstring;
	StringInfoData	out;
	int16 					typLen;
	bool 						typByVal;
	char						typAlign;
	char						typDelim;
	Oid							typIoParam;
	Oid							typIoFunc;

	/* Get cstring of original data */
	get_type_io_data(orgTypeOid,
						 IOFunc_output,
						 &typLen,
						 &typByVal,
						 &typAlign,
						 &typDelim,
						 &typIoParam,
						 &typIoFunc);
	fmgr_info_cxt(typIoFunc, &proc, fcinfo->flinfo->fn_mcxt);
	if( typByVal )
		orig_datum = *VDATAPTR(input);
	else
		orig_datum = VDATAPTR(input);
	org_cstring = OutputFunctionCall(&proc, orig_datum);

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

	/* format_type_by handles quoting for us */
	appendStringInfoChar(&out, '(');
	appendStringInfoString(&out, format_type_be(input->typeOid));
	appendStringInfoChar(&out, ',');

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

Oid
getIntOid()
{
	int		ret;
	bool	isnull;

	/*
	 * Get OID of our internal data type. This is necessary because record_in and
	 * record_out need it.
	 */
	if (!(ret = SPI_execute("SELECT '_variant._variant'::regtype::oid", true, 1)))
		elog( ERROR, "SPI_execute returned %s", SPI_result_code_string(ret));

	return DatumGetObjectId( heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull) );
}
// vi: noexpandtab sw=2 ts=2
