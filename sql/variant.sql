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

CREATE OR REPLACE FUNCTION _variant.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  RAISE DEBUG 'Executing SQL %s', sql;
  EXECUTE sql;
END
$f$;

CREATE TYPE _variant._variant AS ( original_type text, data text );

CREATE TYPE variant.variant;
CREATE OR REPLACE FUNCTION _variant._variant_in(cstring, Oid, int)
RETURNS variant.variant
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_in';
CREATE OR REPLACE FUNCTION _variant._variant_typmod_in(cstring[])
RETURNS int
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_typmod_in';
CREATE OR REPLACE FUNCTION variant.text_in(text)
RETURNS variant.variant
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_text_in';

CREATE OR REPLACE FUNCTION _variant._variant_out(variant.variant)
RETURNS cstring
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_out';
CREATE OR REPLACE FUNCTION _variant._variant_typmod_out(int)
RETURNS cstring
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_typmod_out';
CREATE OR REPLACE FUNCTION variant.text_out(variant.variant)
RETURNS text
LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_text_out';

CREATE TYPE variant.variant(
  INPUT = _variant._variant_in
  , OUTPUT = _variant._variant_out
  , TYPMOD_IN = _variant._variant_typmod_in
  , TYPMOD_OUT = _variant._variant_typmod_out
  , STORAGE = extended
);

SELECT _variant.exec( format($$
CREATE OR REPLACE FUNCTION _variant.variant_%1$s(variant.variant, variant.variant)
  RETURNS boolean LANGUAGE c IMMUTABLE STRICT AS '$libdir/variant', 'variant_%1$s';
  $$
  , op
) )
FROM unnest(string_to_array('lt le eq ne ge gt', ' ')) AS op;

CREATE OPERATOR < (
  PROCEDURE = _variant.variant_lt
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = >
  , NEGATOR = >=
);
CREATE OPERATOR <= (
  PROCEDURE = _variant.variant_le
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = >=
  , NEGATOR = >
);
CREATE OPERATOR = (
  PROCEDURE = _variant.variant_eq
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = =
  , NEGATOR = !=
);
CREATE OPERATOR != (
  PROCEDURE = _variant.variant_ne
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = !=
  , NEGATOR = =
);
CREATE OPERATOR >= (
  PROCEDURE = _variant.variant_ge
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = <=
  , NEGATOR = <
);
CREATE OPERATOR > (
  PROCEDURE = _variant.variant_gt
  , LEFTARG = variant.variant
  , RIGHTARG = variant.variant
  , COMMUTATOR = <
  , NEGATOR = <=
);

CREATE OR REPLACE VIEW _variant.allowed_types AS
  SELECT t.oid::regtype AS type_name
      , 'variant.variant'::regtype AS source
      , 'variant.variant'::regtype AS target
    FROM pg_catalog.pg_type t
      LEFT JOIN pg_catalog.pg_type e ON e.oid = t.typelem
    WHERE true
      AND t.typisdefined
      AND t.typtype != 'c' -- We don't currently support composite types
      AND (e.typtype IS NULL OR e.typtype != 'c' ) -- Or arrays of composite types
      AND t.typtype != 'p' -- Or pseudotypes
      AND t.typtype != 'd' -- You can't cast to or from domains :(
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

CREATE OR REPLACE VIEW variant.variant_casts AS
  SELECT *
    FROM _variant.casts
    WHERE false
      OR source = 'variant.variant'::regtype
      OR target = 'variant.variant'::regtype
;

CREATE OR REPLACE VIEW _variant.missing_casts_in AS
  SELECT t.type_name AS source, target
    FROM _variant.allowed_types t
  EXCEPT
  SELECT source, target FROM variant.variant_casts
  EXCEPT
  SELECT 'variant.variant', 'variant.variant'
;

CREATE OR REPLACE VIEW _variant.missing_casts_out AS
  SELECT source, t.type_name AS target
    FROM _variant.allowed_types t
  EXCEPT
  SELECT source, target FROM variant.variant_casts
  EXCEPT
  SELECT 'variant.variant', 'variant.variant'
;

CREATE OR REPLACE VIEW variant.missing_casts AS
  SELECT *, 'IN' AS direction
    FROM _variant.missing_casts_in
  UNION ALL
  SELECT *, 'OUT' AS direction
    FROM _variant.missing_casts_out
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
) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM _variant.exec(
    format(
      $sql$CREATE OR REPLACE FUNCTION _variant.cast_in(
      i %s
      , typmod int
      , explicit boolean
    ) RETURNS variant.variant LANGUAGE c IMMUTABLE AS '$libdir/variant', 'variant_cast_in'
      $sql$
      , p_source -- i data type
    )
  );
  PERFORM _variant.exec(
    format( 'CREATE CAST( %s AS variant.variant ) WITH FUNCTION _variant.cast_in( %1$s, int, boolean ) AS ASSIGNMENT'
      , p_source
    )
  );
