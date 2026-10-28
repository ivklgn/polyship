---
title: "Land branches with a merge commit; publish the target with MERGE_PUSH"
status: draft
tags:
  - "architecture"
  - "merge"
---

## Context
Two gaps blocked many-agent use (2026-10-26).

- The gate tests the branch's tip, and `--no-squash` put every branch commit on the target's first-parent line. With real agents (`@lab/swarm.sh`, Sonnet, N = 10) 2 of 11 commits of main were red: a session's fix after exit 1, and a review fix commit (`@measurements/REPORT.md`, 2026-10-26).
- `wt merge` moves only the local target. bb, Claude Code and Codex worktrees start from `origin/<target>`, so every new session started from stale code (`@.archcore/architecture/known-limits.doc.md`).

## Decision
The owner chose (2026-10-26):

1. `@bin/merge.sh` calls `wt merge --no-squash --no-ff`: the rebased branch comes in under a merge commit whose tree the pre-merge hook tested. The moves log records a move when the merge's first parent is the target read before the merge and its second parent is the branch tip.
2. `MERGE_PUSH=<remote>` is opt-in. Under the lock merge.sh takes the remote's target, merges, and pushes. A merge counts only once the remote took it. A rejected push puts the target back and merges again on top. A local commit on the target that no merge.sh made is never published (exit 2).

## Alternatives
- Test every commit of the branch under the lock (`rebase --exec`): a linear, all-green history at N suite runs per branch of N commits. Rejected: the queue is the bottleneck.
- Squash with every message body kept in one commit: linear and green, one commit per task. Rejected: loses the per-commit intent the conflict agent reads.
- Keep the tip-only gate and record it as a limit. Rejected by the owner.
- A `[post-merge]` hook that pushes: the hook runs after the target moved, so a rejected push cannot put it back under the same lock.

## Consequences
- Every first-parent commit of the target is green (R20); `git bisect --first-parent` skips red commits inside branches. History is no longer linear.
- With `MERGE_PUSH`, exit 0 means the remote holds the merge (R19-R19h). The lock is per machine; two machines meet only through rejected pushes, up to 5 tries per merge.sh.
- A conflict agent may add commits of its own; the merge is still recorded (R8f). The earlier "no more commits than the branch brought" check failed on that and caused exit 4 for other sessions.
- Measured on the final bin/: `@lab/race.sh` N = 10, lock, ship and ship with push, and `@lab/swarm.sh` Sonnet N = 20 with push: 20 of 20 landed, origin equal to main (`@measurements/REPORT.md`, 2026-10-26).