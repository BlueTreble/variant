#include "postgres.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "access/htup_details.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "utils/typcache.h"
#include "utils/lsyscache.h"
#include "variant.h"

/*
 * You can include more files here if needed.
 * To use some types, you must include the
 * correct file here based on:
 * http://www.postgresql.org/docs/current/static/xfunc-c.html#XFUNC-C-TYPE-TABLE
 */

#define INTERNAL_TYPE_CSTRING "_variant._variant\0"

PG_MODULE_MAGIC;

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
	Datum						composite;
	HeapTupleHeader	composite_tuple;
	Oid							intTypeOid = InvalidOid;
	Datum						intType;
	int32						typmod = 0;
	TupleDesc				tupdesc;
	HeapTuple				tuple = NULL;
	int							ncolumns;
	Datum					 *values;
	bool					 *nulls;
	Oid							typiofunc;
	Oid							typioparam;
	FmgrInfo	 		 *proc = NULL;
	bool						isnull;
	Oid							orgTypeOid;
	char					 *orgTypeName;
	StringInfoData	cmd;
	bool						do_pop = false;
	int							ret;

	if (!SPI_connect()) {
		do_pop = true;
		SPI_push();
	}

	/*
	 * Get OID of our internal data type. This is necessary because record_in
	 * needs it.
	 *
	 * TODO: Do our own error reporting instead of confusing error
	 * parseTypeString will give us if our internal type doesn't exist.
	 */
	if (!(ret = SPI_execute("SELECT '_variant._variant'::regtype::oid", true, 1)))
		elog( ERROR, "SPI_execute returned %s", SPI_result_code_string(ret));

	intType = heap_getattr(SPI_tuptable->vals[0], 1, SPI_tuptable->tupdesc, &isnull);
	intTypeOid = DatumGetObjectId(intType);

	/* Cast input data to our internal composite type */
	getTypeInputInfo(intTypeOid, &typiofunc, &typioparam);
	fmgr_info_cxt(typiofunc, proc, fcinfo->flinfo->fn_mcxt);
	composite=InputFunctionCall(proc, PG_GETARG_CSTRING(0), typioparam, typmod);
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
	heap_deform_tuple(tuple, tupdesc, values, nulls);

	/* Get the type information for the type *that was passed in* */
	if(nulls[0])
		elog(ERROR, "input type can not be NULL");

	orgTypeOid = DatumGetObjectId(values[0]);
	orgTypeName = format_type_be(orgTypeOid);

	/* Make sure we can legitimately cast our input to the passed in type */
	initStringInfo(&cmd);

	/*
	 * $1 is our raw input. Cast it to internal composite, extract data
	 * portion, and attempt cast.
	 */
	appendStringInfo(&cmd,
			"SELECT CAST( (v).data AS %s ) FROM (SELECT $1::_variant._variant AS v) a",
			orgTypeName);

	if (!(ret = SPI_execute_with_args(cmd.data, 1, &intTypeOid, &PG_GETARG_DATUM(0), PG_ARGISNULL(0) ? "n" : " ", true, 1)))
		elog(ERROR, "SPI_execute_with_args returned %s", SPI_result_code_string(ret));

  if (do_pop)
		SPI_pop();

	return composite;
}

// vi: noexpandtab sw=2 ts=2
