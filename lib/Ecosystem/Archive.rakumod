use Cro::HTTP::Client:ver<0.8.6>;
use JSON::Fast:ver<0.16>;

class Ecosystem::Archive:ver<0.0.1>:auth<zef:lizmat> {
    has $.shelves      is built(:bind) = 'archive';
    has $.git-meta     is built(:bind) = 'git-meta';
    has $.cpan-meta    is built(:bind) = 'cpan-meta';
    has $.zef-meta     is built(:bind) = 'zef-meta';
    has $.http-client  is built(:bind) = default-http-client;
    has %.meta         is built(False);
    has %.modules      is built(False);
    has $.meta-as-json is built(False);
    has $!meta-lock;

    sub default-http-client() {
        Cro::HTTP::Client.new(
          user-agent => $?CLASS.^name ~ ' ' ~ $?CLASS.^ver,
          :http<1.1>,  # for now
        )
    }

    my constant $zef-base-url  = 'https://360.zef.pm';
    my constant $cpan-base-url = 'http://www.cpan.org';
    my constant @extensions = <.meta .tar.gz .tgz .zip>;

    sub no-extension($string) {
        return $string.chop(.chars) if $string.ends-with($_) for @extensions;
    }
    sub extension($string) {
        @extensions.first: { $string.ends-with($_) }
    }
    sub determine-base($domain) {
        $domain eq 'raw.githubusercontent.com' | 'github.com'
          ?? 'github'
          !! $domain eq 'gitlab.com'
            ?? 'gitlab'
            !! Nil
    }
    sub build-identity($name, $version, $auth, $api) {
        my $identity := $name ~ ":ver<$version>:auth<$auth>";
        ($api && $api ne "0")
          ?? $identity ~ ":api<$api>"
          !! $identity
    }
    sub github-download-URL($user, $repo, $tag = 'master') {
        "https://github.com/$user/$repo/archive/$tag.tar.gz"
    }
    sub gitlab-download-URL($user, $repo, $tag = 'master') {
        "https://gitlab.com/$user/$repo/-/archive/$tag/$repo-$tag.tar.gz"
    }
    sub subdir-json($initial, $dir, $file) {
        my $io := $initial.add($dir);
        $io.mkdir;
        $io.add("$file.json")
    }

    method TWEAK(--> Nil) {
        $!git-meta  := $!git-meta.IO;
        $!cpan-meta := $!cpan-meta.IO;
        $!zef-meta  := $!zef-meta.IO;
        $!shelves   := $!shelves.IO;
        $!meta-lock := Lock.new;

        await
          (start self!read-zef),
          (start self!read-cpan),
          (start self!read-git),
        ;
    }

    method !read-json($dir) {
        indir $dir, {
            my $proc := shell 'ls */*', :out;
            self!update-meta: $proc.out.lines
              .race
              .map: -> $filename {
                my %distribution := from-json $filename.IO.slurp;
                %distribution<dist> => %distribution
                  unless %distribution<error>;
            }
        }
    }

    method !read-zef( --> Nil) { self!read-json($!zef-meta)  }
    method !read-cpan(--> Nil) { self!read-json($!cpan-meta) }
    method !read-git(--> Nil) {
        indir $!git-meta, {
            my $proc := shell 'ls */*', :out;
            self!update-meta: $proc.out.lines
              .race
              .map: -> $filename {
                my %distribution := from-json $filename.IO.slurp;
                $filename.split('/').tail.chop(5) => %distribution
                  unless %distribution<error>;
            }
        }
    }

    method !update(--> Nil) {
        await
          (start self!update-git),
          (start self!update-cpan),
          (start self!update-zef),
        ;
        self!update-meta-as-json;
    }

    method !update-meta(\updates --> Nil) {
        $!meta-lock.protect: {
            my %meta    := %!meta.clone;
            my %modules := %!modules.clone;
            for updates -> (:key($identity), :value(%distribution)) {
                %meta{$identity} := %distribution;
                if %distribution<provides> -> %provides {
                    %modules.push($_, $identity) for %provides.keys;
                }
            }
            %!meta    := %meta;
            %!modules := %modules;
        }
    }

