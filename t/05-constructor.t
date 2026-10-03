#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use IO::Async::Loop;
use IO::Async::Test;
use Net::Async::HTTP;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

# Constructor and configure: the connection attributes are WWW::MikroTik's
# (same defaults, same validation), http is the seam. Nothing here connects.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %args ) = @_;
  my $mt = Net::Async::MikroTik->new( host => 'router.example', %args );
  $loop->add($mt);
  return $mt;
}

sub _mock { Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { @_ } ) }

subtest 'defaults are those of WWW::MikroTik' => sub {
  my $mt   = _nam();
  my $sync = WWW::MikroTik->new( host => 'router.example' );

  is $mt->host, 'router.example', 'host as given';
  is $mt->$_, $sync->$_, $_.' default equals the sync client\'s' for qw(
    user password scheme port verify_ssl timeout base_url
  );
  is $mt->user, 'admin', 'user admin';
  is $mt->password, '', 'empty password';
  is $mt->scheme, 'https', 'https';
  is $mt->port, undef, 'no port';
  is $mt->verify_ssl, 1, 'verifying';
  is $mt->timeout, 60, 'timeout 60';
  is $mt->base_url, 'https://router.example/rest', 'base_url';

  $loop->remove($mt);
};

subtest 'explicit values reach the accessors and the URL' => sub {
  my $http = _mock( 'GET /rest/ip/address' => [] );
  my $mt   = _nam(
    scheme => 'http', port => 8728, user => 'bob', password => 'pw',
    verify_ssl => 0, timeout => 5, http => $http
  );

  is $mt->scheme, 'http', 'scheme';
  is $mt->port, 8728, 'port';
  is $mt->user, 'bob', 'user';
  is $mt->password, 'pw', 'password';
  is $mt->verify_ssl, 0, 'verify_ssl';
  is $mt->timeout, 5, 'timeout';
  is $mt->base_url, 'http://router.example:8728/rest', 'base_url built from scheme and port';

  wait_for_future( $mt->list('/ip/address') );
  my $req = $http->requests->[0];
  is $req->uri->as_string, 'http://router.example:8728/rest/ip/address', 'URL';
  is_deeply [ $req->authorization_basic ], [ 'bob', 'pw' ], 'credentials';

  $loop->remove($mt);
};

subtest 'an explicit base_url wins and prefixes the path' => sub {
  my $http = _mock( 'GET /gw/rest/ip/address' => [] );
  my $mt   = _nam( base_url => 'https://proxy.example:9443/gw/rest', scheme => 'http', http => $http );

  is $mt->base_url, 'https://proxy.example:9443/gw/rest', 'verbatim';
  wait_for_future( $mt->list('/ip/address') );
  is $http->requests->[0]->uri->as_string, 'https://proxy.example:9443/gw/rest/ip/address',
    'requests go there';

  $loop->remove($mt);
};

subtest 'invalid arguments croak at construction' => sub {
  ok !eval { Net::Async::MikroTik->new( user => 'admin' ); 1 }, 'no host';
  like $@, qr/Missing required arguments?: host/, 'WWW::MikroTik\'s message';
  ok !eval { Net::Async::MikroTik->new( host => 'r', scheme => 'ftp' ); 1 }, 'bad scheme';
  ok !eval { Net::Async::MikroTik->new( host => 'r', port => 'eighty' ); 1 }, 'bad port';
  ok !eval { Net::Async::MikroTik->new( host => 'r', timeout => 'soon' ); 1 }, 'bad timeout';
};

subtest 'reconfigure changes the next request, and a failed one changes nothing' => sub {
  my $http = _mock( 'GET /rest/ip/address' => [] );
  my $mt   = _nam( http => $http );

  wait_for_future( $mt->list('/ip/address') );
  $mt->configure( host => 'other.example', password => 'new' );
  is $mt->host, 'other.example', 'accessor follows';
  wait_for_future( $mt->list('/ip/address') );

  is $http->requests->[0]->uri->as_string, 'https://router.example/rest/ip/address', 'before';
  is $http->requests->[1]->uri->as_string, 'https://other.example/rest/ip/address', 'after: new host';
  is_deeply [ $http->requests->[1]->authorization_basic ], [ 'admin', 'new' ], 'new password';
  is $mt->http, $http, 'the injected http survives a connection change';

  ok !eval { $mt->configure( scheme => 'ftp' ); 1 }, 'invalid reconfigure croaks';
  is $mt->scheme, 'https', 'scheme unchanged';
  is $mt->host, 'other.example', 'host unchanged';

  $loop->remove($mt);
};

