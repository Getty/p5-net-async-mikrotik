package Net::Async::MikroTik;
# ABSTRACT: Async MikroTik RouterOS REST API client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Carp qw( croak );
use Future;
use Net::Async::HTTP;
use Scalar::Util qw( blessed refaddr );
use WWW::MikroTik;
use namespace::clean;

our $VERSION = '0.001';

=synopsis

    use IO::Async::Loop;
    use Net::Async::MikroTik;

    my $loop = IO::Async::Loop->new;

    my $mt = Net::Async::MikroTik->new(
      host       => '192.168.88.1',
      user       => 'admin',
      password   => $ENV{MIKROTIK_PASSWORD},
      verify_ssl => 0,                    # lab router, self-signed
    );
    $loop->add($mt);

    # Block on one Future
    my $addrs = $mt->list('/ip/address', interface => 'ether2')->get;

    # Or chain without blocking
    my $f = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2')
      ->then(sub {
        my ( $new ) = @_;
        return $mt->set('/ip/address', $new->{'.id'}, comment => 'uplink');
      })
      ->on_fail(sub { warn 'failed: '.$_[0] });
    $loop->await($f);

    # Several requests in parallel
    my ( $res, $ifs ) = Future->needs_all(
      $mt->cmd('/system/resource/print'),
      $mt->print('/interface', proplist => [qw( name type )]),
    )->get;

=description

The L<IO::Async> twin of L<WWW::MikroTik>: same constructor arguments, same
method names and signatures, same requests on the wire - but every method
returns a L<Future> instead of a value, and the HTTP exchange runs through
L<Net::Async::HTTP> on the loop instead of a blocking L<LWP::UserAgent>.

This module is transport only. Paths, C<.id> segments, C<print>'s
C<.proplist>/C<.query>, Basic auth, JSON encoding and decoding, the error
messages and the masked debug log all come from L<WWW::MikroTik>: an internal
subclass of it overrides only L<WWW::MikroTik/request>, sending the
L<HTTP::Request> from L<WWW::MikroTik/build_request> with C<http> and handing
the L<HTTP::Response> to L<WWW::MikroTik/parse_response>. Read
L<WWW::MikroTik> for what each method sends and what it resolves to.

As there, every RouterOS value is a string in both directions
(C<"disabled":"false">): nothing is converted, compare with C<eq> and send
C<'true'>/C<'false'>, never JSON booleans.

A request fails its Future in one of two shapes:

=over 4

=item * The router answered, with a status of 400 or higher or with a body
that is not JSON: the failure is the message L<WWW::MikroTik> would C<croak>
with, C<< WWW::MikroTik: <status> <message>: <detail> >> and its variants.

=item * No answer came back - connection refused, TLS failure, timeout: the
failure is L<Net::Async::HTTP>'s, unchanged, message and category and details
(C<< ( $message, 'timeout' ) = $f->failure >>, for example).

=back

Two failures are this module's own, both before anything is sent: an https
request when L<IO::Async::SSL> cannot be loaded (see L</http>), and a request
while the default C<http> is not in a loop. Every one of these arrives as a
failed Future; none of the request methods dies synchronously.
Constructing or reconfiguring it with invalid arguments - a missing C<host>,
a C<scheme> other than C<http>/C<https> - C<croak>s immediately with
L<WWW::MikroTik>'s constructor error, because the internal client is built
right there.

RouterOS ends every REST request after 60 seconds whatever the client does:
a command without its limiting parameter (C<ping> without C<count>,
C<monitor> without C<once>) fails with C<400 Session closed> here exactly as
with L<WWW::MikroTik/cmd>.

=cut

#### Configuration

sub _client_keys { qw( host user password scheme port base_url verify_ssl timeout ) }

