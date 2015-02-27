\set ECHO none
\set QUIET 1


\set baseline_type numeric
-- Space separated string
\set test_types 'smallint integer bigint float real numeric(2,1) numeric'
-- Used in array[ :base_values ]
\set base_values '-1, 0, 1, NULL' 
\set compare_value 0


\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
