\set ECHO 0
BEGIN;
\i test/pgtap-core.sql
\i sql/variant.sql

ROLLBACK;