sub configure {
  my ( $self, %params ) = @_;

  my %args = %{ $self->{_client_args} // {} };
  my $client_changed;
  for my $key ($self->_client_keys) {
    next unless exists $params{$key};
    $args{$key} = delete $params{$key};
    $client_changed = 1;
  }

  my $has_http = exists $params{http};
  my $http     = delete $params{http};
  croak __PACKAGE__.'->configure: http must be an object with a do_request method'
    if defined $http && !( blessed $http && $http->can('do_request') );

  # Built before anything is stored: an invalid argument croaks with
  # WWW::MikroTik's constructor error and leaves this object unchanged.
  my $client = $client_changed || !$self->{_client}
    ? $self->_client_class->new( %args, notifier => $self )
    : undef;

  $self->SUPER::configure(%params);

  if ($client) {
    my $old = $self->{_client};
    $self->{_client_args} = \%args;
    $self->{_client}      = $client;
    # The default http was built from timeout and verify_ssl; a changed value
    # needs a new one (and fresh connections - a pooled connection opened
    # without verification must not be reused once verify_ssl is on).
    $self->_release_http if $self->{_own_http} && $old
      && ( $old->timeout != $client->timeout
        || !$old->verify_ssl != !$client->verify_ssl );
  }

  if ($has_http) {
    $self->_release_http;
    if (defined $http) {
      $self->{_http} = $http;
      $self->_adopt($http);
    }
  }

  return;
}

=method configure

    $mt->configure( timeout => 10, password => $new_password );

Takes the attributes below, plus the L<IO::Async::Notifier> parameters. Any
connection attribute rebuilds the internal L<WWW::MikroTik> client from the
merged arguments - requests already in flight finish with the old one - and
C<croak>s with its constructor error, leaving everything unchanged, if the
result is invalid. Passing C<http> replaces the transport (C<undef> goes back
to the default); a default or adopted one that is replaced is removed as a
child.

=cut

sub _client_class { 'Net::Async::MikroTik::_Client' }

sub _client { $_[0]->{_client} }

sub host { shift->_client->host }

=attr host

Router address - IP or hostname. Required: constructing without it C<croak>s
with L<WWW::MikroTik>'s constructor error. This and the following
connection attributes are passed to L<WWW::MikroTik/new> exactly as given
(only those you pass), so defaults and validation are that module's; see
L<WWW::MikroTik/host>.

=cut

sub user { shift->_client->user }

=attr user

Console user for HTTP Basic auth. Defaults to C<admin>.
L<WWW::MikroTik/user>.

=cut

sub password { shift->_client->password }

=attr password

Console password for HTTP Basic auth. Defaults to C<''>.
L<WWW::MikroTik/password>.

=cut

sub scheme { shift->_client->scheme }

=attr scheme

C<https> (the default) or C<http>. C<https> needs L<IO::Async::SSL>
installed - see L</http>. L<WWW::MikroTik/scheme>.

=cut

sub port { shift->_client->port }

=attr port

TCP port; unset means the scheme's standard port. L<WWW::MikroTik/port>.

=cut

sub base_url { shift->_client->base_url }

=attr base_url

C<< <scheme>://<host>[:<port>]/rest >> unless given. L<WWW::MikroTik/base_url>.

=cut

sub verify_ssl { shift->_client->verify_ssl }

=attr verify_ssl

    verify_ssl => 0,   # lab router, self-signed cert

Verify the router's TLS certificate and host name. Defaults to C<1>. Applied
to the default L</http> only, as C<SSL_verify_mode>; an injected C<http> is
used as it is. L<WWW::MikroTik/verify_ssl>.

=cut

sub timeout { shift->_client->timeout }

=attr timeout

Request timeout in seconds, default C<60>. Applied to the default L</http>
only; an injected C<http> is used as it is. L<WWW::MikroTik/timeout>.

=cut

sub http {
  my ( $self ) = @_;
  return $self->{_http} //= $self->_build_http;
}

sub _build_http {
  my ( $self ) = @_;
  my $http = Net::Async::HTTP->new(
    user_agent      => 'Net-Async-MikroTik/'.$VERSION,
    timeout         => $self->timeout,
    # 1 is IO::Socket::SSL's SSL_VERIFY_PEER (host name included), 0 its
    # SSL_VERIFY_NONE - literals, because IO::Socket::SSL is only there when
    # the recommended IO::Async::SSL is. Set explicitly both ways: left
    # unset, IO::Async::SSL quietly falls back to no verification when it
    # finds no CA store.
    SSL_verify_mode => $self->verify_ssl ? 1 : 0,
    # A redirect is not followed: Net::Async::HTTP would resend the Basic auth
    # header to wherever it points, and a redirect to https would connect
    # without the IO::Async::SSL check below. RouterOS's REST API does not
    # redirect; one that arrives anyway goes to parse_response as it is.
    max_redirects   => 0,
  );
  $self->{_own_http} = 1;
  $self->_adopt($http);
  return $http;
}

=attr http

    http => $any_object_with_do_request,

The HTTP transport: any object with
C<< do_request( request => $http_request ) >> returning a L<Future> of an
L<HTTP::Response> - the interface of L<Net::Async::HTTP>, and the seam the
test suite uses to run without a router.

Unless given, built on first use: a L<Net::Async::HTTP> with the
C<user_agent> C<Net-Async-MikroTik/$VERSION>, the L</timeout>,
C<SSL_verify_mode> from L</verify_ssl>, and C<max_redirects> C<0> (a
redirect is not followed and fails as a non-JSON response; RouterOS does not
send one). It becomes a child notifier of this object, so it joins the loop
when this object is added - make requests only after C<< $loop->add($mt) >>,
otherwise they fail. Reconfiguring C<timeout> or C<verify_ssl> to a
different value replaces it and removes the old one from the loop, closing
its connections: a request still in flight on it fails with
L<Net::Async::HTTP>'s C<Connection closed>. An
injected L<IO::Async::Notifier> that has neither a parent nor a loop is
adopted as a child the same way; anything else is used as it is.

Before an https request through a L<Net::Async::HTTP>, this module checks
once that L<IO::Async::SSL> (0.12 or later) loads, and fails the request
with C<< Net::Async::MikroTik: https needs IO::Async::SSL ... >> if it does
not. L<Net::Async::HTTP> itself loads it only while connecting, and a load
failure there leaves every later request to that router hanging forever.
L<IO::Async::SSL> is a recommended, not a required, dependency: install it
unless you only talk to C<http> routers.

=cut

sub _adopt {
  my ( $self, $http ) = @_;
  return unless blessed $http && $http->isa('IO::Async::Notifier');
  return if defined $http->parent || defined $http->loop;
  $self->add_child($http);
}

sub _release_http {
  my ( $self ) = @_;
  my $http = delete $self->{_http};
  delete $self->{_own_http};
  return unless blessed $http && $http->isa('IO::Async::Notifier');
  my $parent = $http->parent;
  $self->remove_child($http) if $parent && refaddr $parent == refaddr $self;
}

#### Transport

# The client's request ends here: the HTTP::Request built by WWW::MikroTik
# goes out through http. Returns a Future of the HTTP::Response.
sub _send {
  my ( $self, $req ) = @_;
  my $http = $self->http;
  if (blessed $http && $http->isa('Net::Async::HTTP')) {
    return Future->fail(__PACKAGE__.': add it to an IO::Async::Loop before making requests'."\n")
      unless $http->loop;
    if ($req->uri->scheme eq 'https') {
      my $problem = $self->_ssl_problem;
      return Future->fail($problem) if length $problem;
    }
  }
  return $http->do_request( request => $req );
}

# Net::Async::HTTP loads IO::Async::SSL by name only while connecting, and a
# failure there leaks the connection slot: the first request fails, every
# later one to that host hangs. It is an optional dependency, so probe it
# here - the one place a runtime require is the point - and fail loudly.
sub _ssl_problem {
  my ( $self ) = @_;
  return $self->{_ssl_problem} //= eval {
    require IO::Async::SSL;
    IO::Async::SSL->VERSION('0.12');
    '';
  } // do {
    my ( $reason ) = split /\n/, $@;
    __PACKAGE__.': https needs IO::Async::SSL 0.12 or later, which did not load: '.$reason."\n";
  };
}

