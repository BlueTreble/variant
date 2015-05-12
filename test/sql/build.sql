\set ECHO none
BEGIN;
\i test/helpers/psql.sql

\i sql/variant.sql
ROLLBACK;