    method !update-zef(--> Nil) {
        my $resp := await $!http-client.get('https://360.zef.pm');
        self!update-meta: (await $resp.body)
          .race
          .map: -> %distribution {
            my $identity := %distribution<dist>;
            if !$identity.contains(':api<') && %distribution<api> -> $api {
                unless $api eq "0" {
                    $identity := $identity ~ ":api<$api>";
                    %distribution<dist> := $identity;
                }
            }

            my $json := $!zef-meta.add(%distribution<name>);
            $json.mkdir;
            $json := $json.add("$identity.json");
            unless $json.e {
                my $path := %distribution<path>;
                self!archive-distribution(
                  "$zef-base-url/$path",
                  %distribution<name>,
                  $identity,
                  extension($path)
                );
                $json.spurt: to-json(%distribution, :!pretty);
            }

            $identity => %distribution
        }
    }

    method !update-cpan(--> Nil) {
        my @includes = BEGIN @extensions.map: {  # my constant @ dies
            '--include="/id/*/*/*/Perl6/*' ~ $_ ~ '"'
        }

        # The magic CPAN incantation to get all Raku module info
        my @command =
          '/usr/bin/rsync', '--dry-run', '--prune-empty-dirs', '-av', 
          '--include="/id/*/*/*/Perl6/"',
          @includes,
          '--exclude="/id/*/*/*/Perl6/*"',
          '--exclude="/id/*/*/*/*"',
          '--exclude="id/*/*/CHECKSUMS"',
          '--exclude="id/*/CHECKSUMS"',
          'cpan-rsync.perl.org::CPAN/authors/id', 'CPAN';

        my %new;
        my $proc := shell @command, :out;
        for $proc.out.lines.grep({
             !.starts-with('id/P/PS/PSIXDISTS/')
               && .contains('/Perl6/')
               && !.ends-with('/Perl6/')
        }).sort -> $path {

# sample lines
# id/A/AC/ACW/Perl6/Config-Parser-json-1.0.0.meta
# id/A/AC/ACW/Perl6/Config-Parser-json-1.0.0.tar.gz
            my @parts = $path.split('/');
            my $nick := @parts[3];
            my $id   := "$nick:&no-extension(@parts[5])";
            my $json := subdir-json($!cpan-meta, $nick, $id);

            # mention of .meta is always first
            if $path.ends-with('.meta') {
                next if $json.e;  # already done this one

                my $URL  := "$cpan-base-url/authors/$path";
                my $resp := await $!http-client.get($URL);

                my %distribution = error => 'Invalid JSON file in distribution';
                my $text := (await $resp.body).decode;
                %distribution = $_ with try from-json $text;

                # Version encoded in path has priority over version in META
                # because PAUSE would not allow uploads of the same version
                # encoded in the distribution name, but it *would* allow
                # uploads with a non-matching version in the META.  Also make
                # sure we skip any "v" in the version string.
                with $id.rindex('-') {
                    my $version := $id.substr($_ + 1);
                    $version := $version.substr(1) if $version.starts-with('v');
say $id if !%distribution<version> || $version ne %distribution<version>;
                    %distribution<version> := $version
                      unless $version.contains(/ <-[\d \.]> /);
                }

                %new{$id} := %distribution;
            }

            # not meta, so distribution info of which we should have seen meta
            elsif %new{$id} -> %distribution {
                unless %distribution<error> {
                    # META sometimes lies
                    %distribution<auth> := "cpan:@parts[3]";

                    my $name     := %distribution<name>;
                    my $identity := $name
                      ~ ':ver<'
                      ~ %distribution<version>
                      ~ '>:auth<'
                      ~ %distribution<auth>
                      ~ '>';
                    if %distribution<api> -> $api {
                        $identity := $identity ~ ":api<$api>"
                          unless $api eq "0";
                    }

                    # save identity in zef ecosystem compatible way
                    %distribution<dist> := $identity;

                    self!archive-distribution(
                      "$cpan-base-url/authors/$path",
                      $name, $identity, extension($path)
                    );
                }
                $json.spurt: to-json(%distribution, :!pretty);
            }
        }

        self!update-meta: $!cpan-meta
          .dir(test => *.ends-with(q/.json/))
          .race
          .map: -> $io {
            my %distribution := from-json $io.slurp;
            %distribution<dist> => %distribution
              unless %distribution<error>
        }
    }

