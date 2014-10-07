\set ECHO 0
BEGIN;
\i sql/variant.sql
\set ECHO all

-- You should write your tests

SELECT variant('foo', 'bar');

SELECT 'foo' #? 'bar' AS arrowop;

CREATE TABLE ab (
    a_field variant
);

INSERT INTO ab VALUES('foo' #? 'bar');
SELECT (a_field).a, (a_field).b FROM ab;

SELECT (variant('foo', 'bar')).a;
SELECT (variant('foo', 'bar')).b;

SELECT ('foo' #? 'bar').a;
SELECT ('foo' #? 'bar').b;

ROLLBACK;
