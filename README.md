[![Actions Status](https://github.com/lizmat/Ecosystem-Archive/workflows/test/badge.svg)](https://github.com/lizmat/Ecosystem-Archive/actions)

NAME
====

Ecosystem::Archive - Interface to the Raku Ecosystem Archive

SYNOPSIS
========

```raku
use Ecosystem::Archive;

my $ea = Ecosystem::Archive.new(
  archive     => 'archive',
  cpan-meta   => 'cpan-meta',
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

  * archive

The name (or an `IO` object) of a directory in which to place distributions. This is usually a symlink to the "archive" directory of the actual [Raku Ecosystem Archive repository](https://github.com/lizmat/REA). The default is 'archive', aka the 'archive' subdirectory from the current directory.

  * cpan-meta

The name (or an `IO` object) of a directory in which to store `META6.json` files as downloaded from CPAN (and cleaned up). This is usually a symlink to the "cpan-meta" directory of the actual [Raku Ecosystem Archive repository](https://github.com/lizmat/REA). The default is 'cpan-meta', aka the 'cpan-meta' subdirectory from the current directory.

  * http-client

The `Cro::HTTP::Client` object to do downloads with. Defaults to a `Cro::HTTP::Client` object that advertises this module as its User-Agent.

METHODS
=======

archive
-------

```raku
say "$ea.archive.dir.elems() different modules in archive";
```

The `IO` object of the directory where distributions are being stored in a subdirectory by the name of the module in the distribution. For instance:

    archive
     |- ...
     |- silently
         |- silently:ver<0.0.1>:auth<cpan:ELIZABETH>.tar.gz
         |- silently:ver<0.0.2>:auth<cpan:ELIZABETH>.tar.gz
         |- silently:ver<0.0.3>:auth<cpan:ELIZABETH>.tar.gz
         |- silently:ver<0.0.4>:auth<zef:lizmat>.tar.gz
     |- ...

Note that a subdirectory will contain **all** distributions of the name, regardless of version, authority or API value.

cpan-meta
---------

```raku
say "$ea.cpan-meta.dir.elems() different CPAN distributions known";
```

The `IO` object of the directory in which the CPAN meta files are being stored. For instance:

    cpan-meta
      |- ...
      |- cpan-meta/ELIZABETH:silently-0.0.1.json
      |- cpan-meta/ELIZABETH:silently-0.0.2.json
      |- cpan-meta/ELIZABETH:silently-0.0.3.json
      |- ...

http-client
-----------

```raku
say "Information fetched as '$ea.http-client.user-agent()'";
```

The `Cro::HTTP::Client` object that is used for downloading information from the Internet.

meta
----

```raku
say "Archive has $ea.meta.elems() identities, they are:";
.say for $ea.meta.keys.sort;
```

Returns a hash of all of the META information of all distributions, keyed by identity (for example "Module::Name:ver<0.1>:auth<foo:bar>:api<1>"). The value is a hash obtained from the distribution's metd data.

meta-as-json
------------

```raku
say $ea.meta-as-json;  # at least 3MB of text
```

Returns the JSON of all the currently known meta-information.

update
------

```raku
my %updated = $ea.update;
```

Updates all the meta-information and downloads any new distributions. Returns a hash with the identities and the meta info of any distributions that were not seen before.

TODO
====

Add support for the old, git based ecosystem.

AUTHOR
======

Elizabeth Mattijsen <liz@raku.rocks>

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

