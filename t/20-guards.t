#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# The two failures Net::Async::MikroTik raises itself, before anything is
# sent through a real Net::Async::HTTP. Nothing here opens a connection: both
# requests fail before do_request, and 192.0.2.1 is TEST-NET-1 anyway.

# Pretend IO::Async::SSL is not installed. Net::Async::HTTP only loads it
# while connecting - a failure there would hang every later request instead.
BEGIN {
  unshift @INC, sub {
    die "Can't locate IO/Async/SSL.pm in \@INC (hidden by this test)\n"
      if $_[1] eq 'IO/Async/SSL.pm';
    return;
  };
}

use IO::Async::Loop;
use Net::Async::MikroTik;

plan skip_all => 'IO::Async::SSL is already loaded, cannot hide it' if $INC{'IO/Async/SSL.pm'};

my $loop = IO::Async::Loop->new;

# ->failure on a pending IO::Async::Future runs the loop until it is ready -
# forever, for exactly the hang this file guards against. Read it only once
# the Future is ready, so a regression shows up red instead of hanging.
sub failure_of {
  my ( $f ) = @_;
  return '(still pending)' unless $f->is_ready;
  return '(not failed)'    unless $f->is_failed;
  return scalar $f->failure;
}

subtest 'https without IO::Async::SSL fails at once, every time' => sub {
  my $mt = Net::Async::MikroTik->new( host => '192.0.2.1' );
  $loop->add($mt);

  for my $attempt ( 1, 2 ) {
    my $f = $mt->get('/system/resource');
    ok $f->is_ready, 'attempt '.$attempt.': the Future is ready without running the loop';
    ok $f->is_failed, 'attempt '.$attempt.': and failed';
    like failure_of($f), qr/\ANet::Async::MikroTik: https needs IO::Async::SSL/,
      'attempt '.$attempt.': naming IO::Async::SSL';
  }

  $loop->remove($mt);
};

subtest 'default http outside a loop fails instead of dying' => sub {
  my $mt = Net::Async::MikroTik->new( host => '192.0.2.1', scheme => 'http' );

  my $f;
  ok eval { $f = $mt->get('/system/resource'); 1 }, 'the call does not die';
  ok $f->is_ready && $f->is_failed, 'the Future failed at once';
  like failure_of($f), qr/\ANet::Async::MikroTik: add it to an IO::Async::Loop/, 'saying what is missing';
};

done_testing;
