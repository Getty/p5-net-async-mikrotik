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

# What a response becomes: a Future done with the decoded JSON (or with no
# value), or a Future failed with WWW::MikroTik's croak text. Fixtures are the
# vendor shapes also used by WWW::MikroTik's own suite.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new( host => 'router.example', password => 's3cr3t', http => $http );
  $loop->add($mt);
  return $mt;
}

# Runs the Future to completion; a call that dies fails the test, not the file.
sub _await {
  my ( $mt, $verb, @args ) = @_;
  my $f;
  my $lived = eval { $f = $mt->$verb(@args); 1 };
  ok $lived, $verb.' does not die synchronously' or return;
  isa_ok $f, 'Future';
  wait_for_future($f);
  return $f;
}

subtest 'a list response resolves to the arrayref, values stay strings' => sub {
  my $addresses = [
    { '.id' => '*1', address => '10.0.0.111/24', disabled => 'false', interface => 'ether2' },
    { '.id' => '*2', address => '10.0.0.109/24', disabled => 'true', interface => 'ether3' }
  ];
  my $mt = _nam( 'GET /rest/ip/address' => $addresses );

  my $f = _await( $mt, 'get', '/ip/address' );
  is_deeply $f->result, $addresses, 'decoded verbatim';
  is $f->result->[0]{disabled}, 'false', 'the string "false", not a JSON boolean';

  $loop->remove($mt);
};

subtest 'a single record resolves to a hashref, an empty array is a value' => sub {
  my $address = { '.id' => '*1', address => '10.0.0.111/24', disabled => 'false' };
  my $mt = _nam(
    'GET /rest/ip/address/*1' => $address,
    'POST /rest/some/command' => [],
    'POST /rest/execute'      => { ret => '*5' }
  );

  is_deeply _await( $mt, 'get', '/ip/address/*1' )->result, $address, 'object';
  my $f = _await( $mt, 'cmd', '/some/command' );
  is_deeply [ $f->result ], [ [] ], 'the empty arrayref is one value';
  is_deeply _await( $mt, 'cmd', '/execute', script => '/log/info test' )->result, { ret => '*5' },
    '!done data is an object';

  $loop->remove($mt);
};

subtest 'an empty body resolves with no value at all' => sub {
  my $mt = _nam(
    'DELETE /rest/ip/address/*9' => HTTP::Response->new(200),
    'GET /rest/x'                => HTTP::Response->new( 204, 'No Content' )
  );

  for my $case (
    [ 'remove', 'remove', '/ip/address', '*9' ],
    [ 'delete', 'delete', '/ip/address/*9' ],
    [ '204',    'get',    '/x' ]
  ) {
    my ( $name, $verb, @args ) = @$case;
    my $f = _await( $mt, $verb, @args );
    ok $f->is_done, $name.': done';
    is_deeply [ $f->result ], [], $name.': the empty list, not (undef)';
    my @list = $f->get;
    is scalar @list, 0, $name.': ->get in list context is ()';
    is scalar $f->get, undef, $name.': ->get in scalar context is undef';
  }

  $loop->remove($mt);
};

subtest 'a 2xx that is not JSON fails with the module prefix' => sub {
  my $html = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'text/html' ],
    '<html><body>captive portal</body></html>' );
  my $mt = _nam( 'GET /rest/ip/address' => $html );

  my $f = _await( $mt, 'get', '/ip/address' );
  ok $f->is_failed, 'failed';
  like scalar $f->failure, qr/\AWWW::MikroTik: 200 OK: response body is not JSON: \S/, 'message';

  $loop->remove($mt);
};

my @errors = (
  [ 400, 'Bad Request',           undef ],
  [ 400, 'Bad Request',           'Session closed' ],
  [ 401, 'Unauthorized',          undef ],
  [ 404, 'Not Found',             undef ],
  [ 406, 'Not Acceptable',        'no such command or directory (remove)' ],
  [ 500, 'Internal Server Error', undef ],
  [ 500, 'Internal Server Error', 'something broke' ]
);

