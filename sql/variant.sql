/*
 * Author: Jim Nasby
 * Created at: 2014-10-07 17:50:51 -0500
 *
 */


SET client_min_messages = warning;

-- If your extension will create a type you can
-- do somenthing like this

CREATE SCHEMA _variant;
CREATE SCHEMA variant;
GRANT USAGE ON SCHEMA variant TO public;

CREATE VIEW _variant.variant_casts AS
  SELECT *
    FROM (
      SELECT s.typname AS source, t.typname AS target, c.*
        FROM pg_cast c
          LEFT JOIN pg_type s ON s.oid = c.castsource
          LEFT JOIN pg_type t ON t.oid = c.casttarget
      ) a
    WHERE source = 'variant' OR target = 'variant'
;

CREATE TYPE _variant._variant AS ( original_type regtype, data text );

CREATE TYPE variant.variant;
CREATE OR REPLACE FUNCTION _variant._variant_in(cstring)
RETURNS variant.variant
LANGUAGE c IMMUTABLE STRICT
--AS 'MODULE_PATHNAME';
--AS '$libdir/variant';
AS '$libdir/variant', 'variant_in';

CREATE OR REPLACE FUNCTION _variant._variant_out(variant.variant)
RETURNS cstring
LANGUAGE c IMMUTABLE STRICT
--AS 'MODULE_PATHNAME';
AS '$libdir/variant', 'variant_out';

CREATE TYPE variant.variant(
  INPUT = _variant._variant_in
  , OUTPUT = _variant._variant_out
);


-- vi: expandtab sw=2 ts=2
