#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use HTTP::Response;
use IO::Async::Loop;
use IO::Async::Test;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

# Every verb: a Future, and on the wire exactly what WWW::MikroTik's verb
# sends. The mock answers from a loop timer, so each Future is pending when
# the call returns.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new(
    host     => 'router.example',
    user     => 'admin',
    password => 's3cr3t',
    http     => $http
  );
  $loop->add($mt);
  return ( $mt, $http );
}

my $base = 'https://router.example/rest';

my $address = {
  '.id' => '*A', 'actual-interface' => 'dummy', address => '192.168.111.111/32',
  disabled => 'false', dynamic => 'false', interface => 'dummy', invalid => 'false',
  network => '192.168.111.111'
};
my $addresses = [
  { '.id' => '*2', 'actual-interface' => 'ether3', address => '10.0.0.109/24',
    disabled => 'true', interface => 'ether3' }
];

# [ name, route, response, code, method, url, body, expected result (list) ]
my @cases = (
  [ 'request', 'GET /rest/interface/ether1', { '.id' => '*1', name => 'ether1' },
    sub { $_[0]->request( 'GET', '/interface/ether1', undef ) },
    'GET', $base.'/interface/ether1', undef, [ { '.id' => '*1', name => 'ether1' } ] ],
  [ 'get', 'GET /rest/ip/address', $addresses,
    sub { $_[0]->get( '/ip/address', network => '10.155.101.0', dynamic => 'true' ) },
    'GET', $base.'/ip/address?dynamic=true&network=10.155.101.0', undef, [ $addresses ] ],
  [ 'get by .id', 'GET /rest/ip/address/*1A', $address,
    sub { $_[0]->get('/ip/address/*1A') },
    'GET', $base.'/ip/address/*1A', undef, [ $address ] ],
  [ 'list', 'GET /rest/ip/address', $addresses,
    sub { $_[0]->list( '/ip/address', interface => 'ether3' ) },
    'GET', $base.'/ip/address?interface=ether3', undef, [ $addresses ] ],
  [ 'put', 'PUT /rest/ip/address', $address,
    sub { $_[0]->put( '/ip/address', { interface => 'dummy', address => '192.168.111.111' } ) },
    'PUT', $base.'/ip/address', '{"address":"192.168.111.111","interface":"dummy"}', [ $address ] ],
  [ 'add', 'PUT /rest/ip/address', $address,
    sub { $_[0]->add( '/ip/address', address => '192.168.111.111', interface => 'dummy' ) },
    'PUT', $base.'/ip/address', '{"address":"192.168.111.111","interface":"dummy"}', [ $address ] ],
  [ 'patch', 'PATCH /rest/ip/address/*3', { %$address, '.id' => '*3', comment => 'test' },
    sub { $_[0]->patch( '/ip/address/*3', { comment => 'test' } ) },
    'PATCH', $base.'/ip/address/*3', '{"comment":"test"}', [ { %$address, '.id' => '*3', comment => 'test' } ] ],
  [ 'set', 'PATCH /rest/ip/address/*3', { %$address, '.id' => '*3', comment => 'test' },
    sub { $_[0]->set( '/ip/address', '*3', comment => 'test' ) },
    'PATCH', $base.'/ip/address/*3', '{"comment":"test"}', [ { %$address, '.id' => '*3', comment => 'test' } ] ],
  [ 'delete', 'DELETE /rest/ip/address/*9', HTTP::Response->new(200),
    sub { $_[0]->delete('/ip/address/*9') },
    'DELETE', $base.'/ip/address/*9', undef, [] ],
  [ 'remove', 'DELETE /rest/ip/address/*9', HTTP::Response->new(200),
    sub { $_[0]->remove( '/ip/address', '*9' ) },
    'DELETE', $base.'/ip/address/*9', undef, [] ],
  [ 'post', 'POST /rest/ping', [ { host => '10.155.101.1', received => '1', sent => '1' } ],
    sub { $_[0]->post( '/ping', { count => '4', address => '10.155.101.1' } ) },
    'POST', $base.'/ping', '{"address":"10.155.101.1","count":"4"}',
    [ [ { host => '10.155.101.1', received => '1', sent => '1' } ] ] ],
  [ 'cmd', 'POST /rest/ping', [ { host => '10.155.101.1', received => '1', sent => '1' } ],
    sub { $_[0]->cmd( '/ping', address => '10.155.101.1', count => '4' ) },
    'POST', $base.'/ping', '{"address":"10.155.101.1","count":"4"}',
    [ [ { host => '10.155.101.1', received => '1', sent => '1' } ] ] ],
  [ 'cmd without args', 'POST /rest/system/resource/print', [ { 'cpu-count' => '16' } ],
    sub { $_[0]->cmd('/system/resource/print') },
    'POST', $base.'/system/resource/print', '{}', [ [ { 'cpu-count' => '16' } ] ] ],
  [ 'print', 'POST /rest/interface/print', [ { name => 'ether1', type => 'ether' } ],
    sub { $_[0]->print('/interface') },
    'POST', $base.'/interface/print', '{}', [ [ { name => 'ether1', type => 'ether' } ] ] ]
);

for my $case (@cases) {
  my ( $name, $route, $response, $call, $method, $url, $body, $want ) = @$case;

  subtest $name.' -> '.$method.' '.$url => sub {
    my ( $mt, $http ) = _nam( $route => $response );

    my $f = $call->($mt);
    isa_ok $f, 'Future';
    ok !$f->is_ready, 'pending until the loop delivers the response';
    wait_for_future($f);
    ok $f->is_done, 'done';
    is_deeply [ $f->result ], $want, 'resolves to what the sync verb returns';

    is scalar @{ $http->requests }, 1, 'one request';
    my $req = $http->requests->[0];
    is $req->method, $method, 'method';
    is $req->uri->as_string, $url, 'URL';
    is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth of admin:s3cr3t';
    if ( defined $body ) {
      is $req->header('Content-Type'), 'application/json', 'Content-Type with a body';
      is $req->content, $body, 'canonical JSON body bytes';
    }
    else {
      is $req->header('Content-Type'), undef, 'no Content-Type without a body';
      is $req->content, '', 'no body';
    }

    $loop->remove($mt);
  };
}

subtest 'the same verbs through an immediately-done mock' => sub {
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( routes => {
    'GET /rest/ip/address'     => $addresses,
    'PUT /rest/ip/address'     => $address,
    'DELETE /rest/ip/address/*9' => HTTP::Response->new(200)
  } );
  my $mt = Net::Async::MikroTik->new( host => 'router.example', http => $http );
  $loop->add($mt);

  my $f = $mt->list('/ip/address');
  ok $f->is_done, 'done without running the loop';
  is_deeply $f->result, $addresses, 'list';
  is_deeply $mt->add( '/ip/address', address => '192.168.111.111' )->result, $address, 'add';
  is_deeply [ $mt->remove( '/ip/address', '*9' )->result ], [], 'remove';

  $loop->remove($mt);
};

done_testing;
