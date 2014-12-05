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
CREATE TEMP TABLE cmp_raw(
	l		variant.variant
	, r		variant.variant
	, li	int
	, ri	int
);
INSERT INTO cmp_raw(	l,		r		, li	, ri	)
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
CREATE OR REPLACE TEMP VIEW cmp AS
	SELECT *
			, variant.text_out(l) AS l_text
			, variant.text_out(r) AS r_text
			, coalesce(li::text, 'NULL') AS li_text
			, coalesce(ri::text, 'NULL') AS ri_text
	FROM cmp_raw
;

CREATE TEMP VIEW ops AS SELECT * FROM unnest( string_to_array( '<  ,<= , = , >=,  >,!= ', ',' ) ) AS op;

\set ON_ERROR_STOP false

SELECT plan( (
	3 -- Simple cast, equality, NULL
	+ (SELECT count(*) FROM numtest)
	+2 -- text in/out
	+3 -- register
	+4 -- NULL
--	+1 -- cmp
	+ (SELECT count(*) FROM cmp, ops)
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

-- TODO: integrate this with numtest; it's quite similar
SELECT pg_temp.exec_text(
			$$SELECT is( %s )$$
			, format( $fmt$%L::variant.variant %s %L::variant.variant
					, %s %s %s
					, '%s %s %s'$fmt$
				, l, op, r
				, li_text, op, ri_text
				, rpad(l_text, len_l), op, rpad(r_text, len_r)
			)
		)
	FROM cmp, ops
		, (SELECT max(length(l_text)) AS len_l, max(length(r_text)) AS len_r FROM cmp) l
;

SELECT finish();
ROLLBACK;

-- vi: noexpandtab sw=4 ts=4
