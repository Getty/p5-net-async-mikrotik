#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use Encode qw( decode );
use HTTP::Response;
use IO::Async::Loop;
use IO::Async::Test;
use JSON::MaybeXS;
use Net::Async::MikroTik;
use Test::Net::Async::MikroTik::MockHTTP;

# Path segments, query values and body bytes must be the ones the sync client
# sends - the escaping lives in WWW::MikroTik, this guards that nothing in the
# async layer re-encodes or loses them on the way through do_request.

my $loop = IO::Async::Loop->new;
testing_loop($loop);

sub _nam {
  my ( %routes ) = @_;
  my $http = Test::Net::Async::MikroTik::MockHTTP->new( loop => $loop, routes => { %routes } );
  my $mt   = Net::Async::MikroTik->new( host => 'router.example', http => $http );
  $loop->add($mt);
  return ( $mt, $http );
}

# Wait for the Future, return it.
sub _done { my ( $f ) = @_; wait_for_future($f); return $f }

my $base = 'https://router.example/rest';

# RouterOS 7.18.2 decodes no percent-escapes in the REST path, so WWW::MikroTik
# refuses a record name that has to be escaped before anything is sent. The
# refusal reaches the caller as a failed Future, never as a die.

subtest 'set/remove: an addressable id goes out as it is, * stays literal' => sub {
  my @addressable = (
    [ 'star id',   '*1A' ],
    [ 'plain',     'vlan1' ],
    [ 'dash',      'my-bridge' ],
    [ 'dot',       'ether0.1' ],
    [ 'underscore', 'a_b' ],
    [ 'tilde',     'a~b' ],
    [ 'digits',    '123' ]
  );
  for my $case (@addressable) {
    my ( $name, $id ) = @$case;
    my ( $mt, $http ) = _nam(
      'PATCH /rest/interface/'.$id  => { name => 'x' },
      'DELETE /rest/interface/'.$id => HTTP::Response->new(200)
    );

    ok _done( $mt->set( '/interface', $id, comment => 'x' ) )->is_done, $name.': set hit the route';
    ok _done( $mt->remove( '/interface', $id ) )->is_done, $name.': remove hit the route';

    for my $req ( @{ $http->requests } ) {
      is $req->uri->as_string, $base.'/interface/'.$id, $name.': '.$req->method.' URL';
      is $req->uri->query, undef, $name.': no query string from the id';
      is $req->uri->fragment, undef, $name.': no fragment from the id';
    }
    $loop->remove($mt);
  }
};

subtest 'set/remove: a name that has to be escaped fails the Future, nothing is sent' => sub {
  my @reserved = (
    [ 'hash',           'vlan#1' ],
    [ 'question mark',  'a?b' ],
    [ 'percent',        '50%off' ],
    [ 'space',          'my bridge' ],
    [ 'slash',          'a/b' ],
    [ 'star with hash', '*1#A' ]
  );
  for my $case (@reserved) {
    my ( $name, $id ) = @$case;
    my ( $mt, $http ) = _nam(
      'PATCH /rest/interface/x'  => { name => 'x' },
      'DELETE /rest/interface/x' => HTTP::Response->new(200)
    );

    for my $verb ( [ set => 'comment', 'x' ], [ remove => ] ) {
      my ( $method, @args ) = @$verb;
      my $f;
      ok eval { $f = $mt->$method( '/interface', $id, @args ); 1 }, $name.': '.$method.' does not die';
      _done($f);
      ok $f->is_failed, $name.': '.$method.' fails the Future';
      my $err = $f->is_failed ? $f->failure : '';
      like $err, qr/\AWWW::MikroTik: cannot address the record \Q$id\E by name/, $name.': '.$method.' names the record';
      like $err, qr/RouterOS 7\.18\.2/, $name.': the measured RouterOS version';
      like $err, qr/percent-escape/i, $name.': the reason';
      like $err, qr/by its \.id/, $name.': the way out';
    }
    is scalar @{ $http->requests }, 0, $name.': nothing was sent';
    $loop->remove($mt);
  }
};

subtest '*1A stays literal in get and a caller-built path' => sub {
  my ( $mt, $http ) = _nam(
    'GET /rest/ip/address/*1A' => { '.id' => '*1A' },
    'PUT /rest/ip/address/*1A' => { '.id' => '*1A' }
  );
  _done( $mt->get('/ip/address/*1A') );
  _done( $mt->request( 'PUT', '/ip/address/*1A', {} ) );

  is $_->uri->as_string, $base.'/ip/address/*1A', $_->method.' literal *1A' for @{ $http->requests };
  unlike $_->uri->as_string, qr/%2A/i, $_->method.' never %2A' for @{ $http->requests };

  $loop->remove($mt);
};

