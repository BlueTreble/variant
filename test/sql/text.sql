\set ECHO 0
\set QUIET 1
BEGIN;
\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

CREATE TEMP VIEW test_type AS
  SELECT * FROM unnest( string_to_array(
      'char char(10) varchar varchar(10) text'
      , ' '
    ) ) AS u(test_type)
;

CREATE TEMP VIEW base_value AS
  SELECT * FROM unnest(
    array[ 'a'::text, 'b', 'c', NULL ]
  ) AS bv(base_value)
;

CREATE TEMP VIEW compare_value AS
  SELECT 'b'::text AS compare_value
;

\set baseline_type text

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
