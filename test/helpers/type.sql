\set ECHO none
/*
For each type we want to test:

text_in()
text_out()
type_out()
comparators (variant to variant and variant to original)
Actual storage and retrieval
NULL original data (NULL variants should be tested separately)

Overall plan:
1: Start with an original value in a "big" type (ie: numeric vs other number formats).

2: Create text representation of that casted to specific data type

3: Verify text representation is equal to original value when evaluated

4: Use text representation to insert into a variant field

5: SET variant_b = text_in( text_out( variant_a ) )

6: Verify variant_b = variant_a

7: Verify variant.type works
*/

-- By this point, steps 1, 2 and 4 are done.

SELECT is_empty( $$SELECT * FROM base_data WHERE base_variant IS NULL$$, 'No NULL variants' );

-- Step 3
SELECT is( base__casted, base__original, 'Verify result of cast ' || base_cast_string ) FROM base_data;

-- Step 5
SELECT lives_ok(
  $$UPDATE base_data SET base_variant_b = variant.text_in( variant.text_out(base_variant), 'test variant' )$$
  , 'SET base_variant_b'
);

-- Step 6
SELECT is( base_variant_b, base_variant, 'Verify text_in(text_out()) works for ' || variant.text_out(base_variant) ) FROM base_data;

-- Step 7
SELECT is(
    variant.original_type(base_variant)
    , formatted_type
  )
  FROM base_data
;


/*
 * Do the same tests with our compare data.
 *
 * s/base_/compare_/g
 */

SELECT is_empty( $$SELECT * FROM compare_data WHERE compare_variant IS NULL$$, 'No NULL variants' );

-- Step 3
SELECT is( compare__casted, compare__original, 'Verify result of cast ' || compare_cast_string ) FROM compare_data;

-- Step 5
SELECT lives_ok(
  $$UPDATE compare_data SET compare_variant_b = variant.text_in( variant.text_out(compare_variant), 'test variant' )$$
  , 'SET compare_variant_b'
);

-- Step 6
SELECT is( compare_variant_b, compare_variant, 'Verify text_in(text_out()) works for ' || variant.text_out(compare_variant) ) FROM compare_data;


/*
 * Operator testing. (Note that is() uses IS DISTINCT, so that's also tested.)
 *
 * For each operator and type combination:
 *
 * Calculate base value "op" original value
 * base value "op" variant
 * base value as variant "op" variant
 *
 * For each case, we dynamically build an is() test that looks like this:
 * is(
 *      the results of applying operator to original compare and "base" values
 *      , results of applying operator to a different compare and base value
 *      , description
 *    )
 *
 * We generate that using a nested set of format() statements for clarity. The
 * format for the is() is several lines long, so we just stick that in a temp
 * table instead of repeating it everywhere.
 *
 * It's very important to keep in mind what replacement is being done where!
 * The is_format template is the query that ultimately runs the test, and it is
 * pulling all the test data from the op_test_data view. The
 * pg_temp.exec_text() calls provide the "istructions" to the is_format template
 * on what each test actually needs to be.
 *
 * An example will help clarify. Consider the first argument we're supplying to
 * the is_format template in the first test:

      , format( '%s %s %s', 'compare__casted', op, 'base__casted' )

 * The output of that format() is replacing the first %s in the is_format
 * template. So in this example, we end up with a string of

    compare__casted < base_casted

 * where '<' is replaced by each operator in turn.
 *
 * If this is still unclear then uncomment the SET client_min_messages and
 * LIMIT 1 lines below and study the output.
 */

CREATE TEMP TABLE is_format AS SELECT
$$SELECT is(
      %s
      , %s
      , %s
    )
  FROM (
    SELECT * FROM op_test_data $$ || :'op_test_order_by' || $$
  ) ordered -- Need to order first otherwise our test numbers get re-arranged, which is confusing
$$::text AS is_format;

CREATE TEMP VIEW op_test AS
  SELECT *
--      , format( '%L %s %L', compare_value, op, base_value ) AS original_condition
    FROM is_format, operator
;

-- Note: This test isn't testing variant; it's a sanity-check that we did our casting correctly
--SET client_min_messages = DEBUG;
SELECT pg_temp.exec_text(
			is_format
      -- First argument to is(): apply operator op (from this query) to the columns compare__casted and base__casted
      , format( '%s %s %s', 'compare__casted', op, 'base__casted' )
      , format( '%s %s %s', 'compare_value', op, 'base_value' )
      , $$format( 'check casted vs uncasted for %s $$ || op || $$ %s', compare_cast_string, base_cast_string )$$
    )
	FROM op_test
--LIMIT 1
;
SET client_min_messages = NOTICE;

SELECT pg_temp.exec_text(
			is_format
      , format( '%s %s %s', 'compare_variant', op, 'base_variant' )
      , format( '%s %s %s', 'compare_value', op, 'base_value' )
      , $$format( 'check variant vs uncasted for %s $$ || op || $$ %s', compare_cast_string, base_cast_string )$$
    )
	FROM op_test
;

SELECT pg_temp.exec_text(
			is_format
      , format( '%s %s %s', 'compare_variant', op, 'base_variant' )
      , format( '%s %s %s', 'compare__casted', op, 'base__casted' )
      , $$format( 'check variant vs casted for %L $$ || op || $$ %L', compare_cast_string, base_cast_string )$$
    )
	FROM op_test
;

SELECT finish();

-- vi: expandtab sw=2 ts=2