END
$f$;

CREATE OR REPLACE FUNCTION _variant.create_cast_out(
  p_target    regtype
) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_function_name name :=
    'cast_to_'
    || regexp_replace(
          CASE WHEN p_target::text LIKE '%[]'
            THEN '_' || regexp_replace( p_target::text, '\[]$', '' )
          ELSE p_target::text
          END
          , '[\. "]' -- Replace invarid identifier characters with '_'
          , '_'
          , 'g' -- Replace globally
        )
  ;
BEGIN
  PERFORM _variant.exec(
    format(
      $sql$CREATE OR REPLACE FUNCTION _variant.%s(
      v variant.variant
    ) RETURNS %1s LANGUAGE c IMMUTABLE AS '$libdir/variant', 'variant_cast_out'
      $sql$
      , v_function_name
      , p_target
    )
  );
  PERFORM _variant.exec(
    format( 'CREATE CAST( variant.variant AS %s) WITH FUNCTION _variant.%s( variant.variant ) AS ASSIGNMENT'
      , p_target
      , v_function_name
    )
  );
END
$f$;

CREATE OR REPLACE FUNCTION variant.create_casts()
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  r variant.missing_casts;
  sql text;
BEGIN
  FOR r IN
    SELECT * FROM variant.missing_casts
  LOOP
    IF r.direction = 'IN' THEN
      PERFORM _variant.create_cast_in( r.source );
    ELSIF r.direction = 'OUT' THEN
      PERFORM _variant.create_cast_out( r.target );
    ELSE
      RAISE EXCEPTION 'Unknown cast direction "%"', r.direction;
    END IF;
  END LOOP;
END
$f$;

-- Automagically create casts for everything we support
SELECT variant.create_casts();

CREATE TABLE _variant._registered(
  variant_typmod    SERIAL        PRIMARY KEY
      CONSTRAINT variant_typemod_minimum_value CHECK( variant_typmod >= -1 )
  , variant_name    varchar(100)  NOT NULL
);
CREATE UNIQUE INDEX _registered_u_lcase_variant_name ON _variant._registered( lower( variant_name ) );

INSERT INTO _variant._registered VALUES( -1, 'DEFAULT' );

CREATE VIEW variant.registered AS SELECT * FROM _variant._registered;

CREATE OR REPLACE FUNCTION variant.register(
  p_variant_name _variant._registered.variant_name%TYPE
) RETURNS _variant._registered.variant_typmod%TYPE
LANGUAGE plpgsql AS $func$
DECLARE
  ret _variant._registered.variant_typmod%TYPE;
BEGIN
  IF p_variant_name IS NULL THEN
    RAISE EXCEPTION 'variant_name may not be NULL';
  END IF;

  INSERT INTO _variant._registered( variant_name )
    VALUES( p_variant_name )
    RETURNING variant_typmod
    INTO ret
  ;

  RETURN ret;
END
$func$;

CREATE OR REPLACE FUNCTION _variant.registered__get(
  p_variant_typmod  _variant._registered.variant_typmod%TYPE
) RETURNS _variant._registered LANGUAGE plpgsql STABLE AS $f$
DECLARE
  r_variant _variant._registered%ROWTYPE;
BEGIN
  SELECT * INTO STRICT r_variant
      FROM _variant._registered
      WHERE variant_typmod = p_variant_typmod
  ;
  -- TODO: verify variant is enabled
  RETURN r_variant;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE EXCEPTION 'Invalid typmod %', coalesce(p_variant_typmod::text, '<>')
        USING ERRCODE = 'invalid_parameter_value'
      ;
END
$f$;
CREATE OR REPLACE FUNCTION _variant.registered__get__variant_name(
  _variant._registered.variant_typmod%TYPE
) RETURNS _variant._registered.variant_name%TYPE LANGUAGE sql STABLE AS $f$
SELECT variant_name FROM _variant.registered__get( $1 )
$f$;

CREATE OR REPLACE FUNCTION _variant.registered__get(
  p_variant_name _variant._registered.variant_name%TYPE
) RETURNS _variant._registered LANGUAGE plpgsql STABLE AS $f$
DECLARE
  r_variant _variant._registered%ROWTYPE;
BEGIN
  SELECT * INTO STRICT r_variant
      FROM _variant._registered
      WHERE lower( variant_name ) = lower( p_variant_name )
  ;
  -- TODO: verify variant is enabled
  RETURN r_variant;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE EXCEPTION 'Invalid variant type %', coalesce(p_variant_name, '<>')
        USING ERRCODE = 'invalid_parameter_value'
      ;
END
$f$;
CREATE OR REPLACE FUNCTION _variant.registered__get__typmod(
  _variant._registered.variant_name%TYPE
) RETURNS _variant._registered.variant_typmod%TYPE LANGUAGE sql STABLE AS $f$
SELECT variant_typmod FROM _variant.registered__get( $1 )
$f$;

-- vi: expandtab sw=2 ts=2
