/*
 * See overview comment in type.sql before trying to grok this file
 *
 * test_type is a table of the types we're testing
 * base_value is a table of the values to test, represented in the "big" type format
 */

/*
 * Some types don't have sort operators defined. For those cases you'll need to
 * over-ride this variable with something else. It's still a good idea to have
 * a unique sort ordering, to prevent false test failures.
 *
 * Note that this is used as a string value!
 */
\set op_test_order_by 'ORDER BY compare_type, base_type, compare_value, base_value'

BEGIN;
\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

CREATE TEMP VIEW test_type AS
  SELECT * FROM unnest( string_to_array(
      :'test_types'
      , ' '
    ) ) AS u(test_type)
;

CREATE TEMP VIEW base_value AS
  SELECT base_value:::baseline_type FROM unnest(
    array[ :base_values ]
  ) AS bv(base_value)
;

CREATE TEMP VIEW compare_value AS
  SELECT :'compare_value':::baseline_type AS compare_value
;

-- Create a text representation of how to cast our test data to each test type
CREATE TEMP VIEW base_casted AS
  SELECT *
      , base_quoted || '::' || base_type AS base_cast_string
    FROM (
      SELECT test_type AS base_type, base_value
          , quote_nullable(base_value) AS base_quoted
        FROM test_type tt, base_value bv
      ) a
;

-- Create a table to store this data for real
CREATE TEMP TABLE base_data AS SELECT base_type, base_value, base_cast_string FROM base_casted WHERE false;
ALTER TABLE base_data
  ADD COLUMN base__original      :baseline_type
  , ADD COLUMN base__casted        :baseline_type
  , ADD COLUMN base_variant        variant.variant('test variant')
  , ADD COLUMN base_variant_b      variant.variant('test variant')
  , ADD COLUMN formatted_type     text
;

/*
 * Insert into our table using dynamically generated INSERT statements. This is
 * ugly, but I don't see a better way to accomplish the casting.
 *
 * This handles step 4
 */
SELECT NULL = count(*) FROM ( -- Supress tons of blank lines
SELECT _variant.exec( format(
-- start format string
$fmt$INSERT INTO base_data
  VALUES( %L, %L, %L, %s, %s, %s, NULL, %L )$fmt$
-- end format string
      , base_type
      , base_value
      , base_cast_string
      , base_quoted       -- base__original
      , base_cast_string  -- base__casted
      , base_cast_string  -- base_variant
      -- base_variant_b set to NULL in VALUES
      , base_type         -- formatted_type
    ) )
  FROM base_casted
) a;

-- Be careful of the order these are in!
UPDATE base_data SET formatted_type = replace( base_type, 'character', 'character(1)' ) WHERE base_type LIKE 'character%' AND base_type NOT LIKE '%(%)%';
UPDATE base_data SET formatted_type = replace( base_type, 'varchar', 'character varying' ) WHERE base_type LIKE 'varchar%';
UPDATE base_data SET formatted_type = replace( base_type, 'float', 'double precision' ) WHERE base_type LIKE 'float%';
--SELECT base_type, formatted_type FROM base_data WHERE base_type <> formatted_type;

INSERT INTO plan SELECT 1,        'Verify no records where base_variant is NULL';
INSERT INTO plan SELECT count(*), 'Verify base data casted correctly' FROM base_data;
INSERT INTO plan SELECT 1,        'UPDATE base_variant_b';
INSERT INTO plan SELECT count(*), 'Verify text_in(text_out())' FROM base_data;
INSERT INTO plan SELECT count(*), 'Verify variant.original_type())' FROM base_data;

/*
 * Same as above, but for compare values
 *
 * s/base_/compare_/g
 */

-- Create a text representation of how to cast our test data to each test type
CREATE TEMP VIEW compare_casted AS
  SELECT *
      , compare_quoted || '::' || compare_type AS compare_cast_string
    FROM (
      SELECT test_type AS compare_type, compare_value
          , quote_nullable(compare_value) AS compare_quoted
        FROM test_type tt, compare_value bv
      ) a
;

-- Create a table to store this data for real
CREATE TEMP TABLE compare_data AS SELECT compare_type, compare_value, compare_cast_string FROM compare_casted WHERE false;
ALTER TABLE compare_data
  ADD COLUMN compare__original      :baseline_type
  , ADD COLUMN compare__casted        :baseline_type
  , ADD COLUMN compare_variant        variant.variant('test variant')
  , ADD COLUMN compare_variant_b      variant.variant('test variant')
;

/*
 * Insert into our table using dynamically generated INSERT statements. This is
 * ugly, but I don't see a better way to accomplish the casting.
 *
 * This handles step 4
 */
SELECT NULL = count(*) FROM ( -- Supress tons of blank lines
SELECT _variant.exec( format(
-- start format string
$fmt$INSERT INTO compare_data
  VALUES( %L, %L, %L, %s, %s, %s, NULL )$fmt$
-- end format string
      , compare_type
      , compare_value
      , compare_cast_string
      , compare_quoted       -- compare__original
      , compare_cast_string  -- compare__casted
      , compare_cast_string  -- compare_variant
      -- compare_variant_b set to NULL in VALUES
    ) )
  FROM compare_casted
) a;

INSERT INTO plan SELECT 1,        'Verify no records where compare_variant is NULL';
INSERT INTO plan SELECT count(*), 'Verify base data casted correctly' FROM compare_data;
INSERT INTO plan SELECT 1,        'UPDATE compare_variant_b';
INSERT INTO plan SELECT count(*), 'Verify text_in(text_out())' FROM compare_data;

/*
 * Operator testing setup
 */
CREATE TEMP VIEW op_test_data AS SELECT * FROM compare_data, base_data;
-- If you change the tail of these descriptions then check the box test!
INSERT INTO plan SELECT count(*), 'Check casted vs uncasted for ' || op FROM operator, op_test_data GROUP BY 2;
INSERT INTO plan SELECT count(*), 'Check variant vs uncasted for ' || op FROM operator, op_test_data GROUP BY 2;
INSERT INTO plan SELECT count(*), 'Check variant vs casted for ' || op FROM operator, op_test_data GROUP BY 2;

-- vi: expandtab sw=2 ts=2
