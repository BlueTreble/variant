\set ECHO 0
BEGIN;
\i test/pgtap-core.sql
\i sql/variant.sql

\pset format unaligned
\pset tuples_only true
\pset pager
-- Revert all changes on failure.
\set ON_ERROR_ROLLBACK 1
\set ON_ERROR_STOP true

CREATE OR REPLACE FUNCTION pg_temp.exec_text(
	sql text
	, VARIADIC v anyarray
) RETURNS SETOF text LANGUAGE plpgsql AS $f$
DECLARE
	v_sql text := format(sql, VARIADIC v);
	t text;
BEGIN
	RAISE DEBUG 'Executing % into text', v_sql;
	FOR t IN EXECUTE v_sql LOOP
		RETURN NEXT t;
	END LOOP;
	RETURN;
END
$f$;
CREATE OR REPLACE FUNCTION pg_temp.exec_text(text)
RETURNS SETOF text LANGUAGE sql AS $$
	SELECT * FROM pg_temp.exec_text($1, NULL::text)
$$;

CREATE TEMP VIEW ops AS SELECT * FROM unnest( string_to_array( '<  ,<= , = , >=,  >,!= ', ',' ) ) AS op;

CREATE TEMP TABLE num(
	numtype	regtype
	, n		numeric
);

INSERT INTO num VALUES
	( 'smallint', 1 )
	, ( 'int', 1 )
	, ( 'bigint', 1 )
	, ( 'float', 1.1 )
	, ( 'real', 1.1 )
	, ( 'numeric', 1.1 )
;

CREATE OR REPLACE TEMP VIEW numtest AS
	SELECT *, format( $$ '( %s , %s )'::variant.variant::%1$s $$, numtype, n ) AS var
		FROM ( SELECT numtype, n * multiplier AS n FROM num, generate_series(-1,1) AS multiplier ) a
;

CREATE TEMP TABLE ncmp_raw(
	l		variant.variant
	, r		variant.variant
	, lr	int
	, rr	int
);
-- DO NOT TOUCH! Change to the pattern we're using for _ncmp_raw's insert instead!
INSERT INTO ncmp_raw(	l,		r		, lr	, rr	)
VALUES
	  ( NULL, NULL						, NULL	, NULL	)
	, ( '(smallint,-1)', '(bigint,0)'	, -1	, 0	)
	, ( '(smallint,0)', '(int,0)'		, 0		, 0	)
	, ( '(bigint,1)', '(int,0)'			, 1		, 0	)
	, ( '(smallint,)', '(bigint,0)'		, NULL	, 0	)
	, ( '(smallint,)', '(int,0)'		, NULL	, 0	)
	, ( '(bigint,)', '(int,0)'			, NULL	, 0	)
	, ( '(smallint,-1)', '(bigint,)'	, -1	, NULL	)
	, ( '(smallint,0)', '(int,)'		, 0		, NULL	)
	, ( '(bigint,1)', '(int,)'			, 1		, NULL	)
	, ( '(smallint,)', '(bigint,)'		, NULL	, NULL	)
	, ( '(smallint,)', '(int,)'			, NULL	, NULL	)
	, ( '(bigint,)', '(int,)'			, NULL	, NULL	)
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
	l		variant.variant
	, r		variant.variant
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
			, variant.text_in(format( $$(%s[],%s)$$, t, '"' || lr::text || '"' )) AS l
			, variant.text_in(format( $$(%s[],%s)$$, t, '"' || rr::text || '"' )) AS r
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

CREATE TEMP TABLE scmp_raw(
	l		variant.variant
	, r		variant.variant
	, lr	text
	, rr	text
);
-- DO NOT TOUCH! Change to the pattern we're using for _ncmp_raw's insert instead!
INSERT INTO scmp_raw(	l,		r		, lr	, rr	)
VALUES
	  ( NULL, NULL						, NULL	, NULL	)
	, ( '(text,A)','(text,x)'			, 'A'	, 'x'	)
	, ( '(text,x)','(text,x)'			, 'x'	, 'x'	)
	, ( '(text,y)','(text,x)'			, 'y'	, 'x'	)
	, ( '(text,)','(text,x)'			, NULL	, 'x'	)
	, ( '(text,)','(text,x)'			, NULL	, 'x'	)
	, ( '(text,)','(text,x)'			, NULL	, 'x'	)
	, ( '(text,A)','(text,)'			, 'A'	, NULL	)
	, ( '(text,x)','(text,)'			, 'x'	, NULL	)
	, ( '(text,y)','(text,)'			, 'y'	, NULL	)
