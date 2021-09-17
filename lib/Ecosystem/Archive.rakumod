use Cro::HTTP::Client:ver<0.8.6>;

sub elide-ecosystem($identity) {
    if $identity.contains(':auth<zef:') {
        'zef'
    }
    elsif $identity.contains(':auth<cpan:') {
        'cpan'
    }
    else {
        'p6c'
    }
}

class Ecosystem::Archive:ver<0.0.1>:auth<zef:lizmat> {
    has $.http-client  is built(:bind);
    has $.zef-base-url is built(:bind) = 'https://360.zef.pm';
    has %.zef;
    has $!zef-lock;

    method TWEAK(--> Nil) {
        $!http-client := Cro::HTTP::Client.new(
          user-agent => $?CLASS.^name ~ ' ' ~ $?CLASS.^ver,
        ) without $!http-client;

        $!zef-lock := Lock.new;
        self!update-zef-json unless %!zef;
    }

    method !update-zef-json() {
        my $resp := await $!http-client.get($!zef-base-url);
        my %zef;
        for await $resp.body -> %distribution {
            %zef{%distribution<dist>} := %distribution;
        }
        $!zef-lock.protect: { %!zef := %zef }
    }

    method download-URL(
      $identity, $ecosystem = elide-ecosystem($identity)
    ) {
        if $ecosystem eq 'zef' {
            with %!zef{$identity} -> %distribution {
                "$!zef-base-url/%distribution<path>"
            }
            else {
                Nil
            }
        }
        else {
            Nil
        }
    }
}

my $ea := Ecosystem::Archive.new;
my $identity = 'silently:ver<0.0.4>:auth<zef:lizmat>';
#say $identity;
#say $ea.download-URL($identity);

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
