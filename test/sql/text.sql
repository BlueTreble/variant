\set ECHO none
\set QUIET 1

/*
 * We intentionally test "char" as well, because it's typlen is 1 and it's
 * easier to include it here than to test boolean (the other typlen 1 type).
 */


\set baseline_type text
-- Space separated string
\set test_types '"char" character character(10) varchar varchar(10) text'
-- Used in array[ :base_values ]
\set base_values '$$a$$, $$b$$, $$c$$, NULL'
\set compare_value b

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