for my $case (@errors) {
  my ( $code, $message, $detail ) = @$case;
  my $name = $code.' '.$message.( defined $detail ? ' with detail' : ' without detail' );

  subtest 'error: '.$name => sub {
    my $body = { error => $code, message => $message, defined $detail ? ( detail => $detail ) : () };
    my $mt   = _nam( 'POST /rest/ping' => $body );

    my $f    = _await( $mt, 'cmd', '/ping', address => '10.155.101.1' );
    my $want = 'WWW::MikroTik: '.$code.' '.$message.( defined $detail ? ': '.$detail : '' );
    ok $f->is_failed, 'failed';
    is scalar( () = $f->failure ), 1, 'a plain message, no category';
    like scalar $f->failure, qr/\A\Q$want\E at /, 'exactly status, message and optional detail';
    unlike scalar $f->failure, qr/\Q$want\E:/, 'nothing appended after the detail' unless defined $detail;

    $loop->remove($mt);
  };
}

subtest 'the status comes from the HTTP line; errors without a JSON message give the status line' => sub {
  my $mt = _nam(
    'GET /rest/a' => HTTP::Response->new( 404, 'Not Found', [ 'Content-Type' => 'application/json' ],
      '{"error":500,"message":"Not Found"}' ),
    'GET /rest/b' => HTTP::Response->new( 502, 'Bad Gateway', [ 'Content-Type' => 'text/html' ],
      '<html><body><h1>502 Bad Gateway</h1></body></html>' ),
    'GET /rest/c' => HTTP::Response->new( 503, 'Service Unavailable' )
  );

  like scalar _await( $mt, 'get', '/a' )->failure, qr/\AWWW::MikroTik: 404 Not Found at /, 'HTTP status wins';
  my $f = _await( $mt, 'get', '/b' );
  like scalar $f->failure, qr/\AWWW::MikroTik: 502 Bad Gateway at /, 'non-JSON error body';
  unlike scalar $f->failure, qr/<html>/, 'the body stays out of the message';
  like scalar _await( $mt, 'get', '/c' )->failure, qr/\AWWW::MikroTik: 503 Service Unavailable at /,
    'empty error body';

  $loop->remove($mt);
};

subtest 'transport failure passes through unchanged' => sub {
  my $mt = _nam(
    'GET /rest/system/resource' => Future->fail( "Connection refused\n", connect => 'details', 'more' ),
    'GET /rest/slow'            => Future->fail( 'Timed out while waiting for response', timeout => 'x' )
  );

  my $f = _await( $mt, 'get', '/system/resource' );
  ok $f->is_failed, 'failed';
  is_deeply [ $f->failure ], [ "Connection refused\n", connect => 'details', 'more' ],
    'message, category and details exactly as the transport gave them';
  unlike scalar $f->failure, qr/WWW::MikroTik/, 'no WWW::MikroTik wrapping';

  $f = _await( $mt, 'get', '/slow' );
  is_deeply [ $f->failure ], [ 'Timed out while waiting for response', timeout => 'x' ], 'a timeout too';

  $loop->remove($mt);
};

subtest 'a transport that dies fails the Future, never the caller' => sub {
  my $mt = _nam( 'GET /rest/boom' => sub { die "transport blew up\n" } );

  my $f = _await( $mt, 'get', '/boom' );
  ok $f->is_failed, 'failed';
  is scalar $f->failure, "transport blew up\n", 'the exception unchanged';

  $loop->remove($mt);
};

subtest 'an unknown route does not throw either' => sub {
  my $mt = _nam( 'GET /rest/known' => [] );

  my $f = _await( $mt, 'get', '/nowhere' );
  ok $f->is_failed, 'failed';
  like scalar $f->failure, qr/no mock route for 'GET \/rest\/nowhere'/, 'with the mock\'s message';

  for my $verb (qw( list remove cmd print add set )) {
    my @args = $verb eq 'set' ? ( '/nowhere', '*1' ) : $verb eq 'remove' ? ( '/nowhere', '*1' ) : ('/nowhere');
    my $g;
    ok eval { $g = $mt->$verb(@args); 1 }, $verb.' returned a Future' or next;
    wait_for_future($g);
    ok $g->is_failed, $verb.' failed instead of dying';
  }

  $loop->remove($mt);
};

subtest 'status 299 is success, 400 is an error' => sub {
  my $mt = _nam(
    'GET /rest/ok'  => HTTP::Response->new( 299, 'Odd', [], '{"a":"1"}' ),
    'GET /rest/bad' => HTTP::Response->new( 400, 'Bad Request', [], '' )
  );

  is_deeply _await( $mt, 'get', '/ok' )->result, { a => '1' }, 'decodes';
  like scalar _await( $mt, 'get', '/bad' )->failure, qr/\AWWW::MikroTik: 400 Bad Request at /, 'fails';

  $loop->remove($mt);
};

done_testing;
