# Contributing

Work in a worktree of this repository and land with `bin/merge.sh`: its own `pre-merge` gate
(`.config/wt.toml`) runs `lab/recover.sh`, `lab/lock.sh`, `lab/ship-checks.sh` and `lab/vendor-checks.sh`. A change to the merge flow also gets a run of
`lab/race.sh` (`RUNS=100 N=10`, modes `lock` and `ship`) and a line in [measurements/REPORT.md](measurements/REPORT.md);
a new failure shape gets a deterministic replay in `lab/recover.sh` before its fix. Then `bin/vendor.sh` into
each adopter and commit there.

Needs bash, perl, git ≥ 2.40 (`bin/` uses `rev-parse --path-format`, 2.31, and `merge-tree --merge-base`, 2.40) and
`wt` ≥ 0.80 (`brew install worktrunk`, `wt config shell install`); once per repository `wt config approvals add --yes`.

## Layout

| path | what it holds |
|---|---|
| `bin/` | the product: `merge.sh`, `ship.sh`, `lib.sh` (sourced by both, never run), `vendor.sh`. Nothing stack-specific: a project's stack lives in its own `.config/wt.toml` hooks |
| `lab/` | the stands: the regression guards `recover.sh`, `lock.sh`, `ship-checks.sh` and `vendor-checks.sh`; the measurements `race.sh`, `replay.sh`, `merge-race.sh`, `merge-batch.sh`; the lab's scripted agent `resolve.sh`; `summary.py` |
| `measurements/` | `REPORT.md` and, per measurement day, the raw data it is computed from; `lab/summary.py` reads the race files as they are (gzip included) |
| `.config/wt.toml` | this repository's own pre-merge gate |

## Lab

| stand | what it shows | run |
|---|---|---|
| `lab/race.sh` | N sessions with random overlapping edits, flaky and semantic test failures, random SIGKILLs; modes `bare` (plain `wt merge`), `lock` (`merge.sh`), `ship` (`ship.sh` with a stub agent); invariants after every run. A smoke and a measurement: it finds new failure shapes, it does not guard against old ones | `RUNS=100 N=10 MODE=ship OUT=/tmp/r.jsonl lab/race.sh` |
| `lab/summary.py` | per-mode numbers from the JSON lines | `python3 lab/summary.py /tmp/r.jsonl` |
| `lab/lock.sh` | the lock's failure points with a stub `wt` (T1-T6: two holders, a kill at start, a reused pid, signals, takeover time, a daemon that inherits the lock); a regression guard | `REPS=50 lab/lock.sh` |
| `lab/recover.sh` | the failures found under SIGKILL and in review (R1-R10 with R1b-R1e, R5b, R6b, R6c, R8b-R8e, R10b, R10c), deterministic, for `main`, `master` and `MERGE_TARGET`; the regression guard | `lab/recover.sh` |
| `lab/ship-checks.sh` | ship.sh's own decisions with a stub agent (S1-S9): refusals, review verdicts, the fence (exit 4), red tests, conflict rounds (exit 3), codex; a regression guard | `lab/ship-checks.sh` |
| `lab/kill-stress.sh` | one SIGKILL at a random moment of ship.sh, then the recovery its messages ask for, repeated (`REPS`); counts landed, lost and stuck sessions | `REPS=300 lab/kill-stress.sh` |
| `lab/vendor-checks.sh` | bin/vendor.sh on a committed copy (V1-V3): refusals, the header, the vendored recover.sh passing; a regression guard | `lab/vendor-checks.sh` |
| `lab/replay.sh` | a real human-resolved conflict of any repository, replayed through `ship.sh` with a real agent, diffed against the human | `lab/replay.sh <repo> <back-merge-sha>` |
| `lab/merge-race.sh` | six fixed scenarios (the original acceptance stand) | `lab/merge-race.sh` |
| `lab/merge-batch.sh` | model of a Bors-style batch queue against the serial lock | `N=8 SUITE_SLEEP=2 lab/merge-batch.sh` |
