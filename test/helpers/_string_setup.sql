BEGIN;
\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

CREATE TEMP VIEW test_type AS
  SELECT * FROM unnest( string_to_array(
      --'char char(10) varchar varchar(10) text'
      :'test_types'
      , ' '
    ) ) AS u(test_type)
;

CREATE TEMP TABLE base_value(base_value text[]);
INSERT INTO base_value
  SELECT u:::baseline_type AS base_value FROM unnest(
    array[ '{a,a,c}', '{a,b,c}', '{a,c,c}', '{a,NULL,c}', '{NULL,b,c}', NULL ]
  ) AS u
;

CREATE TEMP VIEW compare_value AS
  SELECT '{a,b,c}'::text[] AS compare_value
;

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql

-- vi: expandtab sw=2 ts=2
