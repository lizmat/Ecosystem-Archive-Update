use Cro::HTTP::Client:ver<0.8.6>;
use JSON::Fast:ver<0.16>;

class Ecosystem::Archive:ver<0.0.1>:auth<zef:lizmat> {
    has $.meta         is built(:bind) = 'meta';
    has $.shelves      is built(:bind) = 'archive';
    has $.http-client  is built(:bind);
    has %!meta;
    has $!meta-lock;

    my constant $zef-base-url  = 'https://360.zef.pm';
    my constant $cpan-base-url = 'http://www.cpan.org';
    my constant @extensions = <.meta .tar.gz .tgz .zip>;

    sub no-extension($string) {
        return $string.chop(.chars) if $string.ends-with($_) for @extensions;
    }
    sub extension($string) {
        @extensions.first: { $string.ends-with($_) }
    }

    method TWEAK(--> Nil) {
        $!meta    := $!meta.IO;
        $!shelves := $!shelves.IO;

        $!http-client := Cro::HTTP::Client.new(
          user-agent => $?CLASS.^name ~ ' ' ~ $?CLASS.^ver,
        ) without $!http-client;

        $!meta-lock := Lock.new;
        self!update-zef;
#        self!update-cpan;
    }

    method !update-meta(@updates) {
        $!meta-lock.protect: {
            for @updates -> $key, $value {
                %!meta{$key} := $value;
            }
        }
    }

    method !update-zef(--> Nil) {
        my $resp := await $!http-client.get('https://360.zef.pm');
        my @updates;
        for await $resp.body -> %distribution {
            my $identity := %distribution<dist>;
            if !$identity.contains(':api<') && %distribution<api> -> $api {
                $identity := $identity ~ ":api<$api>"
                  unless $api eq "0";
            }
            @updates.push: $identity, %distribution;

            my $path := %distribution<path>;
            self.archive(
              "$zef-base-url/$path",
              %distribution<name>,
              $identity,
              extension($path)
            );
        }
        self!update-meta(@updates);
    }

    method !update-cpan(--> Nil) {
        my constant @includes   = @extensions.map: {
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
            my $id   := "@parts[3]:" ~ no-extension(@parts[5]);
            my $json := $!meta.add("$id.json");

            # mention of .meta is always first
            if $path.ends-with('.meta') {
                next if $json.e;  # already done this one

                my $URL  := "$cpan-base-url/authors/$path";
                my $resp := await $!http-client.get($URL);

                my %distribution = error => 'Invalid JSON file in distribution';
                my $text := (await $resp.body).decode;
                %distribution = $_ with try from-json $text;
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

                    self.archive(
                      "$cpan-base-url/authors/$path",
                      $name,
                      $identity,
                      extension($path)
                    );
                }
                $json.spurt: to-json(%distribution, :!pretty);
            }
        }

#        for $!meta.dir(test => *.ends-with(q/.json/)) -> $io {
#            my %distribution := from-json $io.slurp;
#            %
#        }

        my @updates;
        self!update-meta(@updates);
    }

    # Archive a distribution with given parameters, if not available yet
    method archive($URL, $name, $identity, $extension) {
        my $io := $!shelves.add($name);
        $io.mkdir;
        $io := $io.add($identity ~ $extension);

        # don't load if we already have it, it's static
        unless $io.e {
say "archiving $identity";
            my $resp := await $!http-client.get($URL);
            $io.spurt(await $resp.body);
        }
    }
}

#my $ea := Ecosystem::Archive.new;

=begin pod

=head1 NAME

Ecosystem::Archive - Interface to the Raku Ecosystem Archive

=head1 SYNOPSIS

=begin code :lang<raku>

use Ecosystem::Archive;

=end code

=head1 DESCRIPTION

Ecosystem::Archive provides the basic logic to the Raku Programming
Language Ecosystem Archive.

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
