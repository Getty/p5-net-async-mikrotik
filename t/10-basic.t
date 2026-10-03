#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use Future;
use HTTP::Response;
use IO::Async::Loop;
use IO::Async::Test;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

my $loop = IO::Async::Loop->new;
testing_loop($loop);

# A client on a mock transport that answers from a zero-delay timer, so every
# Future below is still pending when the method returns.
sub mock_client {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new(
    host     => '192.168.88.1',
    password => 'secret',
    http     => $http,
  );
  $loop->add($mt);
  return ( $mt, $http );
}

subtest 'GET through the loop: wire and result' => sub {
  my @records = ( { '.id' => '*1', address => '10.0.0.1/24', interface => 'ether2', disabled => 'false' } );
  my ( $mt, $http ) = mock_client( 'GET /rest/ip/address' => [ @records ] );

  my $f = $mt->list('/ip/address', interface => 'ether2');
  isa_ok $f, 'Future';
  ok !$f->is_ready, 'the Future is pending until the loop delivers the response';

  wait_for_future($f);
  ok $f->is_done, 'and done after it';
  is_deeply [ $f->result ], [ [ @records ] ], 'resolves to the decoded records, strings left as strings';

  is scalar @{ $http->requests }, 1, 'one request went out';
  my $req = $http->requests->[0];
  is $req->method, 'GET', 'method';
  is $req->uri->as_string, 'https://192.168.88.1/rest/ip/address?interface=ether2', 'URL with the filter as query';
  is_deeply [ $req->authorization_basic ], [ 'admin', 'secret' ], 'Basic auth with the default user';
  is $req->header('Content-Type'), undef, 'no Content-Type without a body';
  is $req->content, '', 'no body';

  $loop->remove($mt);
};

subtest 'router error fails the Future with WWW::MikroTik\'s message' => sub {
  my ( $mt, $http ) = mock_client(
    'GET /rest/ip/address/*9' => { error => 404, message => 'Not Found' },
  );

  my $f;
  ok eval { $f = $mt->get('/ip/address/*9'); 1 }, 'the call itself does not die';
  wait_for_future($f);
  ok $f->is_failed, 'the Future failed';
  like scalar $f->failure, qr/\AWWW::MikroTik: 404 Not Found/, 'with the sync client\'s croak text';

  $loop->remove($mt);
};

subtest 'empty body resolves with no value' => sub {
  my ( $mt, $http ) = mock_client( 'DELETE /rest/ip/address/*1' => HTTP::Response->new(200) );

  my $f = $mt->remove('/ip/address', '*1');
  wait_for_future($f);
  ok $f->is_done, 'done';
  is_deeply [ $f->result ], [], 'no values at all';
  is $f->get, undef, '->get in scalar context is undef, like the sync client';
  is $http->requests->[0]->uri->path, '/rest/ip/address/*1', 'the .id went out unencoded';

  $loop->remove($mt);
};

subtest 'transport failure passes through unchanged' => sub {
  my ( $mt, $http ) = mock_client(
    'GET /rest/system/resource' => Future->fail("Connection refused\n", connect => 'details'),
  );

  my $f = $mt->get('/system/resource');
  wait_for_future($f);
  ok $f->is_failed, 'failed';
  is_deeply [ $f->failure ], [ "Connection refused\n", connect => 'details' ],
    'message, category and details as the transport reported them';

  $loop->remove($mt);
};

subtest 'construction validates through WWW::MikroTik' => sub {
  ok !eval { Net::Async::MikroTik->new( user => 'admin' ); 1 }, 'no host croaks at construction';
  like $@, qr/host/, 'naming the missing host';
};

subtest 'default http' => sub {
  my $mt = Net::Async::MikroTik->new( host => '192.168.88.1', verify_ssl => 0, timeout => 30 );
  $loop->add($mt);

  my $http = $mt->http;
  isa_ok $http, 'Net::Async::HTTP';
  is $http->{user_agent}, 'Net-Async-MikroTik/'.Net::Async::MikroTik->VERSION, 'user_agent';
  is $http->{timeout}, 30, 'timeout from the client';
  is $http->{ssl_params}{SSL_verify_mode}, 0, 'verify_ssl => 0 is SSL_verify_mode 0';
  is $http->parent, $mt, 'a child of the client';
  is $http->loop, $loop, 'in the loop the client was added to';
  is $mt->http, $http, 'built once';

  $mt->configure( timeout => 30 );
  is $mt->http, $http, 'reconfiguring to the same timeout keeps it';
  $mt->configure( timeout => 10 );
  isnt $mt->http, $http, 'a different timeout replaces it';
  is $http->parent, undef, 'the old one is no longer a child';
  is $mt->http->{timeout}, 10, 'the new one has the new timeout';

  my $verifying = Net::Async::MikroTik->new( host => '192.168.88.1' );
  is $verifying->http->{ssl_params}{SSL_verify_mode}, 1, 'verify_ssl defaults to SSL_verify_mode 1';

  $loop->remove($mt);
};

done_testing;
