---
name: net-async-mikrotik-core
description: Use when working on Net::Async::MikroTik — the IO::Async/Future client for the MikroTik RouterOS REST API: the transport-only seam into WWW::MikroTik, the verbs and their wire format, the http transport attribute, the failure shapes and the mock-driven tests.
user-invocable: false
---

# net-async-mikrotik — Kern

`Net::Async::MikroTik` is the `IO::Async` twin of `WWW::MikroTik` (sibling
checkout `~/dev/p5-www-mikrotik`): same constructor arguments, same method
names and signatures, same requests on the wire — every method returns a
`Future` instead of a value, and the HTTP exchange runs through
`Net::Async::HTTP` on the loop. The distribution is **transport only**: paths,
`.id` segments, `print`'s `.proplist`/`.query`, Basic auth, JSON, error texts
and the masked debug log belong to `WWW::MikroTik`; notifier and Future rules:
skill `perl-io-async-future`.

## Two classes in one file

- `Net::Async::MikroTik` — the public class, `use parent 'IO::Async::Notifier'`,
  **not** Moo: `configure` deletes its own keys before `SUPER::configure`.
- `Net::Async::MikroTik::_Client` — a private Moo subclass of `WWW::MikroTik`,
  hidden from PAUSE by the `package # hide` line break. It holds `notifier` as
  a `weak_ref`; a request croaks when the client is gone.

The `_Client` overrides exactly one method: `request`. Every verb, path rule,
JSON detail and error message is inherited unchanged.

## The seam into WWW::MikroTik

1. `build_request($method, $path, $body, %query)` returns the `HTTP::Request`:
   URL, Basic auth, `Content-Type`, canonical JSON body, masked debug log.
2. `parse_response($response, $method, $path)` returns the decoded JSON (the
   empty list for an empty body) or croaks `WWW::MikroTik: ...`.
3. Every verb returns exactly what `$self->request(...)` returns, unprocessed.

`HTTP::Request` and `HTTP::Response` are the exchange types; both sides speak
them natively. The subclass overrides `request` as build_request →
`do_request(request => $req)` → parse_response, wrapped so every error becomes
a failed Future; the public class's verbs forward to that object's verb of the
same name, so the verb logic is never copied here.

## The verbs

`request get put patch delete post list add set remove cmd print` — the sync
client's names and signatures, each returning a `Future` of exactly what the
synchronous method returns. The router-facing mapping is the sync client's:
`list`/`get` → GET, `add`/`put` → PUT, `set`/`patch` → PATCH, `remove`/`delete`
→ DELETE, `cmd`/`post` → POST, `print` → POST to `$path/print`.

`_forward` wraps every call in `Future->call`, so nothing a verb does — not
even the sync client's own croak — escapes as a dying exception.

## Configuration

`configure` takes `host user password scheme port base_url verify_ssl timeout`
(passed to `WWW::MikroTik->new` unchanged) plus `http`. The defaults are the
sibling's: `user` admin, `password` empty, `scheme` https, `port` unset,
`verify_ssl` 1, `timeout` 60, `base_url` `<scheme>://<host>[:<port>]/rest`.

Any of the connection attributes rebuilds the internal client from the merged
arguments. An invalid argument croaks with the sibling's constructor error
(`Missing required arguments?: host`, a bad `scheme`, `port` or `timeout`) and
leaves the object unchanged — the client is built *before* anything is stored.

### The default transport

Built on first use, not at construction: a `Net::Async::HTTP` child notifier
with `user_agent` `Net-Async-MikroTik/$VERSION`, `timeout` from the client,
`SSL_verify_mode` 1 or 0 (set explicitly in both directions — left unset,
`IO::Async::SSL` quietly falls back to no verification when it finds no CA
store) and `max_redirects` 0 (a redirect is not followed, because
`Net::Async::HTTP` would resend the Basic auth header to wherever it points).
It joins the loop with the client — request only after `$loop->add($mt)`.
Reconfiguring `timeout` or `verify_ssl` to a different value replaces the
default and removes the old one from the loop; a request still in flight on it
fails with `Connection closed`.

### The `http` attribute as seam

Any object with `do_request(request => $http_request)` returning a `Future` of
an `HTTP::Response` — the interface of `Net::Async::HTTP`; anything else croaks
at `configure`. An injected `IO::Async::Notifier` with neither parent nor loop
is adopted as a child, everything else is used as it is. `configure(http =>
undef)` releases it and goes back to the default one.

