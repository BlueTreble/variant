\set ECHO 0
\set QUIET 1


\set baseline_type numeric
-- Space separated string
\set test_types 'int2 int4 int8 float real numeric'
-- Used in array[ :base_values ]
\set base_values '-1, 0, 1, NULL' 
\set compare_value 0


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

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
