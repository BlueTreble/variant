#include "postgres.h"
#include "fmgr.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"
#include "executor/spi.h"

/*
 * You can include more files here if needed.
 * To use some types, you must include the
 * correct file here based on:
 * http://www.postgresql.org/docs/current/static/xfunc-c.html#XFUNC-C-TYPE-TABLE
 */

#define INTERNAL_TYPE_CSTRING '_variant._variant\0'

PG_MODULE_MAGIC;

/* fn_extra cache entry for IO functions */
typedef struct IOData
{
	TypeCacheEntry *typcache;	/* range type's typcache entry */
	Oid			typiofunc;		/* element type's I/O function */
	Oid			typioparam;		/* element type's I/O parameter */
	FmgrInfo	proc;			/* lookup result for typiofunc */
} RangeIOData;


/*
 * variantin: Parse text representation of a variant
 *
 * - Cast to _variant._variant
 * - Extract type name and validate
 * 
 * TODO: use type's input function to convert type info to internal format. For
 * now, just store the raw _variant._variant Datum.
 */
PG_FUNCTION_INFO_V1(variantin);
Datum
variantin(PG_FUNCTION_ARGS)
{
	char	   *in = PG_GETARG_CSTRING(0);
	

	Datum						composite;
	HeapTupleHeader	composite_tuple;
	Oid							intTypeOid = InvalidOid;
	int32						typmod;
	TupleDesc				tupdesc;
	HeapTupleData		tuple;
	Datum					 *values;
	bool					 *nulls;
	Oid			typiofunc;
	Oid			typioparam;
	FmgrInfo	proc;
	bool						isnull;
	Oid							orgTypeOid;
	char					 *orgTypeName;
	StringInfoData	cmd;
	bool						do_pop = false;

	/*
	 * Get OID of our internal data type. This is necessary because record_in
	 * needs it.
	 *
	 * TODO: Do our own error reporting instead of confusing error
	 * parseTypeString will give us if our internal type doesn't exist.
	 */
	parseTypeString(INTERNAL_TYPE_CSTRING, &intTypeOid, &typmod, false);
	getTypeInputInfo(intTypeOid, &typiofunc, &typioparam);
	fmgr_info_cxt(typiofunc, &proc, fcinfo->flinfo->fn_mcxt);

	/* Cast input data to our internal composite type */
	composite=InputFunctionCall(proc, PG_GETARG_CSTRING(0), typeioparam, typmod);
	composite_tuple=DatumGetHeapTupleHeader(composite);

	/* Extract data from internal composite type */
	tupdesc = lookup_rowtype_tupdesc(
									HeapTupleHeaderGetTypeId(composite_tuple),
									HeapTupleHeaderGetTypMod(composite_tuple)
			);
	ncolumns = tupdesc->natts;
	values = (Datum *) palloc(ncolumns * sizeof(Datum));
	nulls = (bool *) palloc(ncolumns * sizeof(bool));

	/* Break down the tuple into fields */
	heap_deform_tuple(&tuple, tupdesc, values, nulls);

	/* Get the type information for the type *that was passed in* */
	orgTypeOid = GetAttributeByNum(tuple, 1, &isnull);
	orgTypeName = format_type_be(orgTypeOid);

	/* Make sure we can legitimately cast our input to the passed in type */
	initString(&cmd);
	appendStringInfo(&buf,
			/*
			 * $1 is our raw input. Cast it to internal composite, extract data
			 * portion, and attempt cast.
			 */
			"SELECT CAST( (v).data AS %s ) FROM (SELECT $1::_variant._variant AS v) a",
			orgTypeName);

	if (!SPI_connect()) {
		do_pop = true;
		if (!(ret = SPI_push()))
			elog(ERROR, "SPI_push returned %s", SPI_result_code_string(ret));
	}

	if (!(ret = SPI_execute_with_args(cmd.data, 1, &intTypeOid, &PG_GETARG_DATUM(0), PG_ARGISNULL(0) ? "n" : " ", true, 1)))
		elog(ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

  if (do_pop)
		if (!(ret = SPI_pop()))
			elog(ERROR, "SPI_pop returned %s", SPI_result_code_string(ret));

	return composite;
}

// vi: noexpandtab sw=2 ts=2
