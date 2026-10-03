#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Optional, opt-in only: exercises a real router when the maintainer points
# MIKROTIK_TEST_HOST at one. Never set that variable here or widen what this
# file does - read-only calls only, no add/set/remove/cmd that changes state.
# Same variables and the same calls as WWW::MikroTik's t/90-live.t, through
# the loop.

unless ( $ENV{MIKROTIK_TEST_HOST} ) {
  plan skip_all => 'set MIKROTIK_TEST_HOST (and optionally MIKROTIK_TEST_USER / '
    .'MIKROTIK_TEST_PASSWORD / MIKROTIK_TEST_VERIFY_SSL / MIKROTIK_TEST_SCHEME / '
    .'MIKROTIK_TEST_PORT) to run this against a real router';
}

use Future;
use IO::Async::Loop;
use Net::Async::MikroTik;

my $loop = IO::Async::Loop->new;

my $mt = Net::Async::MikroTik->new(
  host       => $ENV{MIKROTIK_TEST_HOST},
  user       => $ENV{MIKROTIK_TEST_USER} // 'admin',
  password   => $ENV{MIKROTIK_TEST_PASSWORD} // '',
  verify_ssl => $ENV{MIKROTIK_TEST_VERIFY_SSL} // 0,
  ( $ENV{MIKROTIK_TEST_SCHEME} ? ( scheme => $ENV{MIKROTIK_TEST_SCHEME} ) : () ),
  ( $ENV{MIKROTIK_TEST_PORT}   ? ( port   => $ENV{MIKROTIK_TEST_PORT} )   : () ),
);
$loop->add($mt);

subtest 'system resource print' => sub {
  my ( $resource ) = @{ $mt->cmd('/system/resource/print')->get };
  ok $resource, 'got a resource record';
  ok exists $resource->{version}, 'record has a version field';
  ok exists $resource->{'cpu-count'}, 'record has a cpu-count field';
};

subtest 'ip address list' => sub {
  my $addresses = $mt->get('/ip/address')->get;
  is ref $addresses, 'ARRAY', 'listing addresses returns an arrayref';
};

subtest 'ip address list with an arrayref .proplist' => sub {
  my @wanted    = qw( address interface );
  my $addresses = $mt->get('/ip/address', '.proplist' => [ @wanted ])->get;
  is ref $addresses, 'ARRAY', 'a GET with a comma-joined query value returns an arrayref';
  my %wanted = map { ( $_ => 1 ) } @wanted;
  # .id is tolerated: unsure whether RouterOS returns it regardless of .proplist
  my @extra  = grep { !$wanted{$_} && $_ ne '.id' } map { keys %$_ } @$addresses;
  is_deeply [ sort @extra ], [], 'records carry only the requested keys';
};

subtest 'ip address filter with a slash in the value' => sub {
  my $addresses = $mt->get('/ip/address')->get;
  my ( $known ) = grep { defined && m{/} } map { $_->{address} } @$addresses;
  plan skip_all => 'router reports no address with a prefix length' unless $known;
  my $found = $mt->get('/ip/address', address => $known)->get;
  is ref $found, 'ARRAY', 'a GET with a slash in a query value returns an arrayref';
  ok scalar @$found, 'the filter matches at least one record';
  is_deeply [ grep { $_->{address} ne $known } @$found ], [], 'and only records with that address';
};

subtest 'parallel requests on one loop' => sub {
  my ( $resource, $addresses ) = Future->needs_all(
    $mt->cmd('/system/resource/print'),
    $mt->get('/ip/address'),
  )->get;
  is ref $resource, 'ARRAY', 'resource print resolved';
  is ref $addresses, 'ARRAY', 'address list resolved';
};

done_testing;
