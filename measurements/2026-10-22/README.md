# Raw data of the 2026-10-22 measurements

[REPORT.md](../REPORT.md), section "Capacity and dependent work", is computed from these files. Code: this
checkout at branch `capacity-deps` (bin/ unchanged from `main`).

| file | what | made by |
|---|---|---|
| `PLAN.md` | SLO thresholds and the expected outcome of each dependency form, written before the runs | by hand |
| `sessions.json` | the owner's own sessions since 2026-09-01: sessions open at once per minute, owner latency by other open sessions, task cycle | `python3 lab/sessions.py --since 2026-09-01 --json …` (aggregates only; the transcripts are private and stay in `~/.claude/projects`) |
| `suite/hotpot2.jsonl` | `pnpm test` of hotpot2, k = 1, 2, 4, 8 copies at once, 2 rounds each | `REPS=2 lab/suite-time.sh ../hotpot2 "pnpm install --frozen-lockfile --prefer-offline" "pnpm test" 1 2 4 8` |
| `suite/monorepo.jsonl` | `pnpm ts-check && pnpm test` of the private monorepo (its checkout was on branch NAV-4820), k = 1, 2, 4, 1 round | `lab/suite-time.sh` as above; rc 1 everywhere: one package (`middleware-migration-tests`) is red without polyship |
| `hotpot2-pairs.jsonl` | 279 commit pairs A→B at distance ≤ 6: chain, textual, clean, semantic; the real suite on B and on B-without-A | `python3 lab/pairs.py ../hotpot2 --suite "pnpm test" --clone <prepared clone>` |
| `swarm/s1..s3/` | 10 real `claude -p` sessions per run on the tasks of `lab/swarm/tasks.tsv`: `result.json`, `timeline.jsonl` (hidden acceptance per main commit), `events.jsonl`, `host.jsonl`, `sessions/*.json`, final sources, `main.diff` | `SUITE=12 START_WINDOW=60 lab/swarm.sh`; `lab/swarm/eval.sh` recomputes `result.json` |
| `race/H.{ship,lock}.jsonl` | `lab/race.sh` N = 10, 100 runs per mode, P_DEP=20 P_DUP=20, default faults, seeds 4000-4099 | `campaigns.sh H` |
| `race/H.retry.ship.jsonl` | the same with DEP_POLICY=retry (the stub never rebases), 30 runs | `campaigns.sh H.retry` |
| `race/Q.w{300,150,106}.jsonl` | the queue alone: N = 30, 2 s suite, no conflicts, no faults, 8 runs per window | `campaigns.sh Q` |
| `race/X.n{4,8,12,16,20}.jsonl` | conflicts on, faults off, WINDOW 30 s, 20 runs per N | `campaigns.sh X` (stopped once by a 2-hour task limit at N = 16 run 15; the cut run was dropped and the rest appended with seeds 6014-6019) |
| `fixes/` | before/after of the bin/ changes: `C{10,20,30}.ship.{before,after}`, `C10.lock.*` (JSON lines + logs), `*.superseded*` = after runs on an earlier bin/ (kept, not used), `swarm/` (real agents: a1, a2, b20, a20, f20), `PLAN.md`, `bin-after.sha` | `fixes/campaigns.sh` (C10 as listed; the after sides of C10.ship, C20, C30 were started by hand on the frozen copy, same arguments, `BIN=/tmp/bin-after`) |
| `capacity-predictions.txt` | `lab/queue.py predict` for hotpot2 and the monorepo | the commands at the top of each block |

Recompute:

```sh
python3 lab/summary.py measurements/2026-10-22/race/H.ship.jsonl
python3 lab/queue.py check measurements/2026-10-22/race/Q.w150.jsonl
lab/swarm/eval.sh <a kept swarm run dir>        # needs the run's lab; result.json here is its output
BIN=<bin/ at 08e7423> lab/recover.sh   # R6-R10 fail on the old bin/, pass on the current one
```

Lost and rerun: the first H and Q campaigns (16:20-17:40) wrote their JSON lines to a relative path inside each
throwaway lab, so the events were deleted with the labs; their 50 "refused" violations could not be told apart and
were not used. `campaigns.sh` now passes an absolute path; H and Q were rerun from scratch.