subtest 'an injected http is used as it is' => sub {
  my $mock = _mock( 'GET /rest/x' => [] );
  my $mt   = _nam( http => $mock, timeout => 5, verify_ssl => 0 );

  is $mt->http, $mock, 'the very same object';
  wait_for_future( $mt->get('/x') );
  is scalar @{ $mock->requests }, 1, 'requests go through it';

  my $real = Net::Async::HTTP->new( timeout => 7, user_agent => 'mine/1' );
  my $mt2  = _nam( http => $real, timeout => 5, verify_ssl => 0 );
  is $mt2->http, $real, 'a Net::Async::HTTP too';
  is $real->{timeout}, 7, 'its timeout is not overwritten';
  is $real->{user_agent}, 'mine/1', 'nor its user_agent';
  is $real->parent, $mt2, 'a parentless notifier is adopted as a child';
  is $real->loop, $loop, 'and so is in the loop';

  $mt2->configure( http => undef );
  is $real->parent, undef, 'configure( http => undef ) releases it';
  isnt $mt2->http, $real, 'and goes back to a default one';

  $loop->remove($mt);
  $loop->remove($mt2);
};

subtest 'http without do_request croaks' => sub {
  ok !eval { Net::Async::MikroTik->new( host => 'r', http => bless( {}, 'Not::A::Transport' ) ); 1 },
    'object without do_request';
  like $@, qr/http must be an object with a do_request method/, 'says so';
  ok !eval { Net::Async::MikroTik->new( host => 'r', http => 'Net::Async::HTTP' ); 1 }, 'a class name';
  ok !eval { Net::Async::MikroTik->new( host => 'r', http => {} ); 1 }, 'a plain hashref';
};

subtest 'default http: Net::Async::HTTP built from the client settings' => sub {
  my $mt   = _nam( timeout => 30, verify_ssl => 0 );
  my $http = $mt->http;

  isa_ok $http, 'Net::Async::HTTP';
  is $http->{user_agent}, 'Net-Async-MikroTik/'.Net::Async::MikroTik->VERSION, 'user_agent';
  is $http->{timeout}, 30, 'timeout';
  is $http->{ssl_params}{SSL_verify_mode}, 0, 'verify_ssl => 0 is SSL_verify_mode 0';
  is $http->{max_redirects}, 0, 'redirects are not followed';
  is $http->parent, $mt, 'a child of the client';
  is $http->loop, $loop, 'in the client\'s loop';
  is $mt->http, $http, 'built once';

  my $verifying = _nam();
  is $verifying->http->{ssl_params}{SSL_verify_mode}, 1, 'verify_ssl on is SSL_verify_mode 1';
  is $verifying->http->{timeout}, 60, 'default timeout 60';

  $loop->remove($_) for $mt, $verifying;
};

subtest 'reconfigure replaces the default http only for timeout and verify_ssl' => sub {
  my $mt   = _nam( timeout => 30 );
  my $http = $mt->http;

  $mt->configure( host => 'other.example', password => 'x', user => 'y' );
  is $mt->http, $http, 'host/user/password keep it';
  $mt->configure( timeout => 30 );
  is $mt->http, $http, 'the same timeout keeps it';

  $mt->configure( timeout => 10 );
  my $second = $mt->http;
  isnt $second, $http, 'a new timeout replaces it';
  is $second->{timeout}, 10, 'carrying the new timeout';
  is $http->parent, undef, 'the old one left the client';
  is $http->loop, undef, 'and the loop';

  $mt->configure( verify_ssl => 0 );
  my $third = $mt->http;
  isnt $third, $second, 'verify_ssl change replaces it';
  is $third->{ssl_params}{SSL_verify_mode}, 0, 'with the new mode';
  $mt->configure( verify_ssl => 1 );
  is $mt->http->{ssl_params}{SSL_verify_mode}, 1, 'and back';

  my $mock = _mock();
  $mt->configure( http => $mock );
  $mt->configure( timeout => 99 );
  is $mt->http, $mock, 'an injected http is never replaced by a timeout change';

  $loop->remove($mt);
};

done_testing;
