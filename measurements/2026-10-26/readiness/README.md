# Readiness for many agents, 2026-10-26 and 27

Raw data of the section "2026-10-26: readiness for many agents" in [../../REPORT.md](../../REPORT.md).

| path | what | bin/ |
|---|---|---|
| `race/lock.jsonl.gz`, `race/ship.jsonl.gz`, `race/ship-push.jsonl.gz` | `lab/race.sh` RUNS=100 N=10 SEED=261026, MODE=lock, ship, ship with PUSH=1; `python3 lab/summary.py <file>` gives the table rows | final |
| `swarm/s-review-med/` | `lab/swarm.sh` Sonnet, effort medium, N = 10, review on | before push and `--no-ff` |
| `swarm/codex-luna-low/` | Codex gpt-6-luna, effort low, sessions in the workspace-write sandbox: no session could commit | before R22 |
| `swarm/codex-luna-low-2/` | the same, sessions without the sandbox | with R22 |
| `swarm/s20-push-med/` | Sonnet medium, N = 20 (CLUSTERS=2), review, SWARM_PUSH=1 | before R8f, R19h |
| `swarm/s20-push-low/` | Sonnet low, N = 20, review, SWARM_PUSH=1 | with R8f, R19h; before R12b, R19i |
| `kill-stress-300.log` | `REPS=300 lab/kill-stress.sh` | final |
| `lock-loop-50.txt` | `REPS=5 lab/lock.sh`, 50 times in a row | main `e5bd690` |
| `linux-final.log` | the gate and `lab/race.sh` 20 runs per mode in Docker | final |
| `linux-gate.log`, `linux-race.log`, `linux.Dockerfile` | the gate and `lab/race.sh` (20 runs per mode) in Docker: Debian trixie, bash 5.2, git 2.47, wt 0.80 (aarch64 musl release, sha256 checked) | before R8f, R19h |

A swarm directory holds `result.json` (from `lab/swarm/eval.sh`), `events.jsonl.gz` (ship and merge events),
`timeline.jsonl` (the hidden acceptance tests on every first-parent commit of main) and `sessions/<task>.json` (the
session's final answer). Codex sessions report no cost.
