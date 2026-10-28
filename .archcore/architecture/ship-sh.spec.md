---
title: "ship.sh — review, tests, merge and conflict rounds"
status: draft
tags:
  - "ship"
  - "spec"
---

## Purpose & Scope
The contract of `@bin/ship.sh`: the tail of a task in a worktree, review, tests, the locked merge and an agent on every conflict, with an exit code that names what stopped it. Depended on by the adopters' agent instructions ("a task ends with ship.sh") and task-runner aliases, by `@lab/race.sh` (`MODE=ship`) and `@lab/replay.sh`. Out of scope: the merge itself (`@bin/merge.sh`), the content of the review, and the resolution the agent produces.

## Surface
- Invocation: `ship.sh`, no arguments, inside a worktree on a branch other than the target.
- Inputs: `SHIP_TEST`, `SHIP_AGENT`, `SHIP_REVIEW`, `SHIP_REVIEW_HOW`, `SHIP_ROUNDS` (10), plus the `MERGE_*` inputs of merge.sh.
- Files: reads merge.sh's moves log `<git-common-dir>/wt-merge.moves`; the conflict prompt tells the agent to append a skipped duplicate to `<git-dir>/merge-dropped`.
- Agent subprocess: `claude -p --permission-mode bypassPermissions` or `codex exec --dangerously-bypass-approvals-and-sandbox`, prompt on stdin. Codex's workspace-write sandbox keeps a worktree's git dir read-only, so the agent could not commit or finish a rebase in it (R22).
- Logs in the worktree's git dir: `ship-review.log`, `ship-test.log`, `ship-conflict.log`.
- Verdict lines the agent ends with: `REVIEW OK`, `REVIEW BLOCKED: <reason>`, `OWNER DECISION NEEDED: <A> vs <B>`.
- Exit codes: 0, 1, 2, 3, 4, 5. Events: `ship-round`, `ship-conflict`, `ship-fence-pass`, `ship-exit`.

## Normative Behavior
1. WHEN the branch is already on the target with nothing lost, ship.sh MUST exit 0 before any agent call.
2. WHEN `SHIP_REVIEW` is not `0`, ship.sh MUST run one review by the agent and read its last non-empty line as the verdict.
3. WHEN the verdict is `REVIEW OK` and the tree is clean, ship.sh MUST continue to the tests.
4. WHEN the target is not an ancestor of the branch, ship.sh MUST rebase the branch onto the target before the tests (R9).
5. WHEN that rebase conflicts, ship.sh MUST abort it and skip `SHIP_TEST`; the merge rounds resolve, the pre-merge hook tests (R9b).
6. WHEN the rebase is clean or not needed, ship.sh MUST run `SHIP_TEST` before the merge queue.
7. WHEN the tests pass or are skipped, ship.sh MUST call merge.sh for up to `SHIP_ROUNDS` rounds and stop at the first exit 0.
8. WHEN a round leaves a rebase open, ship.sh MUST call the agent once with the conflict prompt.
9. WHEN an agent run starts, ship.sh MUST record the fence: the target's tip, the remotes, and the hooks directory.
10. WHEN the target moved and every step is a line of the moves log, with remotes and hooks unchanged, ship.sh MUST continue (R8).
11. WHEN that chain is incomplete, ship.sh MUST read the fence again under the merge lock before its verdict.
12. WHEN merge.sh exits 5, ship.sh MUST exit 5 without another round.
13. ship.sh MUST pass the agent's prompt on stdin and tee its output to the log named in Surface.
14. WHEN a rebase is open at the start, ship.sh MUST remove that rebase's locks older than `MERGE_STALE_INDEX_LOCK` seconds (R10).
15. WHEN ship.sh rebases the branch before the tests, it MUST record the branch tip first (R1b).
16. ship.sh MUST set `SHIP_AGENT_RUN` to this repository's git common dir for every agent run (R8c, R8d).
17. WHEN ship.sh starts, it MUST remove the worktree's `index.lock` and `HEAD.lock` older than `MERGE_STALE_INDEX_LOCK` seconds (R1c, R5b).
18. WHEN `landed` returns 5, ship.sh MUST exit 5 before it checks for uncommitted changes (R1d).
19. WHEN an open rebase has already finished (see Constraints), ship.sh MUST close it and go on (R10c).
20. WHEN `landed` returns 5 and the tree has uncommitted changes, ship.sh MUST say to stash them before the reset (R1e).
21. WHEN ship.sh starts with HEAD on a branch, a clean tree and `CHERRY_PICK_HEAD` with no rebase open, it MUST clear the cherry-pick state (R21).
22. WHEN ship.sh starts with HEAD on a branch, a clean tree and a `rebase-merge/` without `head-name`, it MUST remove that directory (R21b).
23. WHEN `MERGE_PUSH` is set and the branch is already on the local target, ship.sh MUST run merge.sh before that exit 0 (R19j).
24. WHEN merge.sh exits 2 in a round, ship.sh MUST exit 2.

