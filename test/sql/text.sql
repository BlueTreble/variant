\set ECHO 0
\set QUIET 1


\set baseline_type text
-- Space separated string
\set test_types 'char char(10) varchar varchar(10) text'
-- Used in array[ :base_values ]
\set base_values '$$a$$, $$b$$, $$c$$, NULL'
\set compare_value b

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
