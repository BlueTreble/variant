\set ECHO none
\set QUIET 1
/*
 * NOTE! Unlike the other cases of duplication, we need to handle numeric,
 * float and real separately because of odd things such as
 *
 * 0.0::float < 0.0::real = true
 */


\set baseline_type float
-- Space separated string
\set test_types 'float'
-- Used in array[ :base_values ]
\set base_values '-1.1, 0.1, 1.1, NULL' 
\set compare_value 0.1


\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