## Failure shapes

No request method dies synchronously; every failure is a failed `Future`. No
error classes of its own: the sync croak text is the contract.

1. **The router answered** — status 300 or higher, or a status below 300 with
   a body that is not JSON: the Future fails with the sibling's croak text;
   the status comes from the HTTP line, not from the router's JSON error
   object.
2. **No answer came** — connection refused, TLS, timeout: the failure is
   `Net::Async::HTTP`'s, unchanged — message, category and details.
3. **This module's own two failures**, raised before anything is sent: an https
   request while `IO::Async::SSL` cannot be loaded fails at once with
   `Net::Async::MikroTik: https needs IO::Async::SSL 0.12 or later`, every
   time, instead of hanging later requests; a request while the default `http`
   is not in a loop fails with `Net::Async::MikroTik: add it to an
   IO::Async::Loop before making requests` — only the default
   `Net::Async::HTTP` is checked for that.

## The wire

The async layer never re-encodes: what the sibling builds goes out unchanged.
The URL is `<base_url><path>`; `base_url` carries the `/rest` prefix, Basic
auth goes on every request. The body is the sibling's canonical JSON; `cmd`
always sends one (`{}` even without arguments), `print` puts `.proplist` and
`.query` into it, never into the URL. Every RouterOS value is a string in both
directions (`"disabled":"false"`): compare with `eq` and send `'true'`/`'false'`,
never JSON booleans. The escaping rules for path segments and query values,
the JSON encoding and the 60-second RouterOS limit are the twin's — they apply
here unchanged and stand in the sibling's skill, not in this one.

## Logging

The log lines belong to the sibling: a debug line `METHOD <url>` and a debug
line `Body: {...}`, an info line `METHOD /path -> <status>` and an error line
`WWW::MikroTik: <status> <message>`. Secret-looking keys (password,
passphrase, secret, token, psk, `key`, every `*-key` except `public-key`) are
masked to `***` in the log only — the wire carries the real value. A transport
failure logs neither the info nor the error line: nothing answered.

## Concurrency

Several requests in flight on one client resolve independently and in any
order; a failure touches only its own Future. Cancelling a Future cancels the
transport Future with it and leaves the others alone; a late answer for a
cancelled request is harmless, and the client stays usable. `Future->needs_all`
over several calls gathers the answers in call order.

## Tests

| File | Covers |
|---|---|
| `t/00-load.t` | the module loads; the sibling has the seam |
| `t/05-constructor.t` | constructor, `configure`, the croaks, the `http` seam |
| `t/10-basic.t` | one request: wire and result, a router error, an empty body, a transport failure |
| `t/12-verbs.t` | every verb: method, URL, body bytes and result |
| `t/15-encoding.t` | path segments, query values and UTF-8 bytes |
| `t/20-guards.t` | the two failures this module raises itself |
| `t/30-responses.t` | decoded JSON, empty list or the croak text |
| `t/40-print.t` | `print`'s `.proplist`/`.query` bodies |
| `t/50-logging.t` | the log lines and the masking |
| `t/60-concurrency.t` | requests in flight, cancellation, dropping a Future |
| `t/90-live.t` | the live suite, opt-in via the sibling's `MIKROTIK_TEST_*`, read-only |

`t/lib/Test/Net/Async/MikroTik/MockHTTP.pm` is the router-free transport: it
duck-types `Net::Async::HTTP` and answers from routes keyed
`"METHOD /rest/path"`. A route value is a response to JSON-encode, an
`HTTP::Response` to use as it is, a `Future` to fail as a transport failure, or
a code to call. With `loop` set, every answer comes from a zero-delay timer,
so a test only passes if the client waits for the Future.

```bash
prove -lr t                    # recursive — a plain `prove -l t/` skips t/lib
dzil test && dzil clean
PERL5LIB=../p5-www-mikrotik/lib prove -lr t/   # until the seam version is on CPAN
```

## Delegation

Behavior-relevant work — runtime behaviour, the public API, the Future
contract, error propagation, the twin invariant, tests — belongs to the
`net-async-mikrotik-*` agents; the table and the delegation lock are in
`.claude/rules/net-async-mikrotik-rules.md`. This skill is force-loaded via
`briefing.skills`.