## Constraints & Invariants
- Invariant: ship.sh never merges, moves the target, or resolves a conflict itself; git writes happen in merge.sh and in the agent.
- Invariant: exit 0 implies `landed` returned 0: the branch is on the target with every recorded commit (`@bin/lib.sh`).
- Constraint: one agent call per step and no retry of the agent; only the merge loops, `SHIP_ROUNDS` rounds.
- Constraint: the agent runs without an allow-list; the fence check is the guard against a moved target, a new remote, or a planted hook.
- Constraint: a verdict is the last non-empty line exactly; the same phrase quoted inside prose is not a verdict.
- Constraint: `SHIP_AGENT` is `claude` or `codex`; the default is `claude` when on PATH, else `codex`.
- Constraint: the default `SHIP_TEST` is `wt hook pre-merge --yes`, the adopter's own gate.
- Constraint: a rebase counts as finished when no step is left, the branch is at HEAD, HEAD is not its old tip, and the tree is clean.
- Constraint: when the rebase before the tests conflicts, the adopter's `pre-merge` hook is the only test of that branch; an adopter without one lands it untested.

## Failure Behavior
1. IF HEAD is the target branch or detached, THEN ship.sh MUST exit 2.
2. IF the tree has uncommitted changes, THEN ship.sh MUST exit 2.
3. IF a rebase is open in the worktree at the start, THEN ship.sh MUST exit 2 naming the open rebase (R10).
4. IF the verdict is `REVIEW BLOCKED: …` or no verdict line exists, THEN ship.sh MUST exit 1 naming the log.
5. IF the review left uncommitted changes, THEN ship.sh MUST exit 1.
6. IF the tests exit non-zero, THEN ship.sh MUST exit 1 after the last 40 log lines.
7. IF the conflict agent ends with `OWNER DECISION NEEDED: …`, THEN ship.sh MUST exit 3, the rebase left open.
8. IF a rebase is still open after the agent, THEN ship.sh MUST exit 1.
9. IF merge.sh fails without an open rebase, THEN ship.sh MUST exit 1 (red tests after the rebase, a lock, MERGE_PREPARE).
10. IF the branch is not on the target after `SHIP_ROUNDS` rounds, THEN ship.sh MUST exit 1.
11. IF `SHIP_AGENT` names an unknown agent, THEN ship.sh MUST exit 2.
12. IF an agent run ends with a target move the moves log does not hold, THEN ship.sh MUST exit 4 (R8).
13. IF an agent run ends with the remotes or the hooks changed, THEN ship.sh MUST exit 4.

## Conformance
An implementation is conformant when it satisfies behaviors 1–24, holds the invariants, and follows failure rules 1–13. `@lab/race.sh` `MODE=ship` with a stub agent (0 violations at N = 10, 20 and 30 with dependent and duplicate work, `@measurements/REPORT.md` 2026-10-22 and 23), `@lab/recover.sh` R1, R1b–R1e, R5b, R8, R8b, R8c, R9, R10, R10b, R10c, R19g, R19j, R21–R21c, R22, `@lab/swarm.sh` (real agents, N = 10 and 20) and `@lab/replay.sh` (a real agent, 10 of 10 cases landed) exercise it.

Given a branch with committed work and a clean tree,
When the rebase stops on a conflict between two incompatible product behaviors,
Then the agent ends with OWNER DECISION NEEDED, the rebase stays open, and ship.sh exits 3.