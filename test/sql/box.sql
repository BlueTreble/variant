\set ECHO none
\set QUIET 1
/*
 * NOTE! Unlike the other cases of duplication, we need to handle numeric,
 * float and real separately because of odd things such as
 *
 * 0.0::float < 0.0::real = true
 */

\set baseline_type box
-- Space separated string
\set test_types 'box'
-- Used in array[ :base_values ]
\set base_values '$$((0,0),(0.5,0.5))$$, $$((0,0),(1,1))$$, $$((-1,-1),(1,1))$$, NULL'
\set compare_value ((0,0),(1,1))


\i test/helpers/type_setup.sql

/*
 * Box doesn't have sort operators, so do text-based sorting for the actual values.
 *
 * Note that this is used as a string value!
 */
\set op_test_order_by 'ORDER BY compare_type, base_type, compare_value::text, base_value::text'

-- Box also doesn't have a != operator
DELETE FROM operator WHERE op ~ '!=';
DELETE FROM plan WHERE test_desc ~ '!= *$';

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
