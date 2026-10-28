---
title: "Project stack"
status: accepted
tags:
  - "conventions"
  - "stack"
---

Code in Bash compatible with bash 3.2 (the macOS default), with Perl one-liners for `flock(2)` and file times; `@lab/summary.py` in Python 3.
Build on Worktrunk (`wt` ≥ 0.80, `@README.md`, 2026-10-22) and git ≥ 2.40 (`@bin/merge.sh`, `@bin/ship.sh`, `@bin/lib.sh` use `rev-parse --path-format` and `merge-tree --merge-base`; `@lab/replay.sh` needs 2.38); do not introduce another worktree or merge tool without an ADR.
Test with the lab stands as the primary runner: `@lab/recover.sh` and `@lab/lock.sh`, run by the `pre-merge` hook in `@.config/wt.toml`.