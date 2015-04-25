\set ECHO none
BEGIN;
\i test/helpers/psql.sql

CREATE SCHEMA variant; -- Better not already exist...
\i sql/variant.sql
ROLLBACK;
