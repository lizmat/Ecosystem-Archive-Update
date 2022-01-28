use Cro::HTTP::Client:ver<0.8.7>;
use JSON::Fast::Hyper:ver<0.0.1>:auth<zef:lizmat>;
use paths:ver<10.0.2>:auth<zef:lizmat>;
use Rakudo::CORE::META:ver<0.0.3>:auth<zef:lizmat>;
use Identity::Utils:ver<0.0.6>:auth<zef:lizmat>;

# Locally stored JSON files are assumed to be correct
sub distribution-from-io($io) { from-json $io.slurp } # , :immutable }

# Store given distribution at given io
sub distribution-to-io(%distribution, $io) {
    $io.spurt: to-json %distribution, :!pretty, :sorted-keys
}

# Parsing JSON from text may get garbage, and may need adaptations
# so don't request an immutable version (as in future runs, it will
# have read from the stored JSON anyway, and thus have an immutable
# version
sub distribution-from-text($text) { try from-json $text }

class Ecosystem::Archive::Update:ver<0.0.9>:auth<zef:lizmat> {
    has $.shelves      is built(:bind);
    has $.jsons        is built(:bind);
    has $.degree       is built(:bind);
    has $.batch        is built(:bind);
    has $.http-client  is built(:bind) = default-http-client;
    has %.identities   is built(False);
    has %.distro-names is built(False);
    has %.use-targets  is built(False);
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

        with %Rakudo::CORE::META -> %distribution {
            my $name     := %distribution<name>;
            my $identity := %distribution<dist>;

            %!identities{$identity} := %distribution;
            %!distro-names{$name}  := my str @ = $identity;
            for %distribution<provides>.keys {
                %!use-targets{$_} := my str @ = $identity;
            }
        }

