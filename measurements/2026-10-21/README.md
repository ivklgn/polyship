# Raw data of the 2026-10-21 measurements

Everything [REPORT.md](../REPORT.md) states is computed from these files. "old" = the flow as taken from
hotpot2 at `b1bbcfc` (commit `56b6bc5` here), "new" = after the fixes (`0b4ea0c`).

## race/ — `lab/race.sh`, one JSON line per event

| file | flow | runs | settings |
|---|---|---|---|
| `A.bare` | `wt merge` without a lock | 100 | seeds 1000–1099, N=6, 15 % killed |
| `A.lock`, `A.ship` | old | 85, 100 | as above; an earlier stand version (no orphan labels). Source of R1 (ship seed 1016) and R2 (lock seed 1003). `A.lock` stopped at 85 runs (time limit) |
| `D.old.*`, `D.new.*` | old, new | 100 each | seeds 1000–1099, N=6, 15 % killed, same stand for both (`BIN=`) |
| `E.old.*`, `E.new.*` | old, new | 40 each | seeds 2000–2039, N=6, 50 % killed |
| `F.pre.*` | `091976c` | 43 lock, 51 ship complete | seeds 3000–, N=10; stopped to fix R5 (ship seed 3017). Ship seed 3047's timeout was caused by the operator (`pkill sleep` killed the stand's deadline timer): ignore it |
| `G.new.*` | final (`45941e8`) | 100 each | seeds 3000–3099, N=10, 15 % killed; run ids `<mode>-<seed>-<pid>` |

Recompute the tables:

```sh
python3 lab/summary.py measurements/2026-10-21/race/D.new.lock.jsonl.gz
python3 lab/summary.py measurements/2026-10-21/race/E.old.lock.jsonl.gz     # the 3 stuck sessions, seed 2039
zcat < measurements/2026-10-21/race/A.ship.jsonl.gz | grep '"ev":"violation"'   # the 2 lost edits, seed 1016
```

Rerun one plan: `BIN=<bin dir> RUNS=1 SEED=<seed> N=6 MODE=<lock|ship> P_KILL=<15|50> lab/race.sh`. The seed
fixes who edits what, who flakes and when each kill fires; the OS scheduler still decides the interleaving,
so a rare failure may need many seeds. Campaigns B and C (not here) were paused by a laptop sleep.

## lock/ — `lab/lock.sh`

- `new-flock.txt`: the flock lock before `lib.sh` existed, every check, 50 reps; T1 with 20 waiters, 40 reps.
- `new-flock-recheck-with-lib.txt`: the same with the current `merge.sh` + `lib.sh` and the fixed stand (2026-10-22).
- `old-mkdir-T1-W20-T2-and-new-T2.txt`: the mkdir lock T1 with 20 waiters (8/40 two holders), T2 300 reps
  (1 hang); then the flock lock T2 300 reps: **void**, `merge.sh` could not source `lib.sh` there (see REPORT.md, correction).
- `old-mkdir-rerun-2026-10-22.txt`: the mkdir lock (`56b6bc5`), every check, 10 reps, with the fixed stand: T3 10/10
  hang, T5 p50 1.73 s, T1 1/10 over the time limit (2 s polling). Replaces the first run, whose output was not kept.
- `final-45941e8.txt`: the final lock, every check 30 reps, T6, T1 with 20 waiters 40 reps, T2 300 reps.

## evidence/ — what the failed runs left in git

- `R1-lost-commit-seed1016.txt`: reflog of branch `s5`: `rebase (start): checkout main`, then
  `rebase (finish)` with no pick; the session's `ship.sh` printed "already on main".
- `R2-stuck-main-checkout-seed1003.txt`: the main checkout's index at the previous main, and the
  "conflicting uncommitted changes" refusals that followed.
- `R5-stale-index-lock-seed3017.txt`: the session's output after its rebase was SIGKILLed: "index.lock: File exists"
  on every later merge.

## replay/ — `lab/replay.sh` on 10 real conflicts

Not published: the cases came from a private monorepo (file paths, commit subjects, agent logs). The
aggregate results and the judgment of the four differing cases are in REPORT.md.
