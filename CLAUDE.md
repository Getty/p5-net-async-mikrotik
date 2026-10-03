# CLAUDE.md — Net::Async::MikroTik

Async `IO::Async`/`Future` client for the MikroTik RouterOS REST API. One public class,
`Net::Async::MikroTik` (an `IO::Async::Notifier`), driving `Net::Async::HTTP`. It is
**transport only**: request building, auth, JSON, errors and log masking belong to the
sibling `WWW::MikroTik` (`../p5-www-mikrotik`), released in lockstep.

Build and test (until the `WWW::MikroTik` seam version is on CPAN):
`PERL5LIB=../p5-www-mikrotik/lib prove -lr t/` (`-r` — plain `prove -l t/` is not
recursive), `PERL5LIB=../p5-www-mikrotik/lib dzil test`, `dzil clean`. The suite is
mock-driven and needs no router. Never `dzil release` without explicit permission.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
the principle, the lanes and this repo's hazards are in
`.claude/rules/net-async-mikrotik-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug anything under `lib/` | `net-async-mikrotik-worker` (default) |
| Write or extend tests in `t/` | `net-async-mikrotik-test-writer` |
| POD in the house format | `net-async-mikrotik-doc-writer` |
| Commits, `Changes`, card → done, pre-release audit | `net-async-mikrotik-release-manager` |

The agents carry their conventions via `briefing.skills` (see `.claude/agents/`); the
main agent delegates rather than loading them. Skill sources live in `.claude/skills/` —
`net-async-mikrotik-core` is this repo's own, the rest are installed by skilletor
(`.claude/skilletor.json`; never edit them in place). Work is tracked on the local
`karr` board.
