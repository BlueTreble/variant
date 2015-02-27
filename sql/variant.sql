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
-- See also second definition at bottom of file
CREATE OR REPLACE FUNCTION variant.text_in(text, int)
RETURNS variant.variant
LANGUAGE c IMMUTABLE
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

-- Can only create this after type is fully created
CREATE OR REPLACE FUNCTION variant.text_in(text)
RETURNS variant.variant LANGUAGE sql IMMUTABLE STRICT AS $f$
SELECT variant.text_in( $1, -1 )
$f$;

CREATE OR REPLACE FUNCTION _variant.quote_variant_name(text)
RETURNS text LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'quote_variant_name';
CREATE OR REPLACE FUNCTION variant.original_type(variant.variant)
RETURNS text LANGUAGE c IMMUTABLE STRICT
AS '$libdir/variant', 'variant_type_out';

SELECT NULL = count(*) FROM ( -- Supress tons of blank lines
SELECT _variant.exec( format($$
CREATE OR REPLACE FUNCTION _variant.variant_%1$s(variant.variant, variant.variant)
  RETURNS boolean LANGUAGE c IMMUTABLE STRICT AS '$libdir/variant', 'variant_%1$s';
  $$
  , op
) )
FROM unnest(string_to_array('lt le eq ne ge gt', ' ')) AS op
) a;

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
  , variant_enabled boolean       NOT NULL DEFAULT true
  , allowed_types   regtype[]     NOT NULL
    CONSTRAINT allowed_types_may_not_contain_nulls
      /*
       * Make sure there's no NULLs in allowed_types. Aside from being a good
       * idea, this is required by _variant._tg_check_type_usage.
       */
      CHECK( allowed_types = array_remove(allowed_types, NULL) )
);
CREATE UNIQUE INDEX _registered_u_lcase_variant_name ON _variant._registered( lower( variant_name ) );

INSERT INTO _variant._registered VALUES( -1, 'DEFAULT', false, '{}' );

CREATE VIEW variant.registered AS
  SELECT variant_typmod, _variant.quote_variant_name(variant_name), variant_enabled, coalesce( array_length(allowed_types, 1), 0 ) AS types_allowed
    FROM _variant._registered
;
CREATE VIEW _variant.stored AS
  SELECT atttypmod AS variant_typmod, quote_ident(attname) AS column_name, a.*
    FROM pg_attribute a
    WHERE NOT attisdropped
      AND atttypid = 'variant.variant'::regtype
      -- NOTE: We intentionally look at all temp tables, not just our own
;

CREATE VIEW variant.stored AS
  SELECT *
      , array( SELECT attrelid::regclass || '.' || column_name FROM _variant.stored WHERE variant_typmod = r.variant_typmod )
          AS columns_using_variant
    FROM variant.registered r
;

CREATE OR REPLACE FUNCTION _variant._tg_check_type_usage(
) RETURNS trigger LANGUAGE plpgsql AS $f$
/*
 * Verify that if we're removing a type from the list of allowed types that
 * this registered variant isn't being used in a table anywhere.
 *
 * TODO: We should have a way to verify that a table doesn't contain any rows
 * with a particular type.
 */
DECLARE
  v_columns text[];
  v_new _variant._registered.allowed_types%TYPE;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.allowed_types @> OLD.allowed_types THEN
      -- User didn't remove any types
      RETURN NULL;
    END IF;

    v_new := NEW.allowed_types;
  ELSE
    v_new := '{}';
  END IF;

  v_columns := columns_using_variant FROM variant.stored WHERE variant_typmod = OLD.variant_typmod;
  RAISE DEBUG 'TG_OP: %, OLD.allowed_types %, NEW.allowed_types %, v_columns %'
    , TG_WHEN
    , OLD.allowed_types
    , v_new
    , v_columns
  ;
  IF v_columns IS DISTINCT FROM '{}' THEN
    RAISE EXCEPTION 'variant % is still in use', OLD.variant_name
      USING ERRCODE = 'dependent_objects_still_exist'
        , DETAIL = E'in use by ' || array_to_string( v_columns, ', ' )
    ;
  END IF;

  RETURN NULL;
END
$f$;
CREATE TRIGGER check_type_usage
  AFTER UPDATE OR DELETE ON _variant._registered
  FOR EACH ROW
  EXECUTE PROCEDURE _variant._tg_check_type_usage()
;

CREATE OR REPLACE FUNCTION variant.register(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_allowed_types _variant._registered.allowed_types%TYPE
) RETURNS _variant._registered.variant_typmod%TYPE
LANGUAGE plpgsql AS $func$
DECLARE
  c_test_table CONSTANT text := 'test_ability_to_create_table_with_just_registered_variant';
  v_formatted_type text;
  ret _variant._registered.variant_typmod%TYPE;
