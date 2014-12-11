\set ECHO 0
BEGIN;
\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

\set ON_ERROR_STOP true

SELECT plan( (
	3 -- Simple cast, equality, NULL
	+1 -- DEFAULT is disabled
	+2 -- text in/out
	+3 -- register
	+6 -- register__get*
	+4 -- NULL
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
	, ROW( -1, 'DEFAULT', false )::variant.registered
	, 'valid variant(DEFAULT)'
);
SELECT lives_ok(
	$test$CREATE TEMP TABLE test_typmod AS SELECT *, ' registration test variant '::text AS variant_name, true AS variant_enabled FROM variant.register( ' registration test variant ' ) AS r(variant_typmod)$test$
	, 'Register variant'
);
SELECT bag_eq(
	$$SELECT * FROM variant.registered WHERE variant_typmod IN (SELECT variant_typmod FROM test_typmod)$$
	, $$SELECT * FROM test_typmod$$
	, 'registration test variant correctly added'
);

/*
 * _variant.registered__get
 */
SELECT bag_eq(
	$$SELECT * FROM _variant.registered__get( ' registration TEST variant ' )$$ -- Verify case insensitive
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



SET transform_null_equals = on;
SELECT is( NULL::int::variant.variant("test variant")::int = NULL, true, '(int,)::int = NULL' );
SELECT is( 1::int::variant.variant("test variant")::int = NULL, false, '(int,1)::int != NULL' );
SET transform_null_equals = off;
SELECT is( NULL::int::variant.variant("test variant")::int = NULL, NULL, '(int,)::int = NULL is NULL' );
SELECT is( 1::int::variant.variant("test variant")::int = NULL, NULL, '(int,1)::int != NULL is NULL' );

SELECT finish();
ROLLBACK;

-- vi: noexpandtab sw=4 ts=4
