# Net::Async::MikroTik

Async [IO::Async](https://metacpan.org/pod/IO::Async) client for the
[MikroTik RouterOS REST API](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API).

The `IO::Async` twin of [WWW::MikroTik](https://metacpan.org/pod/WWW::MikroTik):
same constructor arguments, same method names and signatures, same requests on
the wire — every method returns a `Future`, and the HTTP exchange runs through
`Net::Async::HTTP` on the loop. It is transport only: paths, `.id` segments,
`print`'s `.proplist`/`.query`, Basic auth, JSON, error messages and the masked
debug log all come from `WWW::MikroTik`.

## Synopsis

```perl
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
```

## Installation

```bash
cpanm Net::Async::MikroTik
cpanm IO::Async::SSL        # for https, the default scheme
```

## Constructor

`Net::Async::MikroTik->new(...)` takes `WWW::MikroTik`'s arguments with the
same defaults — `host` (required), `user`, `password`, `scheme`, `port`,
`base_url`, `verify_ssl`, `timeout` — plus `http`:

| Argument | Default | |
|---|---|---|
| `http` | `Net::Async::HTTP` | Anything with `do_request(request => $http_request)` returning a `Future` of an `HTTP::Response` |

The default `http` is a child `Net::Async::HTTP` with `timeout`,
`verify_ssl` as `SSL_verify_mode`, and redirects not followed. Add the client
to a loop before the first request.

## Methods

`request get put patch delete post list add set remove cmd print` — the same
calls as in [WWW::MikroTik](https://metacpan.org/pod/WWW::MikroTik#METHODS),
each returning a `Future` that resolves to what the synchronous method returns
(an empty response body resolves with no values).

```perl
$mt->remove('/ip/address', '*9')->then(sub {
  print "removed\n";
  Future->done;
})->get;
```

## Errors

None of the request methods dies; every failure is a failed `Future`:

- the router answered with status 400 or higher, or with a body that is not
  JSON: the failure is the message `WWW::MikroTik` would croak with,
  `WWW::MikroTik: <status> <message>: <detail>`;
- no answer (connection refused, TLS, timeout): `Net::Async::HTTP`'s failure,
  unchanged;
- an https request while `IO::Async::SSL` cannot be loaded fails at once,
  naming the module, instead of hanging.

Invalid constructor arguments (a missing `host`, an unknown `scheme`) croak at
construction.

## Tests

The suite is mock-driven and needs no router:

```bash
prove -lr t/
```

`t/90-live.t` runs only against a router you name, read-only, with the same
variables as `WWW::MikroTik`'s live test (`MIKROTIK_TEST_HOST`,
`MIKROTIK_TEST_USER`, `MIKROTIK_TEST_PASSWORD`, `MIKROTIK_TEST_VERIFY_SSL`,
`MIKROTIK_TEST_SCHEME`, `MIKROTIK_TEST_PORT`):

```bash
MIKROTIK_TEST_HOST=192.168.88.1 MIKROTIK_TEST_VERIFY_SSL=0 prove -l t/90-live.t
```

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See `LICENSE`.
