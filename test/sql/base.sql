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

/*
CREATE TEMP TABLE num(
	numtype	regtype
	, v		variant.variant
	, n		numeric
);

INSERT INTO num VALUES
	  ( 'smallint'	, '(smallint, -1)'	, -1	)
	, ( 'smallint'	, '(smallint, -1)'	, -1	)
	, ( 'smallint'	, '(smallint,  0)'	, 0		)
	, ( 'smallint'	, '(smallint,  1)'	, 1		)

	, ( 'int'		, '(int, -1)'		, -1	)
	, ( 'int'		, '(int,  0)'		, 0		)
	, ( 'int'		, '(int,  1)'		, 1		)

	, ( 'bigint'	, '(bigint, -1)'	, -1	)
	, ( 'bigint'	, '(bigint,  0)'	, 0		)
	, ( 'bigint'	, '(bigint,  1)'	, 1		)

	, ( 'smallint'	, '(smallint, -1)'	, -1	)
	, ( 'smallint'	, '(smallint,  0)'	, 0		)
	, ( 'smallint'	, '(smallint,  1)'	, 1		)

	, ( 'float'		, '(float, -1)'		, -1	)
	, ( 'float'		, '(float,  0)'		, 0		)
	, ( 'float'		, '(float,  1)'		, 1		)

	, ( 'double'	, '(double, -1)'	, -1	)
	, ( 'double'	, '(double,  0)'	, 0		)
	, ( 'double'	, '(double,  1)'	, 1		)

	, ( 'numeric'	, '(numeric, -1)'	, -1	)
	, ( 'numeric'	, '(numeric,  0)'	, 0		)
	, ( 'numeric'	, '(numeric,  1)'	, 1		)

;
*/

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
	, ltr	boolean
	, le	boolean
	, ler	boolean
	, eq	boolean
	, eqr	boolean
	, ge	boolean
	, ger	boolean
	, gt	boolean
	, gtr	boolean
	, ne	boolean
	, ner	boolean
);

INSERT INTO cmp VALUES
--											lt		ltr		le		ler		eq		eqr		ge		ger		gt		gtr		ne		ner
	  ( '(smallint,-1)', '(bigint,0)'	, true	, false	, true	, false	, false	, false	, false	, true	, false	, true	, true	, true	)
	, ( '(smallint,0)', '(int,0)'		, false	, false	, true	, true	, true	, true	, true	, true	, false	, false	, false	, false	)
	, ( '(bigint,1)', '(int,0)'			, false	, true	, false	, true	, false	, false	, true	, false	, true	, false	, true	, true	)
;

\set ON_ERROR_STOP false

SELECT plan( (
	2
	+ (SELECT count(*) FROM numtest)
	+2
	+3
	+4
	+4
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

SELECT _variant.exec(
	format( $$SELECT cmp_ok( %s, '=', %s::%s )$$, var, n, numtype )
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
	$$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, lt AS lt, le AS le, eq AS eq, ge AS ge, gt AS gt, ne AS ne FROM cmp$$
	, $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, l<r AS lt, l<=r AS le, l=r AS eq, l>=r AS ge, l>r AS gt, l!=r AS ne FROM cmp$$
	, 'Check <, <=, =, >=, >, !='
);
SELECT bag_eq(
	$$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, lt AS ltr, le AS ler, eq AS eqr, ge AS ger, gt AS gtr, ne AS ner FROM cmp$$
	, $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, r<l AS ltr, r<=l AS ler, r=l AS eqr, r>=l AS ger, r>l AS gtr, r!=l AS ner FROM cmp$$
	, 'Check reversed <, <=, =, >=, >, !='
);
SELECT bag_eq(
	$$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, lt AS lt, NOT le AS le, NOT eq AS eq, NOT ge AS ge, NOT gt AS gt, NOT ne AS ne FROM cmp$$
	, $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, l<r AS lt, NOT l<=r AS le, NOT l=r AS eq, NOT l>=r AS ge, NOT l>r AS gt, NOT l!=r AS ne FROM cmp$$
	, 'Check <, <=, =, >=, >, !='
);
SELECT bag_eq(
	$$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, lt AS ltr, NOT le AS ler, NOT eq AS eqr, NOT ge AS ger, NOT gt AS gtr, NOT ne AS ner FROM cmp$$
	, $$SELECT variant.text_out(l) AS l, variant.text_out(r) AS r, r<l AS ltr, NOT r<=l AS ler, NOT r=l AS eqr, NOT r>=l AS ger, NOT r>l AS gtr, NOT r!=l AS ner FROM cmp$$
	, 'Check reversed <, <=, =, >=, >, !='
);


SELECT finish();
ROLLBACK;

-- vi: noexpandtab sw=4 ts=4
