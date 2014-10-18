\set ECHO 0
BEGIN;
\i test/pgtap-core.sql
\i sql/variant.sql

\pset format unaligned
\pset tuples_only true
\pset pager
-- Revert all changes on failure.
\set ON_ERROR_ROLLBACK 1
\set ON_ERROR_STOP true

SELECT plan(1);

SELECT ok(true);

SELECT finish();
ROLLBACK;
