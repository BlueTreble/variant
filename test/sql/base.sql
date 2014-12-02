\set ECHO 0
BEGIN;
\i test/pgtap-core.sql
\i sql/variant.sql

\pset format unaligned
\pset tuples_only true
\pset pager
-- Revert all changes on failure.
\set ON_ERROR_ROLLBACK 1
-- \set ON_ERROR_STOP true

SELECT '(text,test)'::variant.variant;
SELECT '(text,test)'::variant.variant::text;


SELECT plan(5);

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


SELECT finish();
ROLLBACK;
