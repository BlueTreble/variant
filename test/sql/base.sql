\set ECHO none
BEGIN;
\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

CREATE TEMP VIEW typmod_chars AS SELECT * FROM unnest( string_to_array('( ) " 99999', ' ') ) AS a(ch);

SELECT plan( (
	3 -- Simple cast, equality, NULL
	+1 -- DEFAULT
	+2 -- text in/out
	+5 -- register
	+6 -- register__get*
	+5 -- allowed types
	+9 -- disallowed types
	+2 -- typmod tests
	+ (SELECT count(*) FROM typmod_chars)
	+4 -- NULL
	+1 -- Type storage options
	+3 -- Hash equality support
	+7 -- plpgsql
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
SELECT lives_ok(
	$$SELECT 't'::text::variant.variant$$
	, 'variant.variant() works'
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
SET ROLE = DEFAULT; -- Need to be SU/owner
SELECT row_eq(
	'SELECT * FROM variant.registered WHERE variant_typmod = -1'
	, ROW( -1, 'DEFAULT', true, false, 0 )::variant.registered
	, 'valid variant(DEFAULT)'
);

-- type_name is intentionally text because we want our output ordered by text, not OID
CREATE TEMP TABLE atypes AS SELECT t::text AS type_name FROM unnest( '{int4,int2}'::regtype[] ) t;

SELECT lives_ok(
	$test$CREATE TEMP TABLE test_typmod AS
				SELECT *, ' registration "TEST" (,/) variant '::text AS variant_name, true AS variant_enabled, false AS storage_allowed, '{int4,int2}'::regtype[]
					FROM variant.register( ' registration "TEST" (,/) variant ', array(SELECT type_name::regtype FROM atypes) ) AS r(variant_typmod)
	$test$
	, 'Register variant'
);

SELECT bag_eq(
	$$SELECT * FROM _variant._registered WHERE variant_typmod IN (SELECT variant_typmod FROM test_typmod)$$
	, $$SELECT * FROM test_typmod$$
	, 'registration test variant correctly added'
);
SELECT bag_eq(
	$$SELECT * FROM variant.registered WHERE variant_typmod IN (SELECT variant_typmod FROM test_typmod)$$
	, $$SELECT variant_typmod, _variant.quote_variant_name(variant_name), variant_enabled, storage_allowed, 2 FROM test_typmod$$
	, 'check variant.registered for newly added variant'
);
-- Sanity-check typmod output. Technically a typmod test, but it uses the test variant we register here
SELECT is(
			pg_catalog.format_type('variant.variant'::regtype, variant_typmod)
			, format('%s("%s")', 'variant.variant'::regtype, regexp_replace(variant_name, '"', '""', 'g'))
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
-- Verify handling of NULL
SELECT throws_ok(
	$$SELECT * FROM variant.add_type( (SELECT variant_name FROM test_typmod), NULL )$$
	, '23514'
	/*
	 * NOTE: We care about the actual error message to ensure there's a CHECK
	 * constraint on the table and not just something in the function. If you
	 * add a check to the function create another test to verify the table
	* CHECK still works.
	 */
	, 'new row for relation "_registered" violates check constraint "allowed_types_may_not_contain_nulls"'
	, 'NULLs not allowed in allowed_types'
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
SET ROLE = variant_test_role;

/*
 * Disallowed types
 */
SELECT throws_ok(
	$$SELECT pg_temp.su( $su$UPDATE _variant._registered SET allowed_types = allowed_types || array[NULL::regtype]$su$ )$$
	, 'new row for relation "_registered" violates check constraint "allowed_types_may_not_contain_nulls"'
);
SELECT lives_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.register('test allowed types', '{}', true)$su$ )$$
	, 'Register allowed types variant'
);
SELECT lives_ok(
	$$CREATE TEMP TABLE test_allowed(v variant.variant("test allowed types"))$$
	, $$Create table for testing allowed types$$
);
-- The allowed case is exercised by all other tests
SELECT throws_ok(
	$$INSERT INTO test_allowed VALUES( 1::int )$$
	, '22023'
	, 'type integer is not allowed in variant.variant(test allowed types)'
);
SELECT lives_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.add_type('test allowed types', 'int')$su$ )$$
	, $$Allow use of int$$
);
SELECT throws_ok(
	$$INSERT INTO test_allowed VALUES( 1::int2 )$$
	, '22023'
	, 'type smallint is not allowed in variant.variant(test allowed types)'
);
SELECT throws_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.remove_type('test allowed types', 'int')$su$ )$$
	, '2BP01'
	, 'variant "test allowed types" is still in use'
);
SELECT lives_ok(
	$$DROP TABLE test_allowed$$
	, 'Drop temp table'
);
SELECT lives_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.remove_type('test allowed types', 'int')$su$ )$$
	, 'remove type'
);

