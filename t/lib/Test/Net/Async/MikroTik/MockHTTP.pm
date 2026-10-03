package Test::Net::Async::MikroTik::MockHTTP;

# Router-free stand-in for the Net::Async::MikroTik 'http' attribute. Duck-types
# Net::Async::HTTP: the only method the client calls is
# do_request(request => $http_request), returning a Future of an
# HTTP::Response, so that's the only method this class implements. Not a
# notifier - it is never adopted as a child.
#
# my $http = Test::Net::Async::MikroTik::MockHTTP->new(
#   loop   => $loop,    # optional: answer on the next loop iteration, not at once
#   routes => {
#     'GET /rest/ip/address'       => [ { '.id' => '*1', ... } ],   # 200, JSON-encoded
#     'PUT /rest/ip/address'       => { '.id' => '*A', ... },
#     'DELETE /rest/ip/address/*9' => { error => 404, message => 'Not Found' }, # status from 'error'
#     'DELETE /rest/ip/address/*1' => HTTP::Response->new(204),                # used as-is
#     'POST /rest/ping'            => sub { my $req = shift; ... },           # dynamic, any form here
#     'GET /rest/system/resource'  => Future->fail('Connection refused', connect => ...), # transport failure
#   },
# );
# my $mt = Net::Async::MikroTik->new( host => '...', http => $http );
# ...
# is $http->requests->[0]->method, 'GET';   # every request seen, in order
#
# A route value that is a Future is the transport's answer as it is - a failed
# one stands for Net::Async::HTTP failing (refused, TLS, timeout). With 'loop'
# set, every answer is delivered from a zero-delay timer, so a test only
# passes if the client waits for the Future instead of relying on it being
# ready at once.

use Moo;
use Carp qw( croak );
use Future;
use HTTP::Response;
use JSON::MaybeXS;
use Scalar::Util qw( blessed );
use namespace::clean;

has routes => (
  is      => 'ro',
  default => sub { {} },
);

has requests => (
  is      => 'ro',
  default => sub { [] },
);

has loop => ( is => 'ro' );

has _json => (
  is      => 'ro',
  default => sub { JSON::MaybeXS->new( canonical => 1, utf8 => 1 ) },
);

sub do_request {
  my ( $self, %args ) = @_;

  my $req = $args{request}
    or croak __PACKAGE__.'->do_request: no request given';

  push @{ $self->requests }, $req;

  my $key = $req->method.' '.$req->uri->path;

  croak $self->_no_route_message( $key ) unless exists $self->routes->{ $key };

  my $answer = $self->_answer_for( $self->routes->{ $key }, $req );

  return $answer unless $self->loop;
  return $self->loop->delay_future( after => 0 )->then(sub { $answer });
}

sub _answer_for {
  my ( $self, $handler, $req ) = @_;

  $handler = $handler->( $req ) if ref $handler eq 'CODE';

  return $handler if blessed $handler && $handler->isa( 'Future' );

  return Future->done( $handler ) if blessed $handler && $handler->isa( 'HTTP::Response' );

  my $status = ref $handler eq 'HASH' && exists $handler->{error} ? $handler->{error} : 200;

  my $res = HTTP::Response->new( $status );
  $res->header( 'Content-Type' => 'application/json' );
  $res->content( $self->_json->encode( $handler ) );

  return Future->done( $res );
}

sub _no_route_message {
  my ( $self, $key ) = @_;

  my @known = sort keys %{ $self->routes };

  return __PACKAGE__.": no mock route for '".$key."' (known routes: "
    .( @known ? join( ', ', @known ) : '(none)' ).')';
}

1;
