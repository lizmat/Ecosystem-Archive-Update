[![Actions Status](https://github.com/lizmat/Ecosystem-Archive/workflows/test/badge.svg)](https://github.com/lizmat/Ecosystem-Archive/actions)

NAME
====

Ecosystem::Archive - Interface to the Raku Ecosystem Archive

SYNOPSIS
========

```raku
use Ecosystem::Archive;

my $ea = Ecosystem::Archive.new(
  shelves     => 'archive',
  jsons       => 'meta',
  http-client => default-http-client
);

say "Archive has $ea.meta.elems() identities:";
.say for $ea.meta.keys.sort;
```

DESCRIPTION
===========

Ecosystem::Archive provides the basic logic to the Raku Programming Language Ecosystem Archive, a place where (almost) every distribution ever available in the Raku Ecosystem, can be obtained even after it has been removed (specifically in the case of the old ecosystem master list and the distributions kept on CPAN).

ARGUMENTS
---------

  * shelves

The name (or an `IO` object) of a directory in which to place distributions. This is usually a symlink to the "archive" directory of the actual [Raku Ecosystem Archive repository](https://github.com/lizmat/REA). The default is 'archive', aka the 'archive' subdirectory from the current directory.

  * jsons

The name (or an `IO` object) of a directory in which to store `META6.json` files as downloaded. This is usually a symlink to the "meta" directory of the actual [Raku Ecosystem Archive repository](https://github.com/lizmat/REA). The default is 'meta', aka the 'meta' subdirectory from the current directory.

  * http-client

The `Cro::HTTP::Client` object to do downloads with. Defaults to a `Cro::HTTP::Client` object that advertises this module as its User-Agent.

  * degree

The number of CPU cores that may be used for parallel processing. Defaults to the **half** number of `Kernel.cpu-cores`.

  * batch

The number of objects to be processed in parallel per batch. Defaults to **64**.

METHODS
=======

batch
-----

```raku
say "Processing with batches of $ea.batch() objects in parallel";
```

The number of objects per batch that will be used in parallel processing.

clear-notes
-----------

```raku
my @cleared = $ea.clear-notes;
say "All notes have been cleared";
```

Returns the `notes` of the object as a `List`, and removes them from the object.

degree
------

```raku
say "Using $ea.degree() CPUs";
```

The number of CPU cores that will be used in parallel processing.

distro
------

```raku
my $identity = $ea.find-identities('eigenstates').head;
say $ea.distro($identity);
```

Returns an `IO` object for the given identity, or `Nil` if it can not be found.

find-identities
---------------

```raku
my @identities = $ea.find-identities('eigenstates', :ver<0.0.3*>);
say "@identities[0] is the most recent";
```

Find the identities that supply the given module name (as a positional parameter) and possible refinement with named parameters for `:ver`, `:auth` and `:api`. Note that the `:ver` specification can contain `+` or `*` to indicate a range rather than a single version.

The identities will be returned sorted by highest version first. So if you're interested in only the most recent version, then just select the first element returned.

http-client
-----------

```raku
say "Information fetched as '$ea.http-client.user-agent()'";
```

The `Cro::HTTP::Client` object that is used for downloading information from the Internet.

investigate-repo
----------------

```raku
my @found = $ea.investigate-repo($url, "lizmat");
```

Performs a `git clone` on the given URL, scans the repo for changes in the `META6.json` file that would change the version, and downloads and saves a tar-file of the repository (and the associated META information in `git-meta`) at that state of the repository.

The second positional parameter indicates the default `auth` value to be applied to any JSON information, if no `auth` value is found or it is invalid.

Only `Github` and `Gitlab` URLs are currently supported.

Returns a list of `Pair`s of the distributions that were added, with the identity as the key, and the META information hash as the value.

Updates the `.meta` and `.modules` meta-information in a thread-safe manner.

jsons
-----

```raku
indir $ea.jsons, {
    my $jsons = (shell 'ls */*', :out).out.lines.elems;
    say "$jsons different distributions";
}
```

The `IO` object of the directory in which the JSON meta files are being stored. For instance the `IRC::Client` distribution:

    meta
      |- ...
      |- I
         |- ...
         |- IRC::Client
             |- IRC::Client:ver<1.001001>:auth<github:zoffixznet>.json
             |- IRC::Client:ver<1.002001>:auth<github:zoffixznet>.json
             |- ...
             |- IRC::Client:ver<3.007010>:auth<github:zoffixznet>.json
             |- IRC::Client:ver<3.007011>:auth<cpan:ELIZABETH>.json
             |- IRC::Client:ver<3.009990>:auth<cpan:ELIZABETH>.json
         |- ...
      |- ...

meta
----

```raku
say "Archive has $ea.meta.elems() identities, they are:";
.say for $ea.meta.keys.sort;
```

Returns a hash of all of the META information of all distributions, keyed by identity (for example "Module::Name:ver<0.1>:auth<foo:bar>:api<1>"). The value is a hash obtained from the distribution's meta data.

meta-as-json
------------

```raku
say $ea.meta-as-json;  # at least 3MB of text
```

Returns the JSON of all the currently known meta-information. The JSON is ordered by identity in the top level array.

modules
-------

```raku
say "Archive has $ea.modules.elems() different modules, they are:";
.say for $ea.modules.keys.sort;
```

Returns a `Map` keyed by module name, with a list of identities that provide that module name, as value.

note
----

```raku
$ea.note("something's wrong");
```

Add a note to the `notes` of the object.

notes
-----

```raku
say "Found $ea.notes.elems() notes:";
.say for $ea.notes;
```

Returns the `notes` of the object as a `List`.

shelves
-------

```raku
indir $ea.shelves, {
    my $distros = (shell 'ls */*', :out).out.lines.elems;
    say "$distros different distributions in archive";
}
```

The `IO` object of the directory where distributions are being stored in a subdirectory by the name of the module in the distribution. For instance the `silently` distribution:

    archive
     |- ...
     |- S
        |- ...
        |- silently
            |- silently:ver<0.0.1>:auth<cpan:ELIZABETH>.tar.gz
            |- silently:ver<0.0.2>:auth<cpan:ELIZABETH>.tar.gz
            |- silently:ver<0.0.3>:auth<cpan:ELIZABETH>.tar.gz
            |- silently:ver<0.0.4>:auth<zef:lizmat>.tar.gz
        |- ...
     |- ...

Note that a subdirectory will contain **all** distributions of the name, regardless of version, authority or API value.

update
------

```raku
my %updated = $ea.update;
```

Updates all the meta-information and downloads any new distributions. Returns a hash with the identities and the meta info of any distributions that were not seen before. Also updates the `.meta` and `.modules` information in a thread-safe manner.

AUTHOR
======

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/Ecosystem-Archive. Comments and Pull Requests are welcome.

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

