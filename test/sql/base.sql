\set ECHO 0
BEGIN;
CREATE TEMP VIEW typmod_chars AS SELECT * FROM unnest( string_to_array('( ) " 99999', ' ') ) AS a(ch);

\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

\set ON_ERROR_STOP true

SELECT plan( (
	3 -- Simple cast, equality, NULL
	+1 -- DEFAULT is disabled
	+2 -- text in/out
	+4 -- register
	+6 -- register__get*
	+4 -- allowed types
	+2 -- typmod tests
	+ (SELECT count(*) FROM typmod_chars)
	+4 -- NULL
	+1 -- Type storage options
)::int );

SELECT is(
	'test'::text::variant.variant("test variant")::text
	, 'test'
	, 'cast to text'
);
SELECT is(
	'test'::text::variant.variant("test variant")
	, 'test'::text::variant.variant("test variant")
	, 'Check equality'
);
SELECT is(
	variant.text_in('(text,)', 'test variant')::text
	, NULL
	, 'Check NULL'
);
SELECT throws_ok(
	$$SELECT 't'::text::variant.variant$$
	, '22023'
	, 'variant.variant(DEFAULT) is disabled'
);

SELECT is(
	variant.text_in( '(bigint,1)'::text, 'TEST variant' )
	, variant.text_in( '(bigint,1)', 'test variant')
	, 'variant.text_in()'
);
SELECT is(
	variant.text_out( 'test'::text::variant.variant("test variant") )
	, '(text,test)'::text
	, 'variant.text_out()'
);

/*
 * variant register
 */
SELECT row_eq(
	'SELECT * FROM variant.registered WHERE variant_typmod = -1'
	, ROW( -1, 'DEFAULT', false, '{}'::regtype[] )::variant.registered
	, 'valid variant(DEFAULT)'
);

-- type_name is intentionally text because we want our output ordered by text, not OID
CREATE TEMP TABLE atypes AS SELECT t::text AS type_name FROM unnest( '{int4,int2}'::regtype[] ) t;
SELECT lives_ok(
	$test$CREATE TEMP TABLE test_typmod AS
				SELECT *, ' registration "TEST" (,/) variant '::text AS variant_name, true AS variant_enabled, '{int4,int2}'::regtype[]
					FROM variant.register( ' registration "TEST" (,/) variant ', array(SELECT type_name::regtype FROM atypes) ) AS r(variant_typmod)
	$test$
	, 'Register variant'
);
SELECT bag_eq(
	$$SELECT * FROM variant.registered WHERE variant_typmod IN (SELECT variant_typmod FROM test_typmod)$$
	, $$SELECT * FROM test_typmod$$
	, 'registration test variant correctly added'
);
-- Sanity-check typmod output. Technically a typmod test, but it uses the test variant we register here
SELECT is(
			pg_catalog.format_type('variant.variant'::regtype, variant_typmod)
			, format('variant.variant("%s")', regexp_replace(variant_name, '"', '""', 'g'))
			, 'Check format_type() output'
		)
	FROM test_typmod
;

/*
 * _variant.registered__get
 */
SELECT bag_eq(
	$$SELECT * FROM _variant.registered__get( ' registration "test" (,/) variant ' )$$ -- Verify case insensitive
	, $$SELECT * FROM test_typmod$$
	, '_variant.registered( text )'
);
SELECT bag_eq(
	$$SELECT * FROM _variant.registered__get( (SELECT variant_typmod FROM test_typmod) )$$
	, $$SELECT * FROM test_typmod$$
	, '_variant.registered( int )'
);
SELECT throws_ok(
	$$SELECT * FROM _variant.registered__get( 'bullshit registered test variant that should never actually exist' )$$
	, '22023'
	, 'Invalid variant type bullshit registered test variant that should never actually exist'
);
SELECT throws_ok(
	$$SELECT * FROM _variant.registered__get( NULL::text )$$
	, '22023'
	, 'Invalid variant type <>'
);
SELECT throws_ok(
	$$SELECT * FROM _variant.registered__get( -2 )$$
	, '22023'
	, 'Invalid typmod -2'
);
SELECT throws_ok(
	$$SELECT * FROM _variant.registered__get( NULL::int )$$
	, '22023'
	, 'Invalid typmod <>'
);

/*
 * Allowed types
 *
 * Note: if you move this before the _variant.registered__get testing you'll break that stuff
 */
SELECT results_eq(
	$$SELECT * FROM variant.allowed_types((SELECT variant_name FROM test_typmod))$$
	, $$SELECT * FROM atypes ORDER BY 1$$
	, 'Verify current allowed types'
);
INSERT INTO atypes VALUES('box');
SELECT results_eq(
	$$SELECT * FROM variant.add_type( (SELECT variant_name FROM test_typmod), 'box' )$$
	, $$SELECT * FROM atypes ORDER BY 1$$
	, 'test variant.add_type'
);
INSERT INTO atypes VALUES ('boolean'), ('point');
SELECT results_eq(
	$$SELECT * FROM variant.add_types( (SELECT variant_name FROM test_typmod), '{point,boolean}' )$$
	, $$SELECT * FROM atypes ORDER BY 1$$
	, 'test variant.add_types'
);
SELECT results_eq(
	$$SELECT * FROM variant.allowed_types( (SELECT variant_name FROM test_typmod) )$$
	, $$SELECT * FROM atypes ORDER BY 1$$
	, 'Verify newly added types'
);

/*
 * typmod testing
 */
SELECT lives_ok(
	$$SELECT variant.register(ch, '{int}') FROM typmod_chars$$
	, 'test valid variant names'
);
SELECT throws_ok(
	$$SELECT variant.register(!)$$
	, '42601'
);
SELECT lives_ok(
				format( $$CREATE TEMP TABLE %I(v %s)$$
						, 'typmod_test_' || ch
						, format_type( 'variant.variant'::regtype, variant_typmod )
					)
				, format('test variant name %s', ch)
			)
	FROM typmod_chars c
		JOIN _variant._registered r ON c.ch = r.variant_name
;

/*
 * transform_null_equals
 */
SET transform_null_equals = on;
SELECT is( NULL::int::variant.variant("test variant")::int = NULL, true, '(int,)::int = NULL' );
SELECT is( 1::int::variant.variant("test variant")::int = NULL, false, '(int,1)::int != NULL' );
SET transform_null_equals = off;
SELECT is( NULL::int::variant.variant("test variant")::int = NULL, NULL, '(int,)::int = NULL is NULL' );
SELECT is( 1::int::variant.variant("test variant")::int = NULL, NULL, '(int,1)::int != NULL is NULL' );

/*
 * This is just meant as a rough sanity-check that we are testing all expected
 * type storage methods. Note that we're only concerned about different
 * positive-size typlens due to alignment reasons, so we ignore ones that align
* to int.
 */
SELECT bag_eq(
	-- Don't use type aliases here!
	$$SELECT DISTINCT typbyval, typlen
		FROM pg_type
		WHERE (typlen <= 8 OR typlen % 4 != 0)
			AND oid = ANY( array( SELECT * FROM variant.allowed_types('test variant') ) )
	$$
	, $$SELECT DISTINCT typbyval, typlen FROM pg_type WHERE (typlen <= 8 OR typlen % 4 != 0) AND typname NOT IN( 'cstring', 'unknown' )$$
	, 'Verify we are testing all storage options'
);

SELECT finish();

-- vi: noexpandtab sw=4 ts=4
