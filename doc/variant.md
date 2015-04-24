variant
=======

`variant` allows for storing any PostgreSQL data type in a column, as well as
remembering what the original data type was.

Usage
-----

For creating storage, you would use `variant` as any other data type: (Note
that by default the default variant shown here is disabled)

    CREATE TABLE setting(
        setting_name        text                NOT NULL PRIMARY KEY
        , setting_value     variant.variant     NOT NULL
    );

You can then insert whatever data you want:

    INSERT INTO setting VALUES( 'foobar', 1::int );
    INSERT INTO setting VALUES( 'box', '((0,0),(1,1))'::box );

    SELECT * FROM setting;
     setting_name |    setting_value    
    --------------+---------------------
     box          | (box,"(1,1),(0,0)")
     foobar       | (integer,1)
    (2 rows)

### Variant modifier ###
In order to more sanely support droping data types, `variant` will eventually
allow you to specify what types are actually allowed to be stored in a variant.
In order to allow for different settings here, you should register a variant
using `variant.register()`:

    SELECT variant.register( 'setting' );
     register 
    ----------
            1
    (1 row)

    ALTER TABLE setting ALTER setting_value TYPE variant.variant(setting);
    ALTER TABLE
    \d setting
                    Table "public.setting"
        Column     |           Type           | Modifiers 
    ---------------+--------------------------+-----------
     setting_name  | text                     | not null
     setting_value | variant.variant(setting) | not null
    Indexes:
        "setting_pkey" PRIMARY KEY, btree (setting_name)

There is a default variant, but you are encouraged not to use it (it is
disabled by default). This is because some parts of PostgreSQL do not inspect
(or even store) a type modifier. That means you could accidentally end up with
data in the default variant instead of a registered variant.

### Support Functions ###
#### type_text() / type_type() ####
This function takes a variant as an input, and returns the original type as a text string (including the original type modifier). If you to strip off the type modifier, cast the output of this function to regtype: `SELECT variant.type(v)::regtype`

#### text_in() / text_out() ####
The main method of changing the value of a variant field is meant to be via casting, ie: `'some data'::varchar(20)::variant`. That's a bit awkward when written out, but would work great in something like plpgsql:

    DO $$DECLARE v_setting_value     text;
    BEGIN
        v_setting_value := 'test';
        INSERT INTO setting SELECT 'test setting', v_setting_value;
    END

You can also construct the text representation of a variant:
    SELECT '(text,test)'::variant.variant;
       variant   
    -------------
     (text,test)
    (1 row)

What does not work is trying to construct a variant input in a text field and then using that to create a variant:

    DO $$
        DECLARE v_in text;
        BEGIN
        v_in := '(text,test)';
        INSERT INTO setting SELECT 'test', v_in;
    END$$;

    SELECT setting_value FROM setting WHERE setting_name = 'test';
        setting_value     
    ----------------------
     (text,"(text,test)")
    (1 row)
    
To support this, you can instead use variant.text_in():

    DO $$
    DECLARE v_in text;
    BEGIN
    v_in := '(text,test)';
    INSERT INTO setting SELECT 'test2', variant.text_in(v_in, 'setting');
    END$$;

    SELECT setting_value FROM setting WHERE setting_name = 'test2';
     setting_value 
    ---------------
     (text,test)
    (1 row)

The second argument to text_in() is the registered name of the variant. If
omitted, the default variant is used. You may also pass in the raw typmod
value.

#### create_casts() ####
The primary interface for storing and retrieving data from a variant is
casting. For that to work, we need to tell Postgres that it's OK to cast from
an existing data type to a variant and vice-versa.

To facilitate this, the function `variant.create_casts()` will create casts to
and from `variant` for all existing types (note that composite types are not
supported). When you install `variant` it will create all these casts for you,
but if you add new data types after installation you should `SELECT
variant.create_casts();`.

TODO
----
  * Better support for dropping types

`variant` uses the input and output functions for each type. It also stores the type in it's native storage format (as opposed to something like text). This means that if you drop a type that has been used to store data in a variant you won't be able to get your data back. Generally this shouldn't be a danger, because you should have casts defined between `variant` and all your types. However, `variant` doesn't actually enforce that, and even if it did you could always drop the cast first or use the `CASCADE` option to `DROP TYPE`.

My plan here is to allow specifying exactly what types a registered variant is allowed to use. Because it's easy to see what columns are using a particular registered variant we could do something to verify that no records exist with the type in question before dis-allowing that types use with that registered variant. I hope we could also create pg_depend entries that would explicitly tie the original data types to individual table fields.

  * Dynamic type support

Once we can restrict registered variants to only using particular types, it would be nice to have "dynamic" variants that have all the tracking associated with restricted variants, but allow you to put whatever you want into the variant. In essence, instead of throwing an error if you try and use an unapproved type, the variant would dynamically mark that type as being approved.

Support
-------
You can see the current status of *released* versions of this extension on [PGXN-tester](http://pgxn-tester.org/distributions/variant).

Travis-CI status: [![Build Status](https://travis-ci.org/decibel/variant.png)](https://travis-ci.org/decibel/variant)

Please report issues at <https://github.com/decibel/variant/issues>.

Author
------
Jim Nasby, [Blue Treble Consulting](http://BlueTreble.com)


Copyright and License
---------------------

Copyright (c) 2014 Jim Nasby