#### Verbs

# Each verb is the internal WWW::MikroTik subclass's verb of the same name,
# whose request returns a Future. Future->call turns anything that still dies
# on the way there into a failed Future.
sub _forward {
  my ( $self, $verb, @args ) = @_;
  return Future->call(sub { $self->_client->$verb(@args) });
}

sub request { shift->_forward( request => @_ ) }

=method request

    my $f = $mt->request('GET', '/ip/address', undef, interface => 'ether2');

Returns a L<Future> of what L<WWW::MikroTik/request> returns: the decoded
JSON, or no value at all for an empty response body. Every verb below is
L<WWW::MikroTik>'s verb of the same name on top of this, so each resolves to
exactly what its synchronous counterpart returns.

=cut

sub get { shift->_forward( get => @_ ) }

=method get

    my $f = $mt->get('/ip/address', interface => 'ether2');

Future of the records (or one record, for a path ending in an C<.id>).
L<WWW::MikroTik/get>.

=cut

sub put { shift->_forward( put => @_ ) }

=method put

    my $f = $mt->put('/ip/address', { address => '10.0.0.5/24', interface => 'ether2' });

Future of the created record. L<WWW::MikroTik/put>.

=cut

sub patch { shift->_forward( patch => @_ ) }

=method patch

    my $f = $mt->patch('/ip/address/*1A', { comment => 'uplink' });

