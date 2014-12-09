\set ECHO 0
BEGIN;
\i test/tap_setup.sql
\i test/common.sql

CREATE TEMP TABLE ncmp_raw(
	l		variant.variant("test variant")
	, r		variant.variant("test variant")
	, lr	int
	, rr	int
);
INSERT INTO ncmp_raw
SELECT l, r, lr, rr
FROM (
	SELECT *
			/*
			 * Need to cast lr/rr to text because "blah" isn't actually a valid array and format() gets mad.
			 */
			, variant.text_in(format( $$(%s,%s)$$, t, '"' || lr::text || '"' ), 'test variant') AS l
			, variant.text_in(format( $$(%s,%s)$$, t, '"' || rr::text || '"' ), 'test variant') AS r
		FROM (
				SELECT *, 0::numeric AS lr, v::numeric AS rr
					FROM unnest(array[ '0', '1', '-1', NULL ]) AS vals(v)
						, unnest( string_to_array( 'int2 int4 int8 float real numeric', ' ' ) ) AS types(t)
			) a
	) a
;
CREATE OR REPLACE TEMP VIEW ncmp AS
	SELECT *
			, variant.text_out(l) AS l_text
			, variant.text_out(r) AS r_text
			, coalesce(lr::text, 'NULL') AS lr_text
			, coalesce(rr::text, 'NULL') AS rr_text
	FROM ncmp_raw
;
CREATE OR REPLACE TEMP VIEW ncmp_ops AS SELECT * FROM ncmp, ops;

CREATE TEMP TABLE _ncmp_raw(
	l		variant.variant("test variant")
	, r		variant.variant("test variant")
	, lr	numeric[]
	, rr	numeric[]
);
INSERT INTO _ncmp_raw
SELECT l, r, lr, rr
FROM (
	SELECT *
			/*
			 * Need to cast lr/rr to text because "blah" isn't actually a valid array and format() gets mad.
			 */
			, variant.text_in(format( $$(%s[],%s)$$, t, '"' || lr::text || '"' ), 'test variant') AS l
			, variant.text_in(format( $$(%s[],%s)$$, t, '"' || rr::text || '"' ), 'test variant') AS r
		FROM (
				SELECT *, '{0,1,1}'::numeric[] AS lr, v::numeric[] AS rr
					FROM unnest(array[ '{0,0,1}', '{0,1,1}', '{0,2,1}', '{NULL,1,1}', '{0,NULL,1}', '{0,1,NULL}', NULL ]) AS vals(v)
						, unnest( string_to_array( 'int2 int4 int8 float real numeric', ' ' ) ) AS types(t)
			) a
	) a
;
CREATE OR REPLACE TEMP VIEW _ncmp AS
	SELECT *
			, variant.text_out(l) AS l_text
			, variant.text_out(r) AS r_text
			, coalesce(lr::text, 'NULL') AS lr_text
			, coalesce(rr::text, 'NULL') AS rr_text
	FROM _ncmp_raw
;
CREATE OR REPLACE TEMP VIEW _ncmp_ops AS SELECT * FROM _ncmp, ops;

CREATE TEMP TABLE box_cmp_raw(
	l		variant.variant("test variant")
	, r		variant.variant("test variant")
	, lr	box
	, rr	box
);
-- DO NOT TOUCH! Change to the pattern we're using for _ncmp_raw's insert instead!
INSERT INTO box_cmp_raw(	l,		r								, lr					, rr	)
SELECT l, r, lr, rr
FROM (
	SELECT *
			/*
			 * Need to cast lr/rr to text because "blah" isn't actually a valid array and format() gets mad.
			 */
			, variant.text_in(format( $$(%s,%s)$$, t, '"' || lr::text || '"' ), 'test variant') AS l
			, variant.text_in(format( $$(%s,%s)$$, t, '"' || rr::text || '"' ), 'test variant') AS r
		FROM (
				SELECT *, '((0,0),(1,1))'::box AS lr, v::box AS rr
					FROM unnest(array[ '((0,0),(0.5,0.5))', '((0,0),(1,1))', '((-1,-1),(1,1))', NULL ]) AS vals(v) -- '' becomes a NULL
						, unnest( string_to_array( 'box', ' ' ) ) AS types(t)
			) a
	) a
;
CREATE OR REPLACE TEMP VIEW box_cmp AS
	SELECT *
			, variant.text_out(l) AS l_text
			, variant.text_out(r) AS r_text
			, coalesce(lr::text, 'NULL') AS lr_text
			, coalesce(rr::text, 'NULL') AS rr_text
	FROM box_cmp_raw
;
CREATE OR REPLACE TEMP VIEW box_cmp_ops AS SELECT * FROM box_cmp, ops WHERE btrim(op) NOT IN ( '!=', '<>' );

\set ON_ERROR_STOP true

SELECT plan( (
	3 -- Simple cast, equality, NULL
	+2 -- text in/out
	+3 -- register
	+6 -- register__get*
	+4 -- NULL
	+ (SELECT count(*)::int FROM ncmp_ops)
	+ (SELECT count(*)::int FROM _ncmp_ops)
	+ (SELECT count(*)::int FROM box_cmp_ops)
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

SELECT is( (SELECT count(*)::int FROM ncmp WHERE r IS NULL), 1 );
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$variant.text_in(%L, 'test variant') %s variant.text_in(%L, 'test variant')
					, %s %s %s
					, $$%L %s %L$$$fmt$
				, l, op, r
				, lr_text, op, rr_text
				, rpad(l_text, len_l), op, rpad(r_text, len_r)
			)
		)
	FROM ncmp_ops
		, (SELECT max(length(l_text)) AS len_l, max(length(r_text)) AS len_r FROM ncmp) l
;
SELECT is( (SELECT count(*)::int FROM _ncmp WHERE r IS NULL), 1 );
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$variant.text_in(%L, 'test variant') %s variant.text_in(%L, 'test variant')
					, %L::numeric[] %s %L::numeric[]
					, $$%L::numeric[] %s %L::numeric[]$$$fmt$
				, l, op, r
				, lr, op, rr
				, rpad(l_text, len_l), op, rpad(r_text, len_r)
			)
		)
	FROM _ncmp_ops
		, (SELECT max(length(l_text)) AS len_l, max(length(r_text)) AS len_r FROM _ncmp) l
;

--SET client_min_messages = debug;
SELECT is( (SELECT count(*)::int FROM box_cmp WHERE r IS NULL), 1 );
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$variant.text_in(%L, 'test variant') %s variant.text_in(%L, 'test variant')
					, %L::box %s %L::box
					, $$%L::box %s %L::box$$$fmt$
				, l, op, r
				, lr, op, rr
				, rpad(l_text, len_l), op, rpad(r_text, len_r)
			)
		)
	FROM box_cmp_ops
		, (SELECT max(length(l_text)) AS len_l, max(length(r_text)) AS len_r FROM box_cmp) l
;

SELECT finish();
ROLLBACK;

-- vi: noexpandtab sw=4 ts=4
