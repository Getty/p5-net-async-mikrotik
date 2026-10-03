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

# Several requests in flight on one client: each Future resolves from its own
# response, in any order, and cancelling or dropping one leaves the others
# alone. The routes hand out pending Futures that the test settles by hand.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _json_response {
  my ( $body ) = @_;
  my $res = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], $body );
  return $res;
}

subtest 'two requests resolve independently, in either order' => sub {
  for my $order ( [ qw( address interface ) ], [ qw( interface address ) ] ) {
    my %wire;
    my ( $mt, $http ) = _nam_with( \%wire );

    my $addr = $mt->list('/ip/address');
    my $ifs  = $mt->list('/interface');
    is scalar @{ $http->requests }, 2, 'both requests are out before either is answered';
    ok !$addr->is_ready && !$ifs->is_ready, 'both pending';

    my %body = (
      address   => '[{".id":"*1","address":"10.0.0.1/24"}]',
      interface => '[{".id":"*2","name":"ether1"}]'
    );
    my ( $first, $second ) = @$order;
    my %future = ( address => $addr, interface => $ifs );

    $wire{$first}->done( _json_response( $body{$first} ) );
    ok $future{$first}->is_done, $order->[0].' answered first: done';
    ok !$future{$second}->is_ready, 'the other still pending';

    $wire{$second}->done( _json_response( $body{$second} ) );
    ok $future{$second}->is_done, 'then the second';

    is_deeply $addr->result, [ { '.id' => '*1', address => '10.0.0.1/24' } ],
      'address result is its own response ('.join( ',', @$order ).')';
    is_deeply $ifs->result, [ { '.id' => '*2', name => 'ether1' } ], 'interface result is its own response';

    $loop->remove($mt);
  }
};

subtest 'a failure of one does not touch the other' => sub {
  my %wire;
  my ( $mt ) = _nam_with( \%wire );

  my $ok  = $mt->list('/ip/address');
  my $bad = $mt->list('/interface');

  $wire{interface}->done( HTTP::Response->new( 404, 'Not Found', [ 'Content-Type' => 'application/json' ],
    '{"error":404,"message":"Not Found"}' ) );
  ok $bad->is_failed, 'one failed';
  ok !$ok->is_ready, 'the other is still pending';
  $wire{address}->done( _json_response('[]') );
  ok $ok->is_done, 'and succeeds';
  like scalar $bad->failure, qr/\AWWW::MikroTik: 404 Not Found at /, 'with its own error';

  my $net = $mt->list('/ip/address');
  my $fine = $mt->list('/interface');
  $wire{address}->fail( "Connection reset\n", connect => 'x' );
  ok $net->is_failed, 'a transport failure fails only its request';
  ok !$fine->is_ready, 'sibling pending';
  $wire{interface}->done( _json_response('[]') );
  ok $fine->is_done, 'sibling done';

  $loop->remove($mt);
};

subtest 'cancelling one request leaves the other alone' => sub {
  my %wire;
  my ( $mt ) = _nam_with( \%wire );

  my $doomed = $mt->list('/ip/address');
  my $kept   = $mt->list('/interface');

  $doomed->cancel;
  ok $doomed->is_cancelled, 'cancelled';
  ok $wire{address}->is_cancelled, 'the transport Future was cancelled with it';
  ok !$kept->is_ready, 'the other is untouched';

  $wire{interface}->done( _json_response('[{"name":"ether1"}]') );
  ok $kept->is_done, 'it still completes';
  is_deeply $kept->result, [ { name => 'ether1' } ], 'with its own data';

  # a late answer for the cancelled one must not blow up anything
  ok eval { $wire{address}->done( _json_response(q([])) ); 1 }, 'a late answer is harmless';

  # the client is still usable
  my $again = $mt->list('/ip/address');
  $wire{address}->done( _json_response('[{"address":"10.0.0.2/24"}]') );
  ok $again->is_done, 'a later request works';

  $loop->remove($mt);
};

subtest 'dropping one pending Future leaves the other alone' => sub {
  my %wire;
  my ( $mt ) = _nam_with( \%wire );

  my $kept = $mt->list('/interface');
  {
    my $dropped = $mt->list('/ip/address');
    ok !$dropped->is_ready, 'pending';
  }

  $wire{interface}->done( _json_response('[{"name":"ether1"}]') );
  ok $kept->is_done, 'the other completes';
  is_deeply $kept->result, [ { name => 'ether1' } ], 'with its own data';

  $loop->remove($mt);
};

subtest 'the same request twice in flight resolves twice' => sub {
  my ( $mt, $http ) = do {
    my $n = 0;
    my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => {
      'GET /rest/system/resource' => sub { _json_response( '{"n":"'.( ++$n ).'"}' ) }
    } );
    my $mt = Net::Async::MikroTik->new( host => 'router.example', http => $http );
    $loop->add($mt);
    ( $mt, $http );
  };

  my @f = map { $mt->get('/system/resource') } 1 .. 3;
  wait_for_future($_) for @f;

  is_deeply [ map { $_->result->{n} } @f ], [ 1, 2, 3 ], 'each Future got its own response';
  is scalar @{ $http->requests }, 3, 'three requests';

  $loop->remove($mt);
};

subtest 'needs_all over a deferred mock gathers independent answers' => sub {
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => {
    'POST /rest/system/resource/print' => [ { 'cpu-count' => '16' } ],
    'POST /rest/interface/print'       => [ { name => 'ether1' } ]
  } );
  my $mt = Net::Async::MikroTik->new( host => 'router.example', http => $http );
  $loop->add($mt);

  my $all = Future->needs_all(
    $mt->cmd('/system/resource/print'),
    $mt->print( '/interface', proplist => 'name' )
  );
  wait_for_future($all);

  is_deeply [ $all->result ], [ [ { 'cpu-count' => '16' } ], [ { name => 'ether1' } ] ],
    'both results, in call order';

  $loop->remove($mt);
};

# Routes that park every request on a pending Future stored in %$wire.
sub _nam_with {
  my ( $wire ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( routes => {
    'GET /rest/ip/address' => sub { $wire->{address}   = Future->new },
    'GET /rest/interface'  => sub { $wire->{interface} = Future->new }
  } );
  my $mt = Net::Async::MikroTik->new( host => 'router.example', http => $http );
  $loop->add($mt);
  return ( $mt, $http );
}

done_testing;