Future of the updated record. L<WWW::MikroTik/patch>.

=cut

sub delete { shift->_forward( delete => @_ ) }

=method delete

    my $f = $mt->delete('/ip/address/*1A');

Future that resolves with no value on success. L<WWW::MikroTik/delete>.

=cut

sub post { shift->_forward( post => @_ ) }

=method post

    my $f = $mt->post('/ping', { address => '10.155.101.1', count => '4' });

Future of the command's result. L<WWW::MikroTik/post>.

=cut

sub list { shift->_forward( list => @_ ) }

=method list

    my $f = $mt->list('/ip/address', interface => 'ether3');

Future of the records matching C<%filter>. L<WWW::MikroTik/list>.

=cut

sub add { shift->_forward( add => @_ ) }

=method add

    my $f = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2');

Future of the created record, including its new C<.id>.
L<WWW::MikroTik/add>.

=cut

sub set { shift->_forward( set => @_ ) }

=method set

    my $f = $mt->set('/ip/address', $rec->{'.id'}, comment => 'uplink');

Future of the full updated record; C<$id> is one escaped path segment as in
L<WWW::MikroTik/set>.

=cut

sub remove { shift->_forward( remove => @_ ) }

=method remove

    my $f = $mt->remove('/ip/address', $rec->{'.id'});

Future that resolves with no value on success. L<WWW::MikroTik/remove>.

=cut

sub cmd { shift->_forward( cmd => @_ ) }

=method cmd

    my $f = $mt->cmd('/ping', address => '10.155.101.1', count => '4');

Future of the command's result. The 60 second RouterOS limit applies:
always pass the command's limiting parameter. L<WWW::MikroTik/cmd>.

=cut

sub print { shift->_forward( print => @_ ) }

=method print

    my $f = $mt->print('/interface', proplist => [qw( name type )],
                       query => [ 'type=ether', 'type=vlan', '#|' ]);

Future of the records; C<proplist>/C<query> become C<.proplist>/C<.query>
as in L<WWW::MikroTik/print>.

=cut

=seealso

=over 4

=item * L<WWW::MikroTik> - the synchronous client, and the reference for every method's semantics

=item * L<RouterOS REST API|https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API> - the vendor's own reference

=item * L<Net::Async::HTTP> - the default transport

=item * L<IO::Async>, L<Future>

=back

=cut

package # hide from PAUSE
  Net::Async::MikroTik::_Client;

# The WWW::MikroTik that Net::Async::MikroTik drives: everything but the
# transport is inherited. request returns a Future instead of the decoded
# response, and every verb returns what request returns.

use Moo;
extends 'WWW::MikroTik';
use Carp qw( croak );
use Future;
use namespace::clean;

has notifier => (
  is       => 'ro',
  required => 1,
  weak_ref => 1,
);

sub request {
  my ( $self, $method, $path, $body, %query ) = @_;
  return Future->call(sub {
    my $notifier = $self->notifier
      or croak 'Net::Async::MikroTik: the object this request belongs to is gone';
    my $req = $self->build_request($method, $path, $body, %query);
    return $notifier->_send($req)->then(sub {
      my ( $res ) = @_;
      # List context on purpose: an empty body is the empty list, so the
      # Future is done with no values - undef from ->get in scalar context,
      # exactly like the synchronous request.
      return Future->done( $self->parse_response($res, $method, $path) );
    });
  });
}

1;
