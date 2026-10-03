#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Log::Any::Test;
use Log::Any qw( $log );
use FindBin;
use lib "$FindBin::Bin/lib";

use Future;
use IO::Async::Loop;
use IO::Async::Test;
use JSON::MaybeXS;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

# The log is WWW::MikroTik's: masked debug lines for URL and body, one info
# line per answered request, one error line per failure. The async client
# must produce the same lines, and never write a secret into them.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new(
    host => 'router.example', user => 'admin', password => 's3cr3t', http => $http
  );
  $loop->add($mt);
  return ( $mt, $http );
}

sub _done { my ( $f ) = @_; wait_for_future($f); return $f }

sub _level {
  my ( $level ) = @_;
  return map { $_->{message} } grep { $_->{level} eq $level } @{ $log->msgs };
}

my $json = JSON::MaybeXS->new( utf8 => 1 );

subtest 'body: password masked in the log, real value on the wire' => sub {
  my ( $mt, $http ) = _nam( 'PUT /rest/ppp/secret' => { '.id' => '*1' } );
  $log->clear;

  _done( $mt->add( '/ppp/secret', name => 'alice', password => 'hunter2', service => 'pppoe' ) );

  is $http->requests->[0]->content, '{"name":"alice","password":"hunter2","service":"pppoe"}',
    'wire body carries the real password';
  my $debug = join "\n", _level('debug');
  unlike $debug, qr/hunter2|s3cr3t/, 'neither the value nor the Basic auth password is logged';
  like $debug, qr/^Body: \{"name":"alice","password":"\*\*\*","service":"pppoe"\}$/m, 'masked body line';
  like $debug, qr{^PUT https://router\.example/rest/ppp/secret$}m, 'URL line';

  $loop->remove($mt);
};

subtest 'query string: masked in the log, real value on the wire' => sub {
  my ( $mt, $http ) = _nam( 'GET /rest/ppp/secret' => [] );
  $log->clear;

  _done( $mt->list( '/ppp/secret', password => 'hunter2', name => 'alice' ) );

  is $http->requests->[0]->uri->as_string,
    'https://router.example/rest/ppp/secret?name=alice&password=hunter2', 'wire URL';
  my $debug = join "\n", _level('debug');
  unlike $debug, qr/hunter2/, 'not in the log';
  like $debug, qr{^GET https://router\.example/rest/ppp/secret\?name=alice&password=\*\*\*$}m, 'masked URL';

  $loop->remove($mt);
};

subtest 'every secret-like key is masked, public-key and look-alikes are not' => sub {
  my @masked  = qw( password Password old-password wpa2-pre-shared-key secret token psk key private-key auth-key );
  my @visible = qw( public-key passthrough key-size comment );
  my %data    = ( ( map { ( $_ => 'leak-'.$_ ) } @masked ), ( map { ( $_ => 'shown-'.$_ ) } @visible ) );
  my ( $mt, $http ) = _nam( 'POST /rest/some/command' => [] );
  $log->clear;

  _done( $mt->cmd( '/some/command', %data ) );

  is_deeply $json->decode( $http->requests->[0]->content ), { %data }, 'wire body is unmasked';
  my $debug = join "\n", _level('debug');
  unlike $debug, qr/leak-/, 'no secret in the log';
  like $debug, qr/"\Q$_\E":"\*\*\*"/, $_.' masked' for @masked;
  like $debug, qr/"\Q$_\E":"shown-\Q$_\E"/, $_.' visible' for @visible;

  $loop->remove($mt);
};

subtest 'info line: method, path and status' => sub {
  my ( $mt ) = _nam( 'GET /rest/ppp/secret' => [] );
  $log->clear;

  _done( $mt->list( '/ppp/secret', password => 'hunter2' ) );

  is_deeply [ _level('info') ], [ 'GET /ppp/secret -> 200' ], 'one info line, no query or body';

  $loop->remove($mt);
};

subtest 'error line: the croak message without a location' => sub {
  my ( $mt ) = _nam( 'POST /rest/ping' => { error => 400, message => 'Bad Request', detail => 'Session closed' } );
  $log->clear;

  my $f = _done( $mt->cmd( '/ping', address => '10.155.101.1' ) );

  ok $f->is_failed, 'failed';
  is_deeply [ _level('error') ], [ 'WWW::MikroTik: 400 Bad Request: Session closed' ], 'error line';
  is_deeply [ _level('info') ], [ 'POST /ping -> 400' ], 'and the info line before it';

  $loop->remove($mt);
};

subtest 'a transport failure logs no response line' => sub {
  my ( $mt ) = _nam( 'GET /rest/x' => Future->fail( "Connection refused\n", connect => 'x' ) );
  $log->clear;

  my $f = _done( $mt->get('/x') );

  ok $f->is_failed, 'failed';
  is scalar( () = _level('info') ), 0, 'no info line: nothing answered';
  is scalar( () = _level('error') ), 0, 'no error line either - the failure is the Future\'s';
  like join( "\n", _level('debug') ), qr{^GET https://router\.example/rest/x$}m, 'the request is still logged';

  $loop->remove($mt);
};

done_testing;
