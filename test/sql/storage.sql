\set ECHO none
BEGIN;

\i test/helpers/tap_setup.sql
\i test/helpers/common.sql

SELECT plan( (
    0
    + 1 -- Reset role
    + 1 -- Event triggers
    + 2 -- can't drop event triggers
    + 5 -- Storage allowed
    + 12 -- Not extension
	+ 5 -- storage OK
)::int );

-- Need to run all this stuff as a superuser
SELECT lives_ok(
    --$$SELECT pg_temp.reset_role()$$
    $$SET ROLE = DEFAULT$$
    , 'Reset role'
);


/*
 * Verify event triggers are setup on proper events
 */
SELECT bag_eq(
    $$SELECT evtname, evtfoid, evttags FROM pg_event_trigger WHERE evtname LIKE 'variant_storage_check_%'$$
    , $$SELECT 'variant_storage_check_' || suffix AS evtname
                , ('variant._etg_verify_storage_' || suffix)::regproc AS evtfoid
                , ' {"ALTER DOMAIN","ALTER TABLE","CREATE DOMAIN","CREATE TABLE","CREATE TABLE AS"}'::text[] AS evttags
            FROM unnest( array[ 'start', 'end' ] ) AS suffix
    $$
    , 'Verify event triggers are correct'
);


/*
 * Verify we can't drop event triggers
 */
SELECT throws_ok(
	$$DROP EVENT TRIGGER variant_storage_check_start$$
    , '2BP01'
    , NULL
	, 'Can not drop _start trigger'
);
SELECT throws_ok(
	$$DROP EVENT TRIGGER variant_storage_check_end$$
    , '2BP01'
    , NULL
	, 'Can not drop _end trigger'
);

/*
 * Storage allowed
 */
SELECT throws_ok(
	$$UPDATE _variant._registered SET storage_allowed = true WHERE variant_typmod = -1$$
	, 'new row for relation "_registered" violates check constraint "storing_default_variant_not_supported"'
	, 'Not allowed to disable variant storage'
);

SELECT throws_ok(
	$$SELECT variant.storage_allowed( 'DEFAULT', true )$$
	, '22023'
	, 'Enabling storage of DEFAULT variant is not allowed'
	, 'Not allowed to disable variant storage'
);

SELECT lives_ok(
	$$SELECT variant.register( 'test storage', '{int}' )$$
	, 'Register test storage variant'
);
SELECT is( storage_allowed, false, 'test storage disallows storage' ) FROM _variant.registered__get( 'test storage' ) a;

SELECT throws_ok(
	$$CREATE TEMP TABLE storage_test( v variant.variant("test storage") )$$
	, '22023'
	, 'detected tables containing variants that do not allow storage'
	, 'Verify event trigger'
);

/*
 * Test dropping event triggers.
 *
 * This shouldn't be possibly if this is loaded as an extension, but be
 * paranoid in case someone loads this stuff as raw SQL.
 */

SELECT lives_ok(
    $$DROP EXTENSION variant$$
    , 'Drop extension'
);
\i sql/variant.sql

-- Need to re-register variants
SELECT lives_ok(
	$$SELECT variant.register( 'test variant', '{int}', true )$$
	, 'Register test variant'
);
SELECT lives_ok(
	$$SELECT variant.register( 'test storage', '{int,text,boolean}' )$$
	, 'Register test storage variant'
);
SELECT is( storage_allowed, false, 'test storage disallows storage' ) FROM _variant.registered__get( 'test storage' ) a;

SELECT lives_ok(
	$$DROP EVENT TRIGGER variant_storage_check_end$$
	, 'Drop _end trigger'
);
SELECT lives_ok(
	$$CREATE TEMP TABLE storage_test( v variant.variant("test storage") )$$
	, 'Create storage test table with event triggers disabled'
);
SELECT lives_ok(
	$$DROP EVENT TRIGGER variant_storage_check_start$$
	, 'Drop _start trigger'
);

\echo Verify we get WARNINGs because EVENT TRIGGERs are MIA
SELECT lives_ok(
	$$SELECT variant.storage_allowed( 'DEFAULT', false )$$
	, 'Disallow storage on DEFAULT variant'
);
SELECT is( storage_allowed, true, 'test storage allows storage after fixup' ) FROM _variant.registered__get( 'test storage' ) a;
SELECT is_empty(
	$$SELECT * FROM variant.stored__bad$$
	, 'No records found in variant.stored__bad'
);

SELECT throws_ok(
	$$ALTER TABLE storage_test ALTER v TYPE variant.variant$$
	, '22023'
	, 'detected tables containing variants that do not allow storage'
	, 'Can not ALTER TABLE'
);

SELECT throws_ok(
	$$SELECT variant.storage_allowed( 'test storage', false )$$
	, '2BP01'
	, 'variant "test storage" is still in use'
	, 'Not allowed to disable variant storage while in use'
);

/*
 * Storage OK
 */
SELECT lives_ok(
	$$INSERT INTO storage_test VALUES(1), (-1), ('a'::text)$$
	, 'Ensure we can store in "test storage"'
);

SELECT * FROM storage_test WHERE v > 0;

SELECT lives_ok(
	$$ALTER TABLE storage_test ALTER v TYPE variant.variant("test variant")$$
	, 'Can ALTER TABLE to use "test variant"'
);
SELECT lives_ok(
	$$CREATE TEMP VIEW storage_test_v AS SELECT * FROM storage_test$$
	, 'Can CREATE VIEW'
);
SELECT lives_ok(
	$$SELECT variant.storage_allowed( 'test storage', false )$$
	, 'Can disallow storage'
);
SELECT is( storage_allowed, false, 'test storage disallows storage' ) FROM _variant.registered__get( 'test storage' ) a;

SELECT finish();
ROLLBACK;
