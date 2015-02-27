\set ECHO none
\set QUIET 1
/*
 * NOTE! Unlike the other cases of duplication, we need to handle numeric,
 * float and real separately because of odd things such as
 *
 * 0.0::float < 0.0::real = true
 */

\set baseline_type macaddr
-- Space separated string
\set test_types 'macaddr'
-- Used in array[ :base_values ]
\set base_values '$$08:00:2b:01:02:03$$, $$08:10:2b:01:02:03$$, $$08:20:2b:01:02:03$$, NULL'
-- TODO: Allow more compare values so we can verify we're not somehow screwing up bit ordering
\set compare_value 08:10:2b:01:02:03


\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
/*
 * Box doesn't have sort operators, so do text-based sorting for the actual values.
 *
 * Note that this is used as a string value!
 */
\set op_test_order_by 'ORDER BY compare_type, base_type, compare_value::text, base_value::text'

-- Box also doesn't have a != operator
DELETE FROM operator WHERE op ~ '!=';
