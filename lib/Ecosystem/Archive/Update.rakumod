use Cro::HTTP::Client:ver<0.8.7>;
use JSON::Fast::Hyper:ver<0.0.3>:auth<zef:lizmat>;
use paths:ver<10.0.2>:auth<zef:lizmat>;
use Rakudo::CORE::META:ver<0.0.5+>:auth<zef:lizmat>;
use Identity::Utils:ver<0.0.10>:auth<zef:lizmat>;

# Locally stored JSON files are assumed to be correct
sub meta-from-io($io) { from-json $io.slurp } # , :immutable }

# Store given distribution at given io
sub meta-to-io(%distribution, $io) {
    $io.spurt: to-json %distribution, :!pretty, :sorted-keys
}

# Parsing JSON from text may get garbage, and may need adaptations
# so don't request an immutable version (as in future runs, it will
# have read from the stored JSON anyway, and thus have an immutable
# version
sub meta-from-text($text) { try from-json $text }

class Ecosystem::Archive::Update:ver<0.0.17>:auth<zef:lizmat> {
    has $.shelves      is built(:bind);
    has $.jsons        is built(:bind);
    has $.degree       is built(:bind);
    has $.batch        is built(:bind);
    has $.http-client  is built(:bind) = default-http-client;
    has %.identities   is built(False);
    has @!notes;
    has str  $!meta-as-json = "";
    has Lock $!meta-lock;
    has Lock $!note-lock;

    method TWEAK(--> Nil) {
        $!shelves := 'archive'            without $!shelves;
        $!jsons   := 'meta'               without $!jsons;
        $!degree  := Kernel.cpu-cores / 2 without $!degree;
        $!batch   := 64                   without $!batch;

        $!jsons    := $!jsons.IO;
        $!shelves  := $!shelves.IO;

        $!meta-lock := Lock.new;
        $!note-lock := Lock.new;

        with %Rakudo::CORE::META -> %meta {
            %!identities{%meta<dist>} := %meta;
        }

        self!update-meta: paths($!jsons, :file(*.ends-with('.json')))
          .race(:$!degree, :$!batch)
          .map: -> $path {
            my $io := $path.IO;
            my %meta := meta-from-io($io);
            with %meta<dist> -> $identity {
                $identity => %meta
            }
            else {
                self.note: "No identity found in $io.basename.chop(5)";
                Empty
            }
        }
    }

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
    sub github-download-URL($user, $repo, $tag = 'master') {
        "https://github.com/$user/$repo/archive/$tag.tar.gz"
    }
    sub gitlab-download-URL($user, $repo, $tag = 'master') {
        "https://gitlab.com/$user/$repo/-/archive/$tag/$repo-$tag.tar.gz"
    }
    sub url-encode($url) {
        $url
          .subst('%','%25',:g)
          .subst('<','%3C',:g)
          .subst('>','%3E',:g)
          .subst(':','%3A',:g)
          .subst('*','%2A',:g)
    }
    sub rea-download-URL($name, $identity, $extension) {
        url-encode 'https://raw.githubusercontent.com/raku/REA/main/archive/' ~
          "$name.substr(0,1).uc()/$name/$identity$extension"
    }