subtest 'UTF-8 in query and path, with or without the utf8 flag' => sub {
  my ( $mt, $http ) = _nam(
    'GET /rest/interface'          => [],
    'GET /rest/interface/B%C3%BCro' => { name => "B\x{fc}ro" }
  );

  my $flagged = "B\x{fc}ro";
  utf8::upgrade($flagged);
  my $plain = "B\x{fc}ro";
  utf8::downgrade($plain);

  _done( $mt->list( '/interface', comment => $flagged ) );
  _done( $mt->list( '/interface', comment => $plain ) );
  _done( $mt->list( '/interface', comment => "B\x{fc}\x{4e2d}" ) );
  is $http->requests->[0]->uri->as_string, $base.'/interface?comment=B%C3%BCro', 'flagged query value';
  is $http->requests->[1]->uri->as_string, $http->requests->[0]->uri->as_string, 'unflagged is the same URL';
  is $http->requests->[2]->uri->as_string, $base.'/interface?comment=B%C3%BC%E4%B8%AD', 'wide character';
  my %back = $http->requests->[2]->uri->query_form;
  is decode( 'UTF-8', $back{comment} ), "B\x{fc}\x{4e2d}", 'decodes back to the text';

  my $result = _done( $mt->get( '/interface/'.$flagged ) )->get;
  _done( $mt->get( '/interface/'.$plain ) );
  is $http->requests->[3]->uri->as_string, $base.'/interface/B%C3%BCro', 'flagged path';
  is $http->requests->[4]->uri->as_string, $base.'/interface/B%C3%BCro', 'unflagged path is the same';
  is_deeply $result, { name => "B\x{fc}ro" }, 'and the record resolves';

  $loop->remove($mt);
};

subtest 'query values: form-encoding as the sync client' => sub {
  my @cases = (
    [ 'comma', '10.0.0.1,10.0.0.2', '10.0.0.1%2C10.0.0.2' ],
    [ 'slash', '10.0.0.1/24',       '10.0.0.1%2F24' ],
    [ 'space', 'my bridge',         'my+bridge' ],
    [ 'ampersand', 'a&b',           'a%26b' ]
  );
  my ( $mt, $http ) = _nam( 'GET /rest/ip/address' => [] );
  for my $case (@cases) {
    my ( $name, $value, $encoded ) = @$case;
    _done( $mt->list( '/ip/address', comment => $value ) );
    is $http->requests->[-1]->uri->as_string, $base.'/ip/address?comment='.$encoded, $name;
  }
  $loop->remove($mt);
};

subtest '.proplist: arrayref and comma string are the same URL' => sub {
  my ( $mt, $http ) = _nam( 'GET /rest/ip/address' => [] );
  _done( $mt->list( '/ip/address', '.proplist' => [ 'address', 'interface' ] ) );
  _done( $mt->list( '/ip/address', '.proplist' => 'address,interface' ) );

  is $http->requests->[0]->uri->as_string, $base.'/ip/address?.proplist=address%2Cinterface', 'arrayref';
  is $http->requests->[1]->uri->as_string, $http->requests->[0]->uri->as_string, 'string';

  $loop->remove($mt);
};

subtest 'a body with non-ASCII characters is UTF-8 bytes on the wire' => sub {
  my ( $mt, $http ) = _nam( 'PUT /rest/ip/address' => { '.id' => '*A' } );
  _done( $mt->add( '/ip/address', comment => 'Büro 中', address => '10.0.0.5/24' ) );

  my $content = $http->requests->[0]->content;
  is $content, "{\"address\":\"10.0.0.5/24\",\"comment\":\"B\xc3\xbcro \xe4\xb8\xad\"}",
    'raw UTF-8 bytes, no \\u escapes';
  ok !utf8::is_utf8($content), 'a byte string';
  is_deeply decode_json($content), { address => '10.0.0.5/24', comment => 'Büro 中' }, 'round-trips';

  $loop->remove($mt);
};

subtest 'a UTF-8 response body resolves to characters' => sub {
  my $res = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    "[{\"\.id\":\"*1\",\"comment\":\"B\xc3\xbcro\"}]" );
  my ( $mt ) = _nam( 'GET /rest/ip/address' => $res );

  my $rec = _done( $mt->list('/ip/address') )->get->[0];
  is $rec->{comment}, "B\x{fc}ro", 'ü is one character';
  is length $rec->{comment}, 4, 'four characters, not five bytes';

  $loop->remove($mt);
};

done_testing;
