\i sql/variant.sql

CREATE TEMP TABLE test_variant_typmod AS
    SELECT *
        FROM variant.register( 'test variant', '{int2,int4,int8,real,float,numeric,char,"\"char\"",varchar,text,box,macaddr}' ) AS r(variant_typmod)
;
-- Add array variations on all the types we added
-- Be easier to use lives_ok, but we need this stuff in place before we call plan()
SELECT CASE WHEN count(*) > 1 THEN 'ok 1..0' ELSE 'FAIL' END
    FROM variant.add_types( 'test variant'
        , array( SELECT (type_name || '[]')::regtype
                    FROM variant.allowed_types( 'test variant' ) AS t(type_name)
                    WHERE type_name != ALL( '{box,macaddr}'::regtype[] )
                )
    )
;

CREATE OR REPLACE FUNCTION pg_temp.exec_text(
	sql text
	, VARIADIC v anyarray
) RETURNS SETOF text LANGUAGE plpgsql AS $f$
DECLARE
	v_sql text := format(sql, VARIADIC v);
	t text;
BEGIN
	RAISE DEBUG 'Executing % into text', v_sql;
	FOR t IN EXECUTE v_sql LOOP
		RETURN NEXT t;
	END LOOP;
	RETURN;
END
$f$;
CREATE OR REPLACE FUNCTION pg_temp.exec_text(text)
RETURNS SETOF text LANGUAGE sql AS $$
	SELECT * FROM pg_temp.exec_text($1, NULL::text)
$$;

CREATE TEMP TABLE operator AS SELECT * FROM unnest( string_to_array( '<  ,<= , = , >=,  >,!= ', ',' ) ) AS op;
CREATE TEMP VIEW ops AS SELECT * FROM operator; -- Eventually going away

CREATE TEMP TABLE plan(
    test_count      int     NOT NULL
    , test_desc     text
);
