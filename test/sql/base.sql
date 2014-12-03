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

-- Trailing 'r' means reverse the operands
CREATE TEMP TABLE cmp(
	l		variant.variant
	, r		variant.variant
	, lt	boolean
	, le	boolean
	, eq	boolean
	, ge	boolean
	, gt	boolean
	, ne	boolean
);

INSERT INTO cmp(	l,		r			, lt	,	le	,	eq	,	ge	,	gt	,	ne	)
VALUES
	  ( '(smallint,-1)', '(bigint,0)'	, true	, true	, false	, false	, false	, true	)
	, ( '(smallint,0)', '(int,0)'		, false	, true	, true	, true	, false	, false	)
	, ( '(bigint,1)', '(int,0)'			, false	, false	, false	, true	, true	, true	)
;

\set ON_ERROR_STOP false

SELECT plan( (
	2 -- cast, equality
	+ (SELECT count(*) FROM numtest)
	+2 -- text in/out
	+3 -- register
	+4 -- NULL
	+1 -- cmp
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


SELECT row_eq(
	'SELECT * FROM variant.registered WHERE variant_typmod = -1'
	, ROW( -1, 'DEFAULT' )::variant.registered
	, 'valid variant(DEFAULT)'
);

SELECT lives_ok(
	$test$CREATE TEMP TABLE variant_typmod AS SELECT * FROM variant.register( 'test variant' )$test$
	, 'Register variant'
);
SELECT bag_eq(
	$$SELECT * FROM variant.registered WHERE variant_typmod IN (SELECT * FROM variant_typmod)$$
	, $$SELECT *, 'test variant'::text FROM variant_typmod$$
	, 'test variant correctly added'
);

SET transform_null_equals = on;
SELECT is( '(int,)'::variant.variant::int = NULL, true, '(int,)::int = NULL' );
SELECT is( '(int,1)'::variant.variant::int = NULL, false, '(int,1)::int != NULL' );
SET transform_null_equals = off;
SELECT is( '(int,)'::variant.variant::int = NULL, NULL, '(int,)::int = NULL is NULL' );
SELECT is( '(int,1)'::variant.variant::int = NULL, NULL, '(int,1)::int != NULL is NULL' );

SELECT bag_eq(
	  $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r,        lt,         le,        eq,         ge,        gt,         ne FROM cmp$$
	, $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, l<r AS lt, l<=r AS le, l=r AS eq, l>=r AS ge, l>r AS gt, l!=r AS ne FROM cmp$$
	, 'Check <, <=, =, >=, >, !='
);

SELECT finish();
ROLLBACK;

-- vi: noexpandtab sw=4 ts=4
