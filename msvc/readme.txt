1. copy out\* --> c:\Program Files (x86)\PostgreSQL\9.3\
	out\lib\variant.dll --> c:\Program Files (x86)\PostgreSQL\9.3\lib\variant.dll
	out\share\extension\variant.control --> c:\Program Files (x86)\PostgreSQL\9.3\share\extension\variant.control
	out\share\extension\variant--1.0.0-beta3.sql --> c:\Program Files (x86)\PostgreSQL\9.3\share\extension\variant--1.0.0-beta3.sql

2. run test using next cmd:
pg_regress.exe --psqldir="c:\Program Files (x86)\PostgreSQL\9.3\bin"
--inputdir=..\test --load-language=plpgsql --dbname=contrib_regression _char _float _int2 _int4 _int8 _num _real _text _varchar base box float int macaddr num real text

NOTE: list of tests should be generated via unix command make print-REGRESS
