#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use IO::Async::Loop;
use IO::Async::Test;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

# print is cmd("$path/print") with .proplist/.query spelled for you; the
# body bytes are WWW::MikroTik's, they must reach the wire untouched.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new(
    host => 'router.example', password => 's3cr3t', http => $http
  );
  $loop->add($mt);
  return ( $mt, $http );
}

sub _done { my ( $f ) = @_; wait_for_future($f); return $f }

subtest 'proplist and query together, verbatim vendor example' => sub {
  my $result = [
    { '.id' => '*8', address => '10.155.101.214/24', interface => 'sfp12' },
    { '.id' => '*A', address => '192.168.111.111/32', interface => 'dummy' }
  ];
  my ( $mt, $http ) = _nam( 'POST /rest/ip/address/print' => $result );

  my $f = $mt->print(
    '/ip/address',
    proplist => [ '.id', 'address', 'interface' ],
    query    => [ 'network=192.168.111.111', 'dynamic=true', '#|' ]
  );
  isa_ok $f, 'Future';
  _done($f);

  my $req = $http->requests->[0];
  is $req->method, 'POST', 'POST';
  is $req->uri->as_string, 'https://router.example/rest/ip/address/print', 'URL, no query string';
  is $req->header('Content-Type'), 'application/json', 'Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
  is $req->content,
    '{".proplist":[".id","address","interface"],".query":["network=192.168.111.111","dynamic=true","#|"]}',
    '.proplist and .query in the body, .query order kept';
  is_deeply $f->result, $result, 'decoded records';

  $loop->remove($mt);
};

subtest 'proplist and query forms' => sub {
  my ( $mt, $http ) = _nam( 'POST /rest/interface/print' => [] );

  my @cases = (
    [ 'no arguments',         [],                                         '{}' ],
    [ 'proplist string',      [ proplist => 'name,type' ],                '{".proplist":"name,type"}' ],
    [ 'proplist list',        [ proplist => [ 'name', 'type' ] ],         '{".proplist":["name","type"]}' ],
    [ 'query stack',          [ query => [ 'type=ether', 'type=vlan', '#|' ] ],
      '{".query":["type=ether","type=vlan","#|"]}' ],
    [ 'both undef',           [ proplist => undef, query => undef ],      '{}' ],
    [ 'plain args alongside', [ proplist => 'name', running => 'true' ],  '{".proplist":"name","running":"true"}' ],
    [ 'flag and sorting',
      [ query => [ 'type=ether' ], 'without-paging' => '', proplist => [ 'name' ], detail => '' ],
      '{".proplist":["name"],".query":["type=ether"],"detail":"","without-paging":""}' ]
  );

  for my $case (@cases) {
    my ( $name, $args, $body ) = @$case;
    _done( $mt->print( '/interface', @$args ) );
    is $http->requests->[-1]->content, $body, $name;
    is $http->requests->[-1]->uri->query, undef, $name.': nothing in the URL';
  }

  $loop->remove($mt);
};

subtest '/print is appended to a nested menu path' => sub {
  my ( $mt, $http ) = _nam( 'POST /rest/ip/firewall/nat/print' => [] );
  _done( $mt->print( '/ip/firewall/nat', query => [ 'chain=srcnat' ] ) );
  is $http->requests->[0]->uri->path, '/rest/ip/firewall/nat/print', 'path';
  $loop->remove($mt);
};

done_testing;
