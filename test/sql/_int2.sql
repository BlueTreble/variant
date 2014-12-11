\set ECHO 0
\set QUIET 1

/*
 * SEE NOTES IN _text.sql!
 */

\set baseline_type numeric[]
-- Space separated string
\set test_types 'int2[] int4[] int8[] float[] real[] numeric[]'
\set test_types 'int2[]'
-- Used in array[ :base_values ]
\set base_values '$${-1,-1,1}$$, $${-1,0,1}$$, $${-1,1,1}$$, $${NULL,-1,1}$$, $${NULL,0,1}$$, $${NULL,1,1}$$, $${-1,NULL,1}$$, NULL'
\set compare_value '{-1,0,1}'


\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
