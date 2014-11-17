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

/*
CREATE VIEW _variants.types

CREATE VIEW variant.defined_casts AS
;

CREATE FUNCTION variant.update_casts()
  RETURNS void
  LANGUAGE plpgsql
  AS $body$
DECLARE
BEGIN
END
$body$
;
*/

-- I'd much prefer to create a domain on top of a composite type, but Postgres doesn't allow that :(
CREATE DOMAIN variant.variant AS text[];
CREATE TYPE _variant._variant AS ( original_type regtype, data text );

CREATE FUNCTION _variant.sanity(
  p_in _variant._variant
) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $body$
DECLARE
BEGIN

  /*
   * We check the correctness of the supplied type by attempting to cast back to that type.
   */

  RAISE DEBUG 'validate using %', $$SELECT $$ || quote_literal( p_in[1] ) || $$::$$ || p_in[2];
  EXECUTE $$SELECT $$ || quote_literal( p_in[1] ) || $$::$$ || p_in[2];

  -- If our input wasn't valid we'd have an error already
  RETURN true;
END
$body$;

CREATE FUNCTION test(
  p_in _variant._variant
) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $body$
DECLARE
BEGIN

  /*
   * We check the correctness of the supplied type by attempting to cast back to that type.
   */

  RAISE DEBUG 'validate';

  -- If our input wasn't valid we'd have an error already
  RETURN true;
END
$body$;

--CREATE OR REPLACE FUNCTION test(variant.variant) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true';

ALTER DOMAIN variant.variant
  --ADD CHECK( _variant.sanity( VALUE ) )
  ADD CHECK( test(VALUE) )
;
CREATE CAST (variant.variant AS _variant._variant) WITH INOUT AS IMPLICIT;

CREATE FUNCTION _variant.to_text(variant.variant) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT $1[1]::text';
CREATE CAST( variant.variant AS text ) WITH FUNCTION _variant.to_text( variant.variant) AS ASSIGNMENT;


-- vi: expandtab sw=2 ts=2
