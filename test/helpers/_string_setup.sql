-- Used in array[ :base_values ]
\set base_values '$${a,a,c}$$, $${a,b,c}$$, $${a,c,c}$$, $${a,NULL,c}$$, $${NULL,b,c}$$, NULL'
\set compare_value '{a,b,c}'

\i test/helpers/type_setup.sql

SELECT plan(sum(test_count)::int) FROM plan;

\i test/helpers/type.sql


-- vi: expandtab sw=2 ts=2
