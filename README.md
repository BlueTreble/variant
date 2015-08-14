variant
=======

variant is a Postgres datatype that can hold data from any other type, as well
as remembering what the original type was. For example:

    SELECT 'some text'::text::variant.variant;
          variant       
    --------------------
     (text,"some text")
    (1 row)

    SELECT 42::int::variant.variant;
       variant    
    --------------
     (integer,42)
    (1 row)

To build it, just do this:

    make install

and then in your database:

    CREATE EXTENSION variant;

See "Building" below for more details or if you run into a problem.

Current Status
==============
You can see the current status of *released* versions of this extension on [PGXN-tester](http://pgxn-tester.org/distributions/variant).

Travis-CI status: [![Build Status](https://travis-ci.org/BlueTreble/variant.svg)](https://travis-ci.org/BlueTreble/variant)

Building
========
To build variant, do this:

    make
    make install

If you encounter an error such as:

    "Makefile", line 8: Need an operator

You need to use GNU make, which may well be installed on your system as
`gmake`:

    gmake
    gmake install

If you encounter an error such as:

    make: pg_config: Command not found

Be sure that you have `pg_config` installed and in your path. If you used a
package management system such as RPM to install PostgreSQL, be sure that the
`-devel` package is also installed. If necessary tell the build process where
to find it:

    env PG_CONFIG=/path/to/pg_config make && make install

And finally, if all that fails (and if you're on PostgreSQL 8.1 or lower, it
likely will), copy the entire distribution directory to the `contrib/`
subdirectory of the PostgreSQL source tree and try it there without
`pg_config`:

    env NO_PGXS=1 make && make installcheck && make install

If you encounter an error such as:

    ERROR:  must be owner of database regression

You need to run the test suite using a super user, such as the default
"postgres" super user:

    make installcheck PGUSER=postgres

Once variant is installed, you can add it to a database. If you're running
PostgreSQL 9.1.0 or greater, it's a simple as connecting to a database as a
super user and running:

    CREATE EXTENSION variant;

If you've upgraded your cluster to PostgreSQL 9.1 and already had variant
installed, you can upgrade it to a properly packaged extension with:

    CREATE EXTENSION variant FROM unpackaged;

For versions of PostgreSQL less than 9.1.0, you'll need to run the
installation script:

    psql -d mydb -f /path/to/pgsql/share/contrib/variant.sql

If you want to install variant and all of its supporting objects into a specific
schema, use the `PGOPTIONS` environment variable to specify the schema, like
so:

    PGOPTIONS=--search_path=extensions psql -d mydb -f variant.sql

Dependencies
------------
The `variant` data type has no dependencies other than PostgreSQL.

Copyright and License
---------------------

Copyright (c) 2014 Jim Nasby, Blue Treble Consulting http://BlueTreble.com