    method !update-git(--> Nil) {
        my $resp := await $!http-client.get:
          'https://raw.githubusercontent.com/Raku/ecosystem/master/META.list';
        my $text := await $resp.body;
        self!update-meta: $text.lines
          .race
          .map: -> $URL {
            my $resp := {
                CATCH { say "problem with $URL" }
                await $!http-client.get($URL)
            }();
            my $text := await $resp.body;
            my %distribution = error => 'Invalid JSON file in distribution';
            %distribution = $_ with try from-json $text;

            my $name := %distribution<name>;
            if $name && $name.contains(' ') {
                say "$URL: invalid name '$name'";
            }
            elsif $name {
                if %distribution<version> -> $version {
# examples:
# https://raw.githubusercontent.com/bbkr/TinyID/master/META6.json
# https://gitlab.com/CIAvash/App-Football/raw/master/META6.json
                    my @parts = $URL.split('/');
                    if determine-base(@parts[2]) -> $base {
                        my $user := @parts[3];
                        my $repo := @parts[4];

                        unless $user eq 'AlexDaniel' and $repo.contains('foo') {
                            my $auth := "$base:$user";
                            if %distribution<auth>
                              && %distribution<auth> ne $auth {
# say "MISMATCH: $name: %distribution<auth> -> $auth";
                                %distribution<auth> := $auth;
                            }

                            my $identity := build-identity(
                              $name, $version, $auth, %distribution<api>
                            );
                            my $json := subdir-json($!git-meta,$name,$identity);
                            unless $json.e {
# Since we cannot determine easily what the default branch is of a repo, we
# just try the ones that we know are being used in the ecosystem in order of
# likeliness to succeed, and write the meta info as soon as we could download
# a tar file.
                                $json.spurt(to-json %distribution, :!pretty)
                                  if <master main dev>.first: -> $branch {
                                      try self!archive-distribution(
                                        ::("&$base\-download-URL")(
                                          $user, $repo, $branch
                                        ),
                                        $name, $identity, '.tar.gz'
                                      )
                                  }
                            }
                        }
                    }
                    else {
                        say "$URL: no base determined";
                    }
                }
                else {
                    say "$URL: no version";
                }
            }
            else {
                say "$URL: no name";
            }
            Empty;
        }
    }

    method !update-meta-as-json() {
        $!meta-as-json := to-json(%!meta.sort(*.key).map(*.value), :!pretty)
    }

    method !archive-distribution($URL, $name, $identity, $extension) {
        my $io := $!shelves.add($name.substr(0,1).uc).add($name);
        $io.mkdir;
        $io := $io.add($identity ~ $extension);

        # don't load if we already have it, it's static
        unless $io.e {
            CATCH {
                note "$URL failed";
            }
            my $resp := await $!http-client.get($URL);
            $io.spurt(await $resp.body);
        }

        True
    }

    method update() {
        my %meta := %!meta.clone;
        self!update;
        %meta{%!meta.keys}:delete;
        %meta
    }

    method investigate-repo($url, $default-auth) {
        my $cloned := $*SPEC.tmpdir.add(now.Num).absolute;
        LEAVE run <rm -rf>, $cloned;

        my @parts = $url.split("/");
        return Empty
          unless my $base := determine-base(@parts[2]);
        my $user := @parts[3];
        my $repo := @parts[4].split('.').head;

        my @added;
        run <git clone>, $url, $cloned, :!out, :!err;
        indir $cloned, {
            my $proc := run <git branch>, :out;
            my $default = $proc.out.lines.first(*.starts-with('* ')).substr(2);

            $proc := run <git rev-list --date-order>, $default, :out;
            my @shas = $proc.out.lines;

            my $sha = $default;
            my %versions;
            loop {
                run <git checkout>, $sha, :!out, :!err;

                my $meta := "META6.json".IO;
                $meta := "META.info".IO unless $meta.e;
                last unless $meta.e;  # no meta, can't do anything anymore

                with try from-json $meta.slurp -> %json {
                    my $name := %json<name>;
                    my $auth := %json<auth>;
                    $auth := "$base:$default-auth"
                      unless $auth && $auth.contains(":");

                    my $identity := build-identity(
                      $name, %json<version>, $auth, %json<api>
                    );

                    unless %!meta{$identity} {
                        my $io := $!git-meta.add($name);
                        $io.mkdir;
                        $io := $io.child("$identity.json");

                        if try self!archive-distribution(
                            ::("&$base\-download-URL")($user, $repo, $sha),
                            $name, $identity, '.tar.gz'
                        ) {
                            %json<auth> := $auth;
                            $io.spurt: to-json %json, :!pretty;
                            @added.push: $identity => %json;
                        }
                    }
                }

                $proc := run <git blame>, $meta, :out;
                my $line := $proc.out.lines.first: *.contains('"version"');
                last unless $line;

                $sha = $line.words.head;
                $sha = $sha.substr(1) if $sha.starts-with('^');
                with @shas.first(*.starts-with($sha), :k) -> $index {
                    last if $index == @shas.end;
                    $sha = @shas[$index + 1];
                }
                else {
                    last;
                }
            }
        }

        self!update-meta(@added);
        @added
    }