BEGIN
  IF p_variant_name IS NULL THEN
    RAISE EXCEPTION 'variant_name may not be NULL';
  END IF;
  IF p_variant_name = '' THEN
    RAISE EXCEPTION 'variant_name may not be an empty string';
  END IF;

  INSERT INTO _variant._registered( variant_name, allowed_types )
    VALUES( p_variant_name, p_allowed_types )
    RETURNING variant_typmod
    INTO ret
  ;
  v_formatted_type := pg_catalog.format_type( 'variant.variant'::regtype, ret );

  -- This ensures that the user can actually use the variant that they're registering
  BEGIN
    PERFORM _variant.exec(format(
        $$CREATE TEMP TABLE %I(v %s)$$
        , c_test_table
        , v_formatted_type
    ));
  EXCEPTION
    WHEN syntax_error THEN
      RAISE EXCEPTION '% is not a valid name for a variant', p_variant_name
        USING ERRCODE = 'syntax_error'
          , HINT = 'variant names must be valid type modifiers: string literals or numbers'
          , DETAIL = 'formatted type output: ' || coalesce(v_formatted_type, '<>')
      ;
  END;
  PERFORM _variant.exec(format(
      $$DROP TABLE %I$$
      , c_test_table
  ));

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
  RETURN r_variant;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE EXCEPTION 'Invalid typmod %', coalesce(p_variant_typmod::text, '<>')
        USING ERRCODE = 'invalid_parameter_value'
      ;
END
$f$;
CREATE OR REPLACE FUNCTION _variant.registered__get__variant_name__enabled(
  _variant._registered.variant_typmod%TYPE
) RETURNS TABLE(
  variant_name _variant._registered.variant_name%TYPE
  , variant_enabled _variant._registered.variant_enabled%TYPE
) LANGUAGE sql STABLE AS $f$
SELECT variant_name, variant_enabled FROM _variant.registered__get( $1 )
$f$;

-- TODO: Might want a non-locking version of this that we can mark stable
CREATE OR REPLACE FUNCTION _variant.registered__get(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_lock boolean DEFAULT false
) RETURNS _variant._registered LANGUAGE plpgsql AS $f$
DECLARE
  r_variant _variant._registered%ROWTYPE;
BEGIN
  IF p_lock THEN
    SELECT * INTO STRICT r_variant
        FROM _variant._registered
        WHERE lower( variant_name ) = lower( p_variant_name )
        FOR UPDATE
    ;
  ELSE
    SELECT * INTO STRICT r_variant
        FROM _variant._registered
        WHERE lower( variant_name ) = lower( p_variant_name )
    ;
  END IF;
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

CREATE OR REPLACE FUNCTION variant.text_in(text, text)
RETURNS variant.variant LANGUAGE sql IMMUTABLE STRICT AS $f$
SELECT variant.text_in( $1, _variant.registered__get__typmod($2) )
$f$;

CREATE OR REPLACE FUNCTION variant.allowed_types(
  p_variant_name _variant._registered.variant_name%TYPE
) RETURNS TABLE(allowed_type regtype) LANGUAGE sql STABLE AS $f$
  SELECT *
    FROM unnest(
        ( SELECT allowed_types FROM _variant.registered__get( p_variant_name ) )
      ) t(t)
    ORDER BY t::text
  ;
$f$;

CREATE OR REPLACE FUNCTION variant.add_types(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_allowed_types _variant._registered.allowed_types%TYPE
) RETURNS TABLE(allowed_type regtype)
LANGUAGE plpgsql AS $f$
DECLARE
  v_new_allowed _variant._registered.allowed_types%TYPE;
  v_current record;
BEGIN
  -- Lock this record when we get it
  v_current := _variant.registered__get( p_variant_name, true );

  UPDATE _variant._registered
    -- It seems worthwhile to keep stuff unique
    SET allowed_types = array(
        SELECT * FROM unnest( v_current.allowed_types )
        UNION ALL
        SELECT * FROM unnest( p_allowed_types )
      )
    WHERE variant_typmod = v_current.variant_typmod
    RETURNING allowed_types INTO v_new_allowed
  ;
  RETURN QUERY SELECT t FROM unnest(v_new_allowed) t(t) ORDER BY t::text;
END
$f$;
CREATE OR REPLACE FUNCTION variant.add_type(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_type text
) RETURNS TABLE(allowed_type regtype) LANGUAGE sql AS $f$
  SELECT * FROM variant.add_types($1,array[ $2::regtype ])
$f$;

CREATE OR REPLACE FUNCTION variant.remove_types(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_removed_types _variant._registered.allowed_types%TYPE
) RETURNS TABLE(allowed_type regtype)
LANGUAGE plpgsql AS $f$
DECLARE
  v_new_allowed _variant._registered.allowed_types%TYPE;
  v_current record;
BEGIN
  -- Lock this record when we get it
  v_current := _variant.registered__get( p_variant_name, true );
  IF NOT v_current.allowed_types && p_removed_types THEN
    IF array_length(p_removed_types, 1) = 1 THEN
      RAISE NOTICE 'type %s was already not allowed in variant %s', p_removed_types[1], v_current.variant_name;
    ELSE
      RAISE NOTICE 'types %s were already not allowed in variant %s', p_removed_types, v_current.variant_name;
    END IF;
    v_new_allowed := v_current.allowed_types;
  ELSE
    UPDATE _variant._registered
      -- It seems worthwhile to keep stuff unique
      SET allowed_types = array(
          SELECT t
            FROM unnest( v_current.allowed_types ) t
            WHERE t != ANY( p_removed_types )
        )
      WHERE variant_typmod = v_current.variant_typmod
      RETURNING allowed_types INTO v_new_allowed
    ;
  END IF;

  RETURN QUERY SELECT t FROM unnest(v_new_allowed) t(t) ORDER BY t::text;
END
$f$;
CREATE OR REPLACE FUNCTION variant.remove_type(
  p_variant_name _variant._registered.variant_name%TYPE
  , p_type text
) RETURNS TABLE(allowed_type regtype) LANGUAGE sql AS $f$
  SELECT * FROM variant.remove_types($1,array[ $2::regtype ])
$f$;

-- vi: expandtab sw=2 ts=2
