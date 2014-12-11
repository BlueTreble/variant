\set ECHO 0
\set QUIET 1
/*
 * Postgres currently doesn't support comparing different string array types
 * (ie: varchar[] vs text[]) so this is split into 3 sections.
 *
 * KEEP ALL THREE FILES IN SYNC!
 */

\set test_types 'char[] char(10)[]'
\set baseline_type char(10)[]

\i test/helpers/_string_setup.sql

-- vi: expandtab sw=2 ts=2