    method find-identities($name, :$ver, :$auth, :$api) {
        my constant regex = / ':ver<' <( <-[>]>+ )> /;

        with %!modules{$name} -> @identities {
            with $auth {
                my $needle  := ":auth<$auth>";
                @identities .= grep(*.contains($needle));
            }
            with $api {
                if $api ne '0' {
                    my $needle  := ":api<$api>";
                    @identities .= grep(*.contains($needle));
                }
            }
            with $ver {
                if $ver ne '*' {
                    my $version := $ver.Version;
                    my &op := $ver.contains("+" | "*")
                      ?? &infix:«>»
                      !! &infix:«==»;
                    @identities .= grep: {
                        op .match(regex).Str.Version, $version
                    }
                }
            }

            @identities.sort(*.match(regex)).reverse
        }
    }

    method distro($identity) {
        my $io := $!shelves
          .add($identity.substr(0,1).uc)
          .add($identity.substr(0,$identity.index(':ver<')))
          .add("$identity.tar.gz");
        $io.e ?? $io !! Nil
    }
}

=begin pod

=head1 NAME

Ecosystem::Archive - Interface to the Raku Ecosystem Archive

=head1 SYNOPSIS

=begin code :lang<raku>

use Ecosystem::Archive;

my $ea = Ecosystem::Archive.new(
  shelves     => 'archive',
  cpan-meta   => 'cpan-meta',
  git-meta    => 'git-meta',
  http-client => default-http-client
);

say "Archive has $ea.meta.elems() identities:";
.say for $ea.meta.keys.sort;

=end code

=head1 DESCRIPTION

Ecosystem::Archive provides the basic logic to the Raku Programming
Language Ecosystem Archive, a place where (almost) every distribution
ever available in the Raku Ecosystem, can be obtained even after it has
been removed (specifically in the case of the old ecosystem master list
and the distributions kept on CPAN).

=head2 ARGUMENTS

=item shelves

The name (or an C<IO> object) of a directory in which to place distributions.
This is usually a symlink to the "archive" directory of the actual
L<Raku Ecosystem Archive repository|https://github.com/lizmat/REA>.
The default is 'archive', aka the 'archive' subdirectory from the current
directory.

=item cpan-meta

The name (or an C<IO> object) of a directory in which to store C<META6.json>
files as downloaded from CPAN (and cleaned up).  This is usually a symlink
to the "cpan-meta" directory of the actual
L<Raku Ecosystem Archive repository|https://github.com/lizmat/REA>.
The default is 'cpan-meta', aka the 'cpan-meta' subdirectory from the current
directory.

=item git-meta

The name (or an C<IO> object) of a directory in which to store C<META6.json>
files as downloaded from the old git-based ecosystem.  This is usually a
symlink to the "git-meta" directory of the actual
L<Raku Ecosystem Archive repository|https://github.com/lizmat/REA>.
The default is 'git-meta', aka the 'git-meta' subdirectory from the current
directory.

=item http-client

The C<Cro::HTTP::Client> object to do downloads with.  Defaults to a
C<Cro::HTTP::Client> object that advertises this module as its User-Agent.

=head1 METHODS

=head2 shelves

=begin code :lang<raku>

indir $ea.shelves {
    my $distros = (shell 'ls */*', :out).out.lines.elems;
    say "$distros different distributions in archive";
}

=end code

The C<IO> object of the directory where distributions are being stored
in a subdirectory by the name of the module in the distribution.  For
instance the C<silently> distribution:

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

Note that a subdirectory will contain B<all> distributions of the name,
regardless of version, authority or API value.

=head2 cpan-meta

=begin code :lang<raku>

indir $ea.cpan-meta {
    my $jsons = (shell 'ls */*', :out).out.lines.elems;
    say "$jsons different distributions on CPAN";
}

=end code

