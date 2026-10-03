# Net::Async::MikroTik House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution over
speed on non-trivial work. Subagents get their conventions from the skills force-loaded via
`briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — State assumptions; ask rather than guess. Push back when a
   simpler approach exists. Stop when confused; name what's unclear.
2. **Simplicity first** — One public class, transport only. Minimum code that solves
   the problem, nothing speculative.
3. **Goal-driven execution** — Define success criteria, loop until verified.
4. **Surface conflicts, don't average them** — pick one, explain why, flag the other.
5. **Read before you write** — `lib/Net/Async/MikroTik.pm` and the `WWW::MikroTik`
   methods it delegates to (`build_request`, `parse_response`, the verbs).
6. **Tests verify intent** — Assert the wire, not only the Future's result. Reproduce a
   bug before fixing it; leave the regression test behind.
7. **A red test is a claim before it is a failure** — say what it asserts before
   changing code to turn it green.
8. **Fail loud** — "Done" is wrong if anything was skipped; "tests pass" is wrong if any
   were skipped or `WWW::MikroTik` was not the sibling's version.
9. **Match the codebase's conventions, even if you disagree.**

## Delegation

Depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  code yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run tests,
  edit `Changes`/`README.md` prose. Why: only the `net-async-mikrotik-*` agents get their
  skills force-loaded via `briefing.skills`.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug anything under `lib/` | `net-async-mikrotik-worker` (default) |
  | Write or extend tests in `t/` | `net-async-mikrotik-test-writer` |
  | POD in the house format | `net-async-mikrotik-doc-writer` |
  | Commits, `Changes`, card → done, pre-release audit | `net-async-mikrotik-release-manager` |

- **You cannot spawn subagents** (you ARE a `net-async-mikrotik-*` agent): the lock does
  not apply — implement, refactor, debug and test per these rules.

Behavior-relevant = everything under `lib/` and `t/`, transport, configure, Future
handling, error propagation. **Only `net-async-mikrotik-release-manager` commits.**

## Coordination — karr board (always in scope)

`karr list --compact` / `karr board` · `karr show ID` · `karr create "Title" --priority
high --body '…'` · `karr move ID in-progress --claim NAME` · `karr handoff ID --claim
NAME --note "…"`. Record drift as tickets. **Serialize board mutations when fanning
out** — N concurrent `karr move`/`handoff`/`sync` calls have OOM-rebooted a host.

## Coupling — WWW::MikroTik, released in lockstep

All RouterOS semantics live in the sibling `WWW::MikroTik` (`../p5-www-mikrotik`). A
change to paths, auth, JSON, errors or log masking is a ticket on *that* board, never
an edit from here. Run tests with `PERL5LIB=../p5-www-mikrotik/lib` until the seam
version is on CPAN; CPAN lag is never a blocker.

## Release — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any CPAN upload are
STRICTLY forbidden without the maintainer's explicit go-ahead.

## Hazards

- **Tests never talk to a real router.** `t/90-live.t` is gated on `MIKROTIK_TEST_HOST`
  and read-only; never set that variable, never widen it. A router is production
  network gear.
- **`prove -l t/` is not recursive.** Use `prove -lr t/` or `dzil test`.
- **An untracked file does not exist for dzil** (`Git::GatherDir`) — `git add` at once.
- **A Future nobody holds is gone.** Lifetime rules: skill `perl-io-async-future`.

## Perl conventions — reference, don't restate

Skills `getty-perl-core`, `getty-perl-moo`, `perl-io-async-future`, `getty-perl-pod`,
`getty-perl-release-author-getty`, `perl-release-dist-ini`.
