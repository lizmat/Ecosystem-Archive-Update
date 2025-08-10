use JSON::Fast::Hyper:ver<0.0.10+>:auth<zef:lizmat>;
use paths:ver<10.1+>:auth<zef:lizmat>;
use Rakudo::CORE::META:ver<0.0.12+>:auth<zef:lizmat>;

use Identity::Utils:ver<0.0.28+>:auth<zef:lizmat> <
  api auth build short-name ver version zef-index-url
>;

use SBOM::Raku:ver<0.0.11+>:auth<zef:lizmat> <
  tar-sbom
>;

# Locally stored JSON files are assumed to be correct
my sub meta-from-io(IO::Path:D $io) { from-json $io.slurp, :immutable }

# Store given distribution at given io
my sub meta-to-io(%distribution, IO::Path:D $io) {
    $io.spurt: to-json %distribution, :!pretty, :sorted-keys
}

# very basic URL fetcher
my sub GET(Str:D $url) {
    (run 'curl', '-L', '-k', '-s', '-f', $url, :out).out.slurp || Nil
}
# very basic remote JSON fetcher
my sub meta-from-URL(Str:D $URL) {
    with GET($URL) {
        try from-json $_
    }
}
# very basic file to IO fetcher
my sub URL-to-io(Str:D $url, IO::Path:D $io) {
    (run 'curl', '-L', '-k', '-s', '-f', '--output', $io.absolute, $url, :out)
      .out.slurp || Nil
}

# Parsing JSON from text may get garbage, and may need adaptations
# so don't request an immutable version (as in future runs, it will
# have read from the stored JSON anyway, and thus have an immutable
# version
sub meta-from-text($text) { try from-json $text }

class Ecosystem::Archive::Update {
    has $.shelves      is built(:bind);
    has $.jsons        is built(:bind);
    has $.sboms        is built(:bind);
    has $.degree       is built(:bind);
    has $.batch        is built(:bind);
    has %.identities   is built(False);
    has @!notes;
    has str  $!meta-as-json = "";
    has Lock $!meta-lock;
    has Lock $!note-lock;

    method TWEAK(--> Nil) {
        $!shelves := 'archive'            without $!shelves;
        $!jsons   := 'meta'               without $!jsons;
        $!sboms   := 'sbom'               without $!sboms;
        $!degree  := Kernel.cpu-cores / 2 without $!degree;
        $!batch   := 64                   without $!batch;

        $!shelves := $!shelves.IO;
        $!jsons   := $!jsons.IO;
        $!sboms   := $!sboms.IO;

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

    my constant $zef-base-url  = zef-index-url;
    my constant $cpan-base-url = 'http://www.cpan.org';
    my constant $git-base-url =
      'https://raw.githubusercontent.com/Raku/ecosystem/master/META.list';
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
        'https://' ~ $url.substr(8)
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
#          (start self!update-git($force-json)),
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
        if meta-from-URL($zef-base-url) -> @metas {
            self!update-meta: @metas
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
                my $shelf := self!make-shelf-io:
                  $name, $identity, extension($path);
                if $json.e {
                    if $force-json {
                        %meta<release-date> :=
                          self!distribution2yyyy-mm-dd($shelf);
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
        else {
            die "Failed to get meta from $zef-base-url";
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
                my $text := GET($URL);
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
        my $text := GET $git-base-url;
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

            my $text := GET $URL;
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
                                    if <main master dev>.first(-> $branch {
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
        return Nil if $io.e;

        {
            CATCH {
                self.note: "$URL failed to load";
                return Nil;
            }
            URL-to-io $URL, $io;
        }
        if $io.e {
            with try tar-sbom($io) -> $sbom {
                my $sbom-io :=
                  $!sboms.add($io.subst($io.parent(3) ~ "/") ~ ".cdx.json");
                mkdir $sbom-io.parent;
                $sbom-io.spurt($sbom.JSON);
            }
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

# Set ^ver ^auth ^api correctly
use META::verauthapi:ver<0.0.1+>:auth<zef:lizmat> $?DISTRIBUTION,
  Ecosystem::Archive::Update
;

# vim: expandtab shiftwidth=4
