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

CREATE TYPE _variant._variant AS ( original_type regtype, data text );

CREATE TYPE variant.variant;
CREATE OR REPLACE FUNCTION _variant._variant_in(cstring)
RETURNS variant.variant
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_in';

CREATE OR REPLACE FUNCTION _variant._variant_out(variant.variant)
RETURNS cstring
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_out';

CREATE TYPE variant.variant(
  INPUT = _variant._variant_in
  , OUTPUT = _variant._variant_out
  , STORAGE = extended
);

GRANT USAGE ON SCHEMA variant TO public;

CREATE OR REPLACE VIEW _variant.types AS
  SELECT oid::regtype AS type_name
      , 'variant.variant'::regtype AS source
      , 'variant.variant'::regtype AS target
    FROM pg_catalog.pg_type
    WHERE true
      AND typisdefined
      AND typrelid = 0 -- We don't currently support composite types
;

CREATE OR REPLACE VIEW _variant.casts AS
  SELECT castsource::regtype AS source, casttarget::regtype AS target
      , castfunc::regprocedure AS cast_function
      , CASE castcontext
          WHEN 'e' THEN 'explicit'
          WHEN 'a' THEN 'assignment'
          WHEN 'i' THEN 'implicit'
        END AS cast_context
      , CASE castmethod
          WHEN 'f' THEN 'function'
          WHEN 'i' THEN 'inout'
          WHEN 'b' THEN 'binary'
        END AS cast_method
    FROM pg_catalog.pg_cast c
;

CREATE OR REPLACE VIEW _variant.variant_casts AS
  SELECT *
    FROM _variant.casts
    WHERE false
      OR source = 'variant.variant'::regtype
      OR target = 'variant.variant'::regtype
;

CREATE OR REPLACE VIEW variant.missing_casts AS
  SELECT t.source, t.type_name AS target, 'TO' AS direction
    FROM _variant.types t
      LEFT JOIN _variant.casts c USING( source )
    WHERE c.source IS NULL
  UNION ALL
  SELECT t.type_name AS source, t.target, 'FROM'
    FROM _variant.types t
      LEFT JOIN _variant.casts c USING( target )
    WHERE c.target IS NULL
;

CREATE OR REPLACE FUNCTION _variant.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  RAISE DEBUG 'Executing SQL %s', sql;
  EXECUTE sql;
END
$f$;

CREATE OR REPLACE FUNCTION _variant.create_cast_in(
  p_source    regtype
  , p_target  regtype
) RETURNS void LANGUAGE sql AS $f$
SELECT
_variant.exec(
  format(
    $sql$CREATE FUNCTION _variant.cast_in(
    i %s
    , typmod int
  ) RETURNS %s LANGUAGE sql IMMUTABLE AS $cast_func$
    SELECT _variant.cast_in( %s, $1, $2 )
$cast_func$
    $sql$
    , $1 -- i data type
    , $2 -- return type
    , $1::oid -- cast_in first parameter
  )
)
$f$;

CREATE OR REPLACE FUNCTION variant.create_casts()
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  r variant.missing_casts;
  sql text;
BEGIN
  FOR r IN SELECT * FROM variant.missing_casts
  LOOP
    sql := format( $sql$CREATE CAST %s AS %s
        WITH FUNCTION _variant.cast
      $sql$ );
  END LOOP;
END
$f$;

-- vi: expandtab sw=2 ts=2