The C<IO> object of the directory in which the CPAN meta files are being
stored.  For instance the C<silently> distribution:

  cpan-meta
    |- ...
    |- ELIZABETH
        |- ...
        |- ELIZABETH:silently-0.0.1.json
        |- ELIZABETH:silently-0.0.2.json
        |- ELIZABETH:silently-0.0.3.json
        |- ...
    |- ...

=head2 distro

=begin code :lang<raku>

my $identity = $ea.find-identities('eigenstates').head;
say $ea.distro($identity);

=end

Returns an C<IO> object for the given identity, or C<Nil> if it can not be
found.

=head2 find-identities

=begin code :lang<raku>

my @identities = $ea.find-identities('eigenstates', :ver<0.0.3*>);
say "@identities[0] is the most recent";

=end code

Find the identities that supply the given module name (as a positional
parameter) and possible refinement with named parameters for C<:ver>,
C<:auth> and C<:api>.  Note that the C<:ver> specification can contain
C<+> or C<*> to indicate a range rather than a single version.

The identities will be returned sorted by highest version first.  So if
you're interested in only the most recent version, then just select the
first element returned.

=head2 git-meta

=begin code :lang<raku>

indir $ea.git-meta {
    my $jsons = (shell 'ls */*', :out).out.lines.elems;
    say "$jsons different distributions on old ecosystem";
}

=end code

The C<IO> object of the directory in which the meta files of the old
ecosystem (using git) are being stored.  For instance the C<IRC::Client>
distribution:

  git-meta
    |- ...
    |- IRC::Client
        |- IRC::Client:ver<1.001001>:auth<github:zoffixznet>.json
        |- IRC::Client:ver<1.002001>:auth<github:zoffixznet>.json
        |- ...
        |- IRC::Client:ver<3.007010>:auth<github:zoffixznet>.json
        |- IRC::Client:ver<3.007011>:auth<cpan:ELIZABETH>.json
        |- IRC::Client:ver<3.009990>:auth<cpan:ELIZABETH>.json
    |- ...

=head2 http-client

=begin code :lang<raku>

say "Information fetched as '$ea.http-client.user-agent()'";

=end code

The C<Cro::HTTP::Client> object that is used for downloading information
from the Internet.

=head2 investigate-repo

=begin code :lang<raku>

my @found = $ea.investigate-repo($url, "lizmat");

=end code

Performs a C<git clone> on the given URL, scans the repo for changes in the
C<META6.json> file that would change the version, and downloads and saves
a tar-file of the repository (and the associated META information in
C<git-meta>) at that state of the repository.

The second positional parameter indicates the default C<auth> value to be
applied to any JSON information, if no C<auth> value is found or it is
invalid.

Only C<Github> and C<Gitlab> URLs acre currently supported.

Returns a list of C<Pair>s of the distributions that were added,  with the
identity as the key, and the META information hash as the value.

Updates the C<.meta> and C<.modules> meta-information in a thread-safe
manner.

=head2 meta

=begin code :lang<raku>

say "Archive has $ea.meta.elems() identities, they are:";
.say for $ea.meta.keys.sort;

=end code

Returns a hash of all of the META information of all distributions, keyed
by identity (for example "Module::Name:ver<0.1>:auth<foo:bar>:api<1>").
The value is a hash obtained from the distribution's meta data.

=head2 meta-as-json

=begin code :lang<raku>

say $ea.meta-as-json;  # at least 3MB of text

=end code

Returns the JSON of all the currently known meta-information.

=head2 modules

=begin code :lang<raku>

say "Archive has $ea.modules.elems() different modules, they are:";
.say for $ea.modules.keys.sort;

=end code

Returns a hash keyed by module name, with a list of identities that
provide that module name, as value.

=head2 update

=begin code :lang<raku>

my %updated = $ea.update;

=end code

Updates all the meta-information and downloads any new distributions.
Returns a hash with the identities and the meta info of any distributions
that were not seen before.  Also updates the C<.meta> and C<.modules>
information in a thread-safe manner.

=head2 zef-meta

=begin code :lang<raku>

indir $ea.zef-meta {
    my $jsons = (shell 'ls */*', :out).out.lines.elems;
    say "$jsons different distributions in the zef ecosystem";
}

=end code

The C<IO> object of the directory in which the meta files of the zef
ecosystem are being stored.  For instance the C<IRC::Client> distribution:

  zef-meta
    |- ...
    |- IRC::Client
        |- IRC::Client:ver<4.0.0>:auth<zef:lizmat>.json
        |- ...
    |- ...

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