    sub sort-identities(@identities) {
        my %short-name = @identities.map: { $_ => short-name($_) }
        my str @ = @identities.sort: -> $a, $b {
          %short-name{$a} cmp %short-name{$b}
            || version($b) cmp version($a)
            || auth($a) cmp auth($b)
            || ver($b) cmp ver($a)  # 0.9.0 before 0.9
            || (api($a) // "") cmp (api($b) // "")
        }
    }

    method note($message --> Nil) {
        $!note-lock.protect: { @!notes.push: $message }
    }
    method notes() {
        $!note-lock.protect: { @!notes.List }
    }
    method clear-notes() {
        $!note-lock.protect: {
            my @notes is List = @!notes;
            @!notes = ();
            @notes
        }
    }

    method !update($force-json --> Nil) {
        await
          (start self!update-git($force-json)),
          (start self!update-cpan($force-json)),
          (start self!update-zef($force-json)),
        ;
    }

    method !update-meta(\updates --> Nil) {
        $!meta-lock.protect: {
            my %identities = %!identities;
            for updates -> (:key($identity), :value(%meta)) {
                %identities{$identity} := %meta;
            }
            %!identities  := %identities.Map;
        }
    }

    method !make-json-io($name, str $identity) {
        my $io := $!jsons.add($name.substr(0,1).uc).add($name);
        $io.mkdir;
        $io.add("$identity.json")
    }

    method !make-shelf-io(str $name, str $identity, str $extension) {
        my $io := $!shelves.add($name.substr(0,1).uc).add($name);
        $io.mkdir;
        $io.add($identity ~ $extension)
    }

    method !update-zef($force-json --> Nil) {
        my $resp := await $!http-client.get('https://360.zef.pm');
        self!update-meta: (await $resp.body)
          .race(:$!degree, :$!batch)
          .map: -> %meta {
            my $identity := %meta<dist>;
            if !$identity.contains(':api<') && %meta<api> -> $api {
                unless $api eq "0" {
                    $identity := $identity ~ ":api<$api>";
                    %meta<dist> := $identity;
                }
            }

            my $path := %meta<path>:delete;
            my $name := %meta<name>;
            %meta<source-url> :=
              rea-download-URL $name,$identity,extension($path);
            my $json  := self!make-json-io:  $name, $identity;
            my $shelf := self!make-shelf-io: $name, $identity, extension($path);
            if $json.e {
                if $force-json {
                    %meta<release-date> := self!distribution2yyyy-mm-dd($shelf);
                    meta-to-io(%meta, $json);
                    $identity => %meta;
                }

                # The meta provided by fez backend does not provide
                # release-date, so we need to fall back to locally
                # stored META, just as in the other backends.
                else {
                    $identity => from-json($json.slurp)
                }
            }
            elsif self!archive-distribution(
              "$zef-base-url/$path", $shelf
            ) -> $release-date {
                %meta<release-date> := $release-date;
                meta-to-io(%meta, $json);
                $identity => %meta
            }
            else {
                self.note: "Failed to archive $identity";
                Empty
            }
        }
    }

    method !update-cpan($force-json --> Nil) {
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

        # Hash with additional META info, keyed on CPAN ID + distro name
        my %valid;

        # Interrogate CPAN
        my $proc := shell @command, :out;
        for $proc.out.lines.grep({
             !.starts-with('id/P/PS/PSIXDISTS/')  # old attempt at CPAN coop
               && .contains('/Perl6/')
               && !.ends-with('/Perl6/')
        }).sort -> $path {

# sample lines
# id/A/AC/ACW/Perl6/Config-Parser-json-1.0.0.meta
# id/A/AC/ACW/Perl6/Config-Parser-json-1.0.0.tar.gz
            my @parts = $path.split('/');
            my $nick := @parts[3];
            my $nep5 := no-extension(@parts[5]);
            my $id   := "$nick:$nep5";

            # mention of .meta is always first
            if $path.ends-with('.meta') {

                # Because the path information does not tell us enough about
                # the distribution, we need to fetch the META file *always*
                # from CPAN.  Since we're sunsetting CPAN as a backend, this
                # should not really be an issue long-term.
                my $URL  := "$cpan-base-url/authors/$path";
                my $resp := await $!http-client.get($URL);
                my $text := (await $resp.body).decode;
                with meta-from-text($text) -> %meta {

                    # Version encoded in path has priority over version in
                    # META because PAUSE would not allow uploads of the same
                    # version encoded in the distribution name, but it *would*
                    # allow uploads with a non-matching version in the META.
                    # Also make sure we skip any "v" in the version string.
                    with $nep5.rindex('-') {
                        my $ver := $nep5.substr($_ + 1);
                        $ver := $ver.substr(1) if $ver.starts-with('v');

                        if $ver.contains(/ <-[\d \.]> /) {
                            self.note:
                              "$id has strange version, keeping meta";
                        }
                        elsif %meta<version> -> $version-in-meta {
                            if $version-in-meta ne $ver {
                                self.note:
                                  "$id has version mismatch: $version-in-meta";
                                %meta<version> := $ver;
                            }
                        }
                        else {
                            self.note:
                              "$id has no version in meta";
                            %meta<version> := $ver;
                        }

                        # Sadly, we must assume that the name in the META
                        # is correct, even though CPAN would not check for
                        # that.  But since the URL has replaced '::' with '-'
                        # there is no way to distinguish between "Foo::Bar"
                        # and "Foo-Bar" as module names from the URL.
                        if %meta<name> -> $name {

                            # Force auth to CPAN, as that's the only thing
                            # that really makes sense, as CPAN would allow
                            # uploads with just about any auth, and this way
                            # we make sure that modules on CPAN are accredited
                            # correctly and prevent module squatting this way.
                            my $auth := %meta<auth> := "cpan:@parts[3]";

                            # Make sure we have a matching identity in the
                            # META information.
                            my $identity :=
                              %meta<dist> :=
                                build $name, :$ver, :$auth, :api(%meta<api>);

                            # Set up META for later confirmation with
                            # actual tar file.
                            %valid{$id} := %meta;
                        }
                        else {
                            self.note: "$id has no name in META";
                        }
                    }
                    else {
                        self.note: "$id has no version in path";
                    }
                }
                else {
                    self.note: "$id has invalid JSON in META";
                }
            }

            # Not meta, so distribution info of which we should have seen meta
            elsif %valid{$id} -> %meta {
                my $name     := %meta<name>;
                my $identity := %meta<dist>;
                %meta<source-url> :=
                  rea-download-URL $name,$identity,extension($path);
                my $json     := self!make-json-io($name, $identity);
                if self!archive-distribution(
                  "$cpan-base-url/authors/$path",
                  self!make-shelf-io($name, $identity, extension($path))
                ) -> $release-date {
                    %meta<release-date> := $release-date;
                    meta-to-io(%meta, $json)
                }
                elsif $force-json {
                    meta-to-io(%meta, $json)
                }
                else {
                    self.note: "Could not get archive for $id";
                    %valid{$id}:delete;
                }
            }
            else {
                self.note: "$id has no valid META info?";
            }
        }

        # Make sure the meta info is ok
        self!update-meta: %valid.values.map: -> %meta {
            %meta<dist> => %meta
        }
    }

    method !update-git($force-json --> Nil) {
        my $resp := await $!http-client.get:
          'https://raw.githubusercontent.com/Raku/ecosystem/master/META.list';
        my $text := await $resp.body;
        my $lock := Lock.new;
        my @failed-URLs;

        self!update-meta: $text.lines
          .race(:$!degree, :$!batch)
          .map: -> $URL {
            CATCH {
                $lock.protect: { @failed-URLs.push: $URL }
                next
            }
            my $result := Empty;

            my $resp := await $!http-client.get($URL);
            my $text := await $resp.body;
            with meta-from-text($text) -> %meta {
                my $name := %meta<name>;
                if $name && $name.contains(' ') {
                    self.note: "$URL: invalid name '$name'";
                }
                elsif $name {
                    if %meta<version> -> $ver {
# examples:
# https://raw.githubusercontent.com/bbkr/TinyID/master/META6.json
# https://gitlab.com/CIAvash/App-Football/raw/master/META6.json
                        my @parts = $URL.split('/');
                        if determine-base(@parts[2]) -> $base {
                            my $user := @parts[3];
                            my $repo := @parts[4];

                            unless $user eq 'AlexDaniel'
                              and $repo.contains('foo') {
                                my $auth := "$base:$user";
                                if %meta<auth> -> $found {
                                    if $found ne $auth {
                                        self.note: "auth: $name: $found -> $auth";
                                        %meta<auth> := $auth;
                                    }
                                }

                                # various checks and fixes
                                my $identity :=
                                  build $name, :$ver, :$auth, :api(%meta<api>);
                                if %meta<dist> -> $dist {
                                    if $dist ne $identity {
                                        self.note: "identity $name: $dist -> $identity";
                                        %meta<dist> := $identity;
                                    }
                                }
                                else {
                                    %meta<dist> := $identity;
                                }

                                my $json := self!make-json-io($name, $identity);
                                %meta<source-url> :=
                                  rea-download-URL $name, $identity, '.tar.gz';
                                if $json.e {
                                    meta-to-io(%meta,$json)
                                      if $force-json;
                                }
# Since we cannot determine easily what the default branch is of a repo, we
# just try the ones that we know are being used in the ecosystem in order of
# likeliness to succeed, and write the meta info as soon as we could download
# a tar file.
                                else {
                                    if <master main dev>.first(-> $branch {
                                          try self!archive-distribution(
                                            ::("&$base\-download-URL")(
                                              $user, $repo, $branch
                                            ),
                                            self!make-shelf-io(
                                              $name, $identity, '.tar.gz'
                                            )
                                          )
                                    }) {
                                        meta-to-io(%meta,$json);
                                        $result := $identity => %meta # NEW!
                                    }
                                    else {
                                       self.note: "no valid branch found";
                                    }
                                }
                            }
                        }
                        else {
                            self.note: "$URL: no base determined";
                        }
                    }
                    else {
                        self.note: "$URL: no version";
                    }
                }
                else {
                    self.note: "$URL: no name";
                }
            }
            else {
                self.note: "$URL: invalid JSON";
            }
            $result
        }

        if @failed-URLs {
            note "Failed URLs:";
            note "  $_" for @failed-URLs;
        }
    }

    method meta-as-json() {
        $!meta-lock.protect: {
            $!meta-as-json ||= to-json
              %!identities.values.sort( -> %a, %b {
                  my $a := %a<dist>;
                  my $b := %b<dist>;
                  short-name($a)       cmp short-name($b)
                    || version($b)     cmp version($a)
                    || auth($a)        cmp auth($b)
                    || ver($b)         cmp ver($a)  # 0.9.0 before 0.9
                    || (api($a) // "") cmp (api($b) // "")
              }),
              :sorted-keys
        }
    }

    # Return YYYY-MM-DD of most recent file in tar-file
    method !distribution2yyyy-mm-dd(IO::Path:D $io) {
        my $tmp := 'tmp' ~ $*THREAD.id;
        mkdir $tmp;
        my $date = indir $tmp, {
            run 'tar', 'xf', "$io.absolute()";
            Date.new(paths.map(*.IO.modified).max)
        }
        run 'rm', '-rf', $tmp;
        $date.yyyy-mm-dd
    }

    # Archive distribution, return whether JSON should be updated
    method !archive-distribution($URL, $io) {
        # Don't load if we already have it (it's static!), and assume that
        # the META is already up-to-date.
        if $io.e {
            Nil
        }
        else {
            CATCH {
                self.note: "$URL failed to load";
                return Nil;
            }
            my $resp := await $!http-client.get($URL);
            $io.spurt(await $resp.body);
            self!distribution2yyyy-mm-dd($io)
        }
    }

    method update(:$force-json) {
        my %before := %!identities.clone;
        self!update($force-json);
        Map.new((
          %!identities.grep({ %before{.key}:!exists })
        ))
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

                my $json := "META6.json".IO;
                $json := "META.info".IO unless $json.e;
                last unless $json.e;  # no json, can't do anything anymore

                with try meta-from-io($json) -> %meta {
                    my $name := %meta<name>;
                    my $auth := %meta<auth>;
                    $auth := "$base:$default-auth"
                      unless $auth && $auth.contains(":");

                    my $identity := build
                      $name, :ver(%meta<version>), :$auth, :api(%meta<api>);

                    unless %!identities{$identity} {
                        my $io := $!jsons.add($name);
                        $io.mkdir;
                        $io := $io.child("$identity.json");

                        if try self!archive-distribution(
                            ::("&$base\-download-URL")($user, $repo, $sha),
                            self!make-shelf-io($name, $identity, '.tar.gz')
                        ) -> $release-date {
                            %meta<auth>         := $auth;
                            %meta<release-date> := $release-date;
                            meta-to-io(%meta, $io);
                            @added.push: $identity => %meta;
                        }
                    }
                }

                $proc := run <git blame>, $json, :out;
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
}

=begin pod

=head1 NAME

Ecosystem::Archive::Update - Updating the Raku Ecosystem Archive

=head1 SYNOPSIS

=begin code :lang<raku>

use Ecosystem::Archive::Update;

my $ea = Ecosystem::Archive::Update.new(
  shelves     => 'archive',
  jsons       => 'meta',
  http-client => default-http-client
);

say "Archive has $ea.meta.elems() identities:";
.say for $ea.meta.keys.sort;

=end code

=head1 DESCRIPTION

Ecosystem::Archive::Update provides the basic logic to updating the Raku
Ecosystem Archive, a place where (almost) every distribution ever available
in the Raku Ecosystem, can be obtained even after it has been removed
(specifically in the case of the old ecosystem master list and the
distributions kept on CPAN).

=head2 ARGUMENTS

=item shelves

The name (or an C<IO> object) of a directory in which to place distributions.
This is usually a symlink to the "archive" directory of the actual
L<Raku Ecosystem Archive repository|https://github.com/lizmat/REA>.
The default is 'archive', aka the 'archive' subdirectory from the current
directory.

=item jsons

The name (or an C<IO> object) of a directory in which to store C<META6.json>
files as downloaded.  This is usually a symlink to the "meta" directory of
the actual L<Raku Ecosystem Archive repository|https://github.com/lizmat/REA>.
The default is 'meta', aka the 'meta' subdirectory from the current directory.

=item http-client

The C<Cro::HTTP::Client> object to do downloads with.  Defaults to a
C<Cro::HTTP::Client> object that advertises this module as its User-Agent.

=item degree

The number of CPU cores that may be used for parallel processing.  Defaults
to the B<half> number of C<Kernel.cpu-cores>.

=item batch

The number of objects to be processed in parallel per batch.  Defaults to
B<64>.

=head1 METHODS

=head2 batch

=begin code :lang<raku>

say "Processing with batches of $ea.batch() objects in parallel";

=end code

The number of objects per batch that will be used in parallel processing.

=head2 clear-notes

=begin code :lang<raku>

my @cleared = $ea.clear-notes;
say "All notes have been cleared";

=end code

Returns the C<notes> of the object as a C<List>, and removes them from the
object.

=head2 degree

=begin code :lang<raku>

say "Using $ea.degree() CPUs";

=end code

The number of CPU cores that will be used in parallel processing.

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

Only C<Github> and C<Gitlab> URLs are currently supported.

Returns a list of C<Pair>s of the distributions that were added,  with the
identity as the key, and the META information hash as the value.

Updates the C<.meta> information in a thread-safe manner.

=head2 jsons

=begin code :lang<raku>

indir $ea.jsons, {
    my $jsons = (shell 'ls */*', :out).out.lines.elems;
    say "$jsons different distributions";
}

=end code

The C<IO> object of the directory in which the JSON meta files are being
stored.  For instance the C<IRC::Client> distribution:

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

=head2 identities

=begin code :lang<raku>

say "Archive has $ea.identities.elems() identities, they are:";
.say for $ea.identities.keys.sort;

=end code

Returns a hash of all of the META information of all distributions, keyed
by identity (for example "Module::Name:ver<0.1>:auth<foo:bar>:api<1>").
The value is a hash obtained from the distribution's meta data.

=head2 meta-as-json

=begin code :lang<raku>

say $ea.meta-as-json;  # at least 3MB of text

=end code

Returns the JSON of all the currently known meta-information.  The
JSON is ordered by identity in the top level array.

=head2 note

=begin code :lang<raku>

$ea.note("something's wrong");

=end code

Add a note to the C<notes> of the object.

=head2 notes

=begin code :lang<raku>

say "Found $ea.notes.elems() notes:";
.say for $ea.notes;

=end code

Returns the C<notes> of the object as a C<List>.

=head2 shelves

=begin code :lang<raku>

indir $ea.shelves, {
    my $distro-names = (shell 'ls */*/*', :out).out.lines.elems;
    say "$distro-names different distributions in archive";
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

=head2 update

=begin code :lang<raku>

my %updated = $ea.update;

=end code

Updates all the meta-information and downloads any new distributions.
Returns a hash with the identities and the meta info of any distributions
that were not seen before.  Also updates the C<.identities> information in
a thread-safe manner.

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/Ecosystem-Archive-Update .
Comments and Pull Requests are welcome.

If you like this module, or what I’m doing more generally, committing to a
L<small sponsorship|https://github.com/sponsors/lizmat/>  would mean a great
deal to me!

=head1 COPYRIGHT AND LICENSE

Copyright 2021, 2022 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