/*
 * typmod testing
 */
SELECT lives_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.register(ch, '{int}', true) FROM typmod_chars$su$ )$$
	, 'test valid variant names'
);
SELECT throws_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.register(!)$su$ )$$
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
		JOIN variant._registered r ON c.ch = r.variant_name
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
SET ROLE = DEFAULT; -- Need to be SU/owner
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
SET ROLE = variant_test_role;


/*
 * Test hash equality support
 *
 * Since this is here mostly to support things like variant[]=variant[] and
 * record(variant) = record(variant), that's how we test it.
 */

SELECT is(
	array[ 1::int::variant.variant ]
	, array[ 1::int::variant.variant ]
	, 'Test array equality'
);
SELECT lives_ok(
	$view$
CREATE TEMP VIEW test_row AS
	SELECT 1::int::variant.variant
	$view$
	, 'Create test view'
);
SELECT is(
			row( t.* )::test_row
			, row( t.* )::test_row
			, 'Test row equality'
		)
	FROM test_row t
;

/*
 * Test plpgsql
 */
SELECT lives_ok( $live$
CREATE TEMP VIEW test_cmp AS
	SELECT $template$
CREATE FUNCTION pg_temp.test_cmp_%s(
	p1 variant.variant(%2$s)
	, p2 variant.variant(%2$s)
) RETURNS pg_temp.cmp_out LANGUAGE plpgsql AS $f$
DECLARE
	-- Test assignment
	v1 variant.variant(%2$s) := p1;
	v2 variant.variant(%2$s) := p2;
	ret pg_temp.cmp_out;
BEGIN
	ret.lt := v1 < v2;
	ret.le := v1 <= v2;
	ret.eq := v1 = v2;
	ret.ge := v1 >= v2;
	ret.gt := v1 > v2;

	RETURN ret;
END
$f$
$template$::text AS template
	$live$
	, 'Create test template'
);

SELECT lives_ok(
	$live$
CREATE TYPE pg_temp.cmp_out AS(
	lt boolean
	, le boolean
	, eq boolean
	, ge boolean
	, gt boolean
);
	$live$
	, 'Create cmp_out type'
);
SELECT lives_ok(
	$$SELECT pg_temp.su( $su$SELECT variant.register( 'test no store' )$su$ )$$
	, 'Register "test no store" with no types to ensure we allow any type when NOT storage AND allowed_types is empty'
);

CREATE TEMP VIEW mod AS
	SELECT 1::int AS id, '"test variant"'::text AS mod
	UNION ALL SELECT 2, '"test no store"'
;
SELECT lives_ok(
			format( (SELECT template FROM test_cmp), id, mod )
			, 'Create test_cmp for ' || mod
		)
	FROM mod
;

SELECT is(
	pg_temp.test_cmp_1( 1::int, 2::int::variant.variant("test variant") )
	, (true, true, false, false, false)::cmp_out
	, 'Test results from "test variant"'
);
SELECT is(
	pg_temp.test_cmp_2( 1::int, 2::int::variant.variant("test no store") )
	, (true, true, false, false, false)::cmp_out
	, 'Test results from "test no store"'
);

SELECT finish();

-- vi: noexpandtab sw=4 ts=4