        self!update-meta: paths($!jsons, :file(*.ends-with('.json')))
          .race(:$!degree, :$!batch)
          .map: -> $path {
            my $io := $path.IO;
            my %distribution := distribution-from-io($io);
            with %distribution<dist> -> $identity {
                $identity => %distribution
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
    sub rea-download-URL($name, $identity, $extension) {
        'https://raw.githubusercontent.com/raku/REA/main/archive/' ~
          "$name.substr(0,1).uc()/$name/$identity$extension"
          .subst('<','%3C',:g).subst('>','%3E',:g)
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
            my %identities   = %!identities;
            my %use-targets  = %!use-targets;
            my %distro-names = %!distro-names;

            my %updated-use-targets;
            my %updated-distro-names;

            for updates -> (:key($identity), :value(%distribution)) {
                %identities{$identity} := %distribution;

                given %distribution<name> {
                    (%distro-names{$_} // (%distro-names{$_} := my str @))
                      .push($identity);
                    %updated-distro-names{$_}++;
                }

                if %distribution<provides> -> %provides {
                    for %provides.keys {
                        (%use-targets{$_} // (%use-targets{$_} := my str @))
                          .push($identity);
                        %updated-use-targets{$_}++;
                    }
                }
            }

            if %updated-distro-names {
                for %updated-distro-names.keys -> $distro {
                    %distro-names{$distro} :=
                      sort-identities %distro-names{$distro};
                }
                for %updated-use-targets.keys -> $module {
                    %use-targets{$module} :=
                      sort-identities %use-targets{$module};
                }
                %!identities   := %identities.Map;
                %!use-targets  := %use-targets.Map;
                %!distro-names := %distro-names.Map;
                $!meta-as-json  = "";
            }
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
          .map: -> %distribution {
            my $identity := %distribution<dist>;
            if !$identity.contains(':api<') && %distribution<api> -> $api {
                unless $api eq "0" {
                    $identity := $identity ~ ":api<$api>";
                    %distribution<dist> := $identity;
                }
            }

            my $path := %distribution<path>:delete;
            %distribution<source-url> :=
              rea-download-URL %distribution<name>,$identity,extension($path);
            my $json  := self!make-json-io: %distribution<name>, $identity;
            my $shelf := self!make-shelf-io:
              %distribution<name>, $identity, extension($path);
            if $json.e {
                if $force-json {
                    %distribution<release-date> :=
                      self!distribution2yyyy-mm-dd($shelf);
                    distribution-to-io(%distribution, $json);
                    $identity => %distribution;
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
                %distribution<release-date> := $release-date;
                distribution-to-io(%distribution, $json);
                $identity => %distribution
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
                with distribution-from-text($text) -> %distribution {

                    # Version encoded in path has priority over version in
                    # META because PAUSE would not allow uploads of the same
                    # version encoded in the distribution name, but it *would*
                    # allow uploads with a non-matching version in the META.
                    # Also make sure we skip any "v" in the version string.
                    with $nep5.rindex('-') {
                        my $version := $nep5.substr($_ + 1);
                        $version := $version.substr(1)
                          if $version.starts-with('v');

                        if $version.contains(/ <-[\d \.]> /) {
                            self.note:
                              "$id has strange version, keeping meta";
                        }
                        elsif %distribution<version> -> $version-in-meta {
                            if $version-in-meta ne $version {
                                self.note:
                                  "$id has version mismatch: $version-in-meta";
                                %distribution<version> := $version;
                            }
                        }
                        else {
                            self.note:
                              "$id has no version in meta";
                            %distribution<version> := $version;
                        }

                        # Sadly, we must assume that the name in the META
                        # is correct, even though CPAN would not check for
                        # that.  But since the URL has replaced '::' with '-'
                        # there is no way to distinguish between "Foo::Bar"
                        # and "Foo-Bar" as module names from the URL.
                        if %distribution<name> -> $name {

                            # Force auth to CPAN, as that's the only thing
                            # that really makes sense, as CPAN would allow
                            # uploads with just about any auth, and this way
                            # we make sure that modules on CPAN are accredited
                            # correctly and prevent module squatting this way.
                            %distribution<auth> := "cpan:@parts[3]";

                            # Make sure we have a matching identity in the
                            # META information.
                            my $identity :=
                              %distribution<dist> := build(
                                $name,
                                :ver($version),
                                :auth(%distribution<auth>),
                                :api(%distribution<api>)
                              );

                            # Set up META for later confirmation with
                            # actual tar file.
                            %distribution<source-url> :=
                              rea-download-URL $name,$identity,extension($path);
                            %valid{$id} := %distribution;
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
            elsif %valid{$id} -> %distribution {
                my $name     := %distribution<name>;
                my $identity := %distribution<dist>;
                my $json     := self!make-json-io($name, $identity);
                if self!archive-distribution(
                  "$cpan-base-url/authors/$path",
                  self!make-shelf-io($name, $identity, extension($path))
                ) -> $release-date {
                    %distribution<release-date> := $release-date;
                    distribution-to-io(%distribution, $json)
                }
                elsif $force-json {
dd %distribution<source-url>;
                    distribution-to-io(%distribution, $json)
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
        self!update-meta: %valid.values.map: -> %distribution {
            %distribution<dist> => %distribution
        }
    }

    method !update-git($force-json --> Nil) {
        my $resp := await $!http-client.get:
          'https://raw.githubusercontent.com/Raku/ecosystem/master/META.list';
        my $text := await $resp.body;
        self!update-meta: $text.lines
          .race(:$!degree, :$!batch)
          .map: -> $URL {
            my $result := Empty;

            my $resp := {
                CATCH { self.note: "problem with $URL" }
                await $!http-client.get($URL)
            }();
            my $text := await $resp.body;
            with distribution-from-text($text) -> %distribution {
                my $name := %distribution<name>;
                if $name && $name.contains(' ') {
                    self.note: "$URL: invalid name '$name'";
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
                                if %distribution<auth> -> $found {
                                    if $found ne $auth {
                                        self.note: "auth: $name: $found -> $auth";
                                        %distribution<auth> := $auth;
                                    }
                                }

                                # various checks and fixes
                                my $identity := build(
                                  $name,
                                  :ver($version),
                                  :$auth,
                                  :api(%distribution<api>)
                                );
                                if %distribution<dist> -> $dist {
                                    if $dist ne $identity {
                                        self.note: "identity $name: $dist -> $identity";
                                        %distribution<dist> := $identity;
                                    }
                                }
                                else {
                                    %distribution<dist> := $identity;
                                }

                                my $json := self!make-json-io($name, $identity);
                                %distribution<source-url> :=
                                  rea-download-URL $name, $identity, '.tar.gz';
                                if $json.e {
                                    distribution-to-io(%distribution,$json)
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
                                            $name, $identity, '.tar.gz'
                                          )
                                    }) {
                                        distribution-to-io(%distribution,$json);
                                        $result := $identity => %distribution # NEW!
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
    }

    method meta-as-json() {
        $!meta-lock.protect: {
            $!meta-as-json ||= to-json
              %!identities.values.sort( -> %a, %b {
                  my $a := %a<dist>;
                  my $b := %b<dist>;
                  short-name($a) cmp short-name($b)
                    || version($b) cmp version($a)
                    || auth($a) cmp auth($b)
                    || ver($b) cmp ver($a)  # 0.9.0 before 0.9
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
        my %identities := %!identities.clone;
        self!update($force-json);
        Map.new((
          %!identities.grep({ %identities{.key}:!exists })
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

                with try distribution-from-io($json) -> %json {
                    my $name := %json<name>;
                    my $auth := %json<auth>;
                    $auth := "$base:$default-auth"
                      unless $auth && $auth.contains(":");

                    my $identity := build(
                      $name, :ver(%json<version>), :$auth, :api(%json<api>)
                    );

                    unless %!identities{$identity} {
                        my $io := $!jsons.add($name);
                        $io.mkdir;
                        $io := $io.child("$identity.json");

                        if try self!archive-distribution(
                            ::("&$base\-download-URL")($user, $repo, $sha),
                            self!make-shelf-io($name, $identity, '.tar.gz')
                        ) -> $release-date {
                            %json<auth>         := $auth;
                            %json<release-date> := $release-date;
                            distribution-to-io(%json, $io);
                            @added.push: $identity => %json;
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

    method find-identities($name, :$ver, :$auth, :$api, :$include-distros) {

        my sub filter(str @identities) {
            my $auth-needle := $auth ?? ":auth<$auth>" !! "";
            my $api-needle  := $api && $api ne '0' ?? ":api<$api>" !! "";
            my $version;
            my &comp;
            if $ver && $ver ne '*' {
                $version := $ver.Version;
                &comp = $ver.contains("+" | "*")
                  ?? &infix:«>»
                  !! &infix:«==»;
            }

            @identities.grep: {
                (!$auth-needle || .contains($auth-needle))
                  &&
                (!$api-needle || .contains($api-needle))
                  && 
                (!&comp || comp(.&version, $version))
            }
        }

        if $ver || $auth || $api {
            if %!use-targets{$name} -> str @identities {
                filter @identities
            }
            elsif $include-distros &&  %!distro-names{$name} -> str @identities {
                filter @identities
            }
            else {
                ()
            }
        }
        else {
            if %!use-targets{$name} -> str @identities {
                @identities.List
            }
            elsif $include-distros && %!distro-names{$name} -> str @identities {
                @identities.List
            }
            else {
                ()
            }
        }
    }

    method distro-io($identity) {
        my $io := $!shelves
          .add($identity.substr(0,1).uc)
          .add(short-name($identity))
          .add("$identity.tar.gz");
        $io.e ?? $io !! Nil
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

=head2 distro-io

=begin code :lang<raku>

my $identity = $ea.find-identities('eigenstates').head;
say $ea.distro-io($identity);

=end code

Returns an C<IO> object for the given identity, or C<Nil> if it can not be
found.

=head2 distro-names

=begin code :lang<raku>

say "Archive has $ea.distro-names.elems() different distributions, they are:";
.say for $ea.distro-names.keys.sort;

=end code

Returns a C<Map> keyed by distribution name, with a list of identities that
are available of this distribution, as value.

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

Updates the C<.meta> and C<.use-targets> meta-information in a thread-safe
manner.

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

=head2 use-targets

=begin code :lang<raku>

say "Archive has $ea.use-targets.elems() different 'use' targets, they are:";
.say for $ea.use-targets.keys.sort;

=end code

Returns a C<Map> keyed by module name, with a list of identities that
provide that module name, as value.

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
that were not seen before.  Also updates the C<.identities> and C<.use-targets>
information in a thread-safe manner.

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/Ecosystem-Archive-Update .
Comments and Pull Requests are welcome.

=head1 COPYRIGHT AND LICENSE

Copyright 2021, 2022 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
