# Plan, written before the runs (2026-10-22)

## SLO: "comfortable" for N parallel sessions (proposed by the agent; the owner has not confirmed them yet)

| | threshold | why |
|---|---|---|
| S1 lock wait p95 | ≤ 5 min | a session that waits longer is a session the owner checks on |
| S2 branches that need a second `ship.sh` run (exit 4) | ≤ 10 % | each one is a turn the owner or the agent spends again |
| S3 invariant violations (`lab/race.sh`) | 0 | lost work or a red target is never comfortable |
| S4 owner interventions outside valid stops | 0 | a valid stop is a semantic conflict or an OWNER DECISION |
| S5 owner latency | p50 ≤ 2 × the p50 at 0–1 other open sessions | the owner, not the queue, is the bottleneck past this |

## Inputs taken from the owner's own data

- T (pre-merge suite): hotpot2 `pnpm test`, monorepo `pnpm ts-check && pnpm test` (`lab/suite-time.sh`).
- Task cycle W: first prompt to first commit in the owner's human sessions (`lab/sessions.py`).
- Conflict density: monorepo MRs with a conflicting back-merge; hotpot2 history (0 of 84 parallel pairs).

## Dependency forms and the outcome expected from polyship (stub agent and real agent)

| form | example | expected with polyship | a failure would be |
|---|---|---|---|
| D1 ordered | B calls a helper A adds | B's tests are red until A lands; with `ship.sh` B stops with exit 1 before the queue, so a dependent never holds the lock with a red suite; B lands on a retry after A | B lands without A (red target), or B burns the lock repeatedly in `merge.sh` mode |
| D2 duplicate | two sessions make the same change | the second rebase drops the duplicate commit; exit 0, nothing lost (B2 in REPORT) | exit 5, or two copies of the change on main |
| D3 incompatible (semantic) | A removes/renames an api, B adds a caller | the second one is red after the rebase: refused (exit 1); the target stays green | red target; or a real agent "fixes" by undoing the other's change |
| D4 hot file | both append to one registry/translation file | textual conflict; the agent keeps both sides; lands | an entry of one side lost |
| D5 hidden duplicate (real agent only) | B needs A's helper, writes its own copy | both land, tests green, two implementations on main | not caught by polyship by design: report the count |

Pass for the stand: 0 violations in ≥ 100 runs at N = 10 with the new forms on.
Pass for the real-agent swarm: every task's hidden acceptance test is green on the final target, or the task stopped with a
valid reason; no first-parent commit of the target is red; no task's work undone by another session.
Outcomes: measurements/REPORT.md, section "Capacity and dependent work, 2026-10-22". The D1 expectation "lands on a retry" held only when the session rebases (see there).
