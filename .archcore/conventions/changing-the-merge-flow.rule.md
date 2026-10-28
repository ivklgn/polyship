---
title: "Changing the merge flow: gate, race run, replay, release tag"
status: draft
tags:
  - "conventions"
  - "process"
---

## Rule
1. WHEN a change touches `bin/` or `lab/`, the contributor MUST land it with `bin/merge.sh` from a worktree of this repository.
2. WHEN a change alters the merge flow in `@bin/merge.sh`, `@bin/ship.sh` or `@bin/lib.sh`, the contributor MUST run `lab/race.sh` with `RUNS=100 N=10` in modes `lock` and `ship`.
3. WHEN that race run is done, the contributor MUST add its line to `@measurements/REPORT.md`.
4. WHEN a new failure shape is found, the contributor MUST add a deterministic replay to `@lab/recover.sh` before the fix lands.
5. WHEN a landed change to `bin/` is meant for adopters, the maintainer MUST tag `main` with the next `vMAJOR.MINOR.PATCH`.

## Rationale
The `pre-merge` gate in `@.config/wt.toml` runs the deterministic checks (`lab/recover.sh`, `REPS=5 lab/lock.sh`, `lab/ship-checks.sh`, `lab/polyship-checks.sh`) only when the change goes through `bin/merge.sh`. `lab/race.sh` finds new failure shapes and does not guard against old ones, so every known shape lives as a replay in `lab/recover.sh`. Adopters run the version installed on their machine (`@bin/polyship`), and `polyship self-update` installs the newest tag, so a change here reaches them only through a tag on a commit that passed the gate.

## Examples
### Good
```sh
wt switch --create fix-index-lock
# edit bin/merge.sh; add R6 to lab/recover.sh first, see it fail, then fix
RUNS=100 N=10 MODE=lock OUT=/tmp/r.jsonl lab/race.sh && RUNS=100 N=10 MODE=ship OUT=/tmp/r.jsonl lab/race.sh
python3 lab/summary.py /tmp/r.jsonl      # the line for measurements/REPORT.md
git commit -am "fix(merge): …"; bin/merge.sh
git tag v0.2.0 main                       # adopters: polyship self-update
```
### Bad
```sh
# on main, no worktree: the gate never runs
git commit -am "fix(merge): …"
# no race run, no REPORT line, no replay in lab/recover.sh; no tag, so adopters keep the old version
```

## Enforcement
Clause 1: the `pre-merge` hook in `@.config/wt.toml` (runs the four checks above on every `bin/merge.sh`). Clauses 2–5: manual review.