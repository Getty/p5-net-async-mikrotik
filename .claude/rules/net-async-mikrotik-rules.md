# Net::Async::MikroTik House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Async MikroTik RouterOS REST API client for IO::Async — one public class, transport only.
Read first: `lib/Net/Async/MikroTik.pm` and the `WWW::MikroTik` methods it delegates to
(`build_request`, `parse_response`, the verbs).

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug anything under `lib/` | `net-async-mikrotik-worker` (default) |
| Write or extend tests in `t/` | `net-async-mikrotik-test-writer` |
| POD in the house format | `net-async-mikrotik-doc-writer` |
| Commits, `Changes`, card → done, pre-release audit | `net-async-mikrotik-release-manager` |
| Read-only research, audit, gap analysis | `net-async-mikrotik-worker` ("read-only, change nothing") |

Behavior-relevant = everything under `lib/` and `t/`, transport, configure, Future handling,
error propagation. `Changes`/`README.md` prose is not.

## Coupling — WWW::MikroTik, released in lockstep

All RouterOS semantics live in the sibling `WWW::MikroTik` (`../p5-www-mikrotik`). A change to
paths, auth, JSON, errors or log masking is a ticket on *that* board, never an edit from here.
Run tests with `PERL5LIB=../p5-www-mikrotik/lib` until the seam version is on CPAN.

## Hazards

- **Tests never talk to a real router.** `t/90-live.t` is gated on `MIKROTIK_TEST_HOST` and
  read-only; never set that variable, never widen it. A router is production network gear.
- **Tests assert the wire, not only the Future's result.** "Tests pass" is wrong if
  `WWW::MikroTik` was not the sibling's version.
- **`prove -l t/` is not recursive.** Use `prove -lr t/` or `dzil test`.
- **An untracked file does not exist for dzil** (`Git::GatherDir`) — `git add` at once.
- **A Future nobody holds is gone.** Lifetime rules: skill `perl-io-async-future`.

## Perl conventions — reference, don't restate

Skills `getty-perl-core`, `getty-perl-moo`, `perl-io-async-future`, `getty-perl-pod`,
`getty-perl-release-author-getty`, `perl-release-dist-ini` (force-loaded for
`net-async-mikrotik-*` agents).
