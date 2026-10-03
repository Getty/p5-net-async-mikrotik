---
name: net-async-mikrotik-core
description: "Use when working on Net::Async::MikroTik — the IO::Async/Future client for the MikroTik RouterOS REST API on top of WWW::MikroTik. The transport-only boundary, the request-override seam into WWW::MikroTik, configure/accessors, Net::Async::HTTP options (timeout, SSL_verify_mode), the mock HTTP notifier tests, and what belongs in WWW::MikroTik instead."
user-invocable: false
---

# Net::Async::MikroTik — async RouterOS REST client

`Net::Async::MikroTik` is the `IO::Async` twin of `WWW::MikroTik` (sibling checkout
`../p5-www-mikrotik`). Same constructor arguments, same method names and
signatures, same wire — every method returns a `Future` instead of a value.
It owns **only the non-blocking transport**. Everything that is about RouterOS
— paths, `.id` segments, `print`'s `.proplist`/`.query`, Basic auth, JSON,
the error croak, log masking — is `WWW::MikroTik`'s and stays there.

Generic notifier/Future lifetime rules are in skill `perl-io-async-future`;
not repeated here.

## Shape

One public class, `Net::Async::MikroTik`, `use parent 'IO::Async::Notifier'`
(not Moo — Notifier owns construction; `configure` deletes its keys before
`SUPER::configure`). Inside the same file one private Moo subclass of
`WWW::MikroTik`, hidden from PAUSE (`package # hide` line break), whose only
override is `request`.

## The seam into WWW::MikroTik — three documented facts

1. `build_request($method, $path, $body, %query)` returns the `HTTP::Request`
   (URL, Basic auth, Content-Type, canonical JSON body, masked debug log).
2. `parse_response($response, $method, $path)` takes an `HTTP::Response` and
   returns the decoded JSON (empty list for an empty body) or croaks
   `WWW::MikroTik: ...` (info/error log included).
3. Every verb (`get put patch delete post list add set remove cmd print`)
   returns exactly what `$self->request(...)` returns, unprocessed.

So the private subclass overrides `request` as
build_request → `Net::Async::HTTP->do_request(request => $req)` →
`parse_response`, wrapped so every error is a failed Future, and
`Net::Async::MikroTik`'s verbs forward to that subclass object's verbs. The
verb logic (`set`'s path join, `print`'s key mapping, ...) is never copied
here. `HTTP::Request`/`HTTP::Response` are the exchange types — both sides
speak them natively, there is no bridge value object.

A change that needs a new URL rule, a JSON tweak or a different error string is
a `WWW::MikroTik` change: note it on your card for that repo's board.

## Configuration

`configure` takes `host user password scheme port base_url verify_ssl timeout`
(passed to `WWW::MikroTik->new` unchanged, same defaults) plus `http` (an
object with `do_request(request => $req)` returning a Future of an
`HTTP::Response` — the test seam, like `WWW::MikroTik`'s `ua`). The default
`http` is a `Net::Async::HTTP` child notifier with `user_agent`
`Net-Async-MikroTik/$VERSION`, `timeout`, and `SSL_verify_mode` 0 when
`verify_ssl` is false. Reconfiguring drops the cached client objects.

## Errors

- Status ≥ 400, non-JSON 2xx: the Future fails with `WWW::MikroTik`'s croak
  message (same text as the sync client).
- Transport failure (connect refused, TLS, timeout): the Future fails with
  `Net::Async::HTTP`'s failure (message, category, ...) unchanged.

## Tests

Offline only. A mock HTTP notifier (`t/lib/Test/Net/Async/MikroTik/MockHTTP.pm`)
records each `HTTP::Request` and answers from routes keyed
`"METHOD /rest/path"` with the same value forms as `WWW::MikroTik`'s MockUA.
Assert the wire (method, URL, query, Basic auth, Content-Type, body bytes)
and the Future's result or failure. `t/90-live.t` is opt-in via the same
`MIKROTIK_TEST_*` variables as `WWW::MikroTik` and read-only; never set them.

Until `WWW::MikroTik` with the seam is on CPAN, run with the sibling on the
path: `PERL5LIB=../p5-www-mikrotik/lib prove -lr t/`.
