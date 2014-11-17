#include "postgres.h"
#include "fmgr.h"
#include "parser/parse_type.h"

/*
 * You can include more files here if needed.
 * To use some types, you must include the
 * correct file here based on:
 * http://www.postgresql.org/docs/current/static/xfunc-c.html#XFUNC-C-TYPE-TABLE
 */

PG_MODULE_MAGIC;

Datum variantin(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(variantin);
Datum
variantin(PG_FUNCTION_ARGS)
{
	char	   *input_str = PG_GETARG_CSTRING(0);

}

// vi: noexpandtab sw=2 ts=2