;
CREATE OR REPLACE TEMP VIEW scmp AS
	SELECT *
			, variant.text_out(l) AS l_text
			, variant.text_out(r) AS r_text
			, coalesce(lr::text, 'NULL') AS lr_text
			, coalesce(rr::text, 'NULL') AS rr_text
	FROM scmp_raw
;
CREATE OR REPLACE TEMP VIEW scmp_ops AS SELECT * FROM scmp, ops;

CREATE TEMP TABLE box_cmp_raw(
	l		variant.variant
	, r		variant.variant
	, lr	box
	, rr	box
);
-- DO NOT TOUCH! Change to the pattern we're using for _ncmp_raw's insert instead!
INSERT INTO box_cmp_raw(	l,		r								, lr					, rr	)
VALUES
	  ( NULL, NULL													, NULL					, NULL	)
	, ( '(box,"((0,0),(0.5,0.5))")'	,'(box,"((0,0),(1,1))")'		, '((0,0),(0.5,0.5))'	, '((0,0),(1,1))'	)
	, ( '(box,"((0,0),(1,1))")'		,'(box,"((0,0),(1,1))")'		, '((0,0),(1,1))'		, '((0,0),(1,1))'	)
	, ( '(box,"((-1,-1),(1,1))")'	,'(box,"((0,0),(1,1))")'		, '((-1,-1),(1,1))'		, '((0,0),(1,1))'	)
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
	+ (SELECT count(*) FROM numtest)
	+2 -- text in/out
	+3 -- register
	+6 -- register__get*
	+4 -- NULL
	+ (SELECT count(*) FROM ncmp_ops)
	+ (SELECT count(*) FROM _ncmp_ops)
	+ (SELECT count(*) FROM scmp_ops)
	+ (SELECT count(*) FROM box_cmp_ops)
)::int );

SELECT is(
	'(text,test)'::variant.variant::text
	, 'test'
	, 'cast to text'
);
SELECT is(
	'(text,test)'::variant.variant
	, '(text,test)'
	, 'Check equality'
);
SELECT is(
	'(text,)'::variant.variant::text
	, NULL
	, 'Check NULL'
);

SELECT pg_temp.exec_text(
	format( $$SELECT cmp_ok( %s, '=', %s::%s, %1$L || ' = %2$s::%3$s' )$$, var, n, numtype )
) FROM numtest;

SELECT is(
	variant.text_in( '(bigint,1)'::text )
	, '(bigint,1)'::variant.variant
	, 'variant.text_in()'
);
SELECT is(
	variant.text_out( '(text,test)'::variant.variant )
	, '(text,test)'::text
	, 'variant.text_out()'
);

/*
 * variant register
 */
SELECT row_eq(
	'SELECT * FROM variant.registered WHERE variant_typmod = -1'
	, ROW( -1, 'DEFAULT' )::variant.registered
	, 'valid variant(DEFAULT)'
);
SELECT lives_ok(
	$test$CREATE TEMP TABLE test_typmod AS SELECT *, ' test variant '::text AS variant_name FROM variant.register( ' test variant ' ) AS r(variant_typmod)$test$
	, 'Register variant'
);
SELECT bag_eq(
	$$SELECT * FROM variant.registered WHERE variant_typmod IN (SELECT variant_typmod FROM test_typmod)$$
	, $$SELECT * FROM test_typmod$$
	, 'test variant correctly added'
);

/*
 * _variant.registered__get
 */
SELECT bag_eq(
	$$SELECT * FROM _variant.registered__get( ' TEST variant ' )$$ -- Verify case insensitive
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
SELECT is( '(int,)'::variant.variant::int = NULL, true, '(int,)::int = NULL' );
SELECT is( '(int,1)'::variant.variant::int = NULL, false, '(int,1)::int != NULL' );
SET transform_null_equals = off;
SELECT is( '(int,)'::variant.variant::int = NULL, NULL, '(int,)::int = NULL is NULL' );
SELECT is( '(int,1)'::variant.variant::int = NULL, NULL, '(int,1)::int != NULL is NULL' );

-- TODO: integrate this with numtest; it's quite similar
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$%L::variant.variant %s %L::variant.variant
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
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$%L::variant.variant %s %L::variant.variant
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

SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$%L::variant.variant %s %L::variant.variant
					, %L::text %s %L::text
					, $$%L::text %s %L::text$$$fmt$
				, l, op, r
				, lr, op, rr
				, rpad(l_text, len_l), op, rpad(r_text, len_r)
			)
		)
	FROM scmp_ops
		, (SELECT max(length(l_text)) AS len_l, max(length(r_text)) AS len_r FROM scmp) l
;

--SET client_min_messages = debug;
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$%L::variant.variant %s %L::variant.variant
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
