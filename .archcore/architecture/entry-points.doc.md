---
title: "Entry-point inventory"
status: accepted
tags:
  - "architecture"
  - "entry-points"
---

Every entry point is a shell command run from a git worktree. `@bin/lib.sh` is sourced by merge.sh and ship.sh, never run.

## CLI
- `@bin/ship.sh` — CLI. The tail of a task: agent review, tests, merge.sh, conflict rounds; exit 0 means the branch is on the target.
- `@bin/merge.sh` — CLI. The locked merge of the current branch into the target; arguments go to `wt merge` as flags.
- `@bin/polyship` — CLI. The per-machine command: `ship`, `merge`, `config`, `check`, `--version`; turns `-o KEY=VALUE` into env and runs ship.sh or merge.sh of its own version directory (`.archcore/architecture/polyship-cli.spec.md`).
- `@install.sh` — CLI. `curl … | sh` once per machine and again to update: downloads `polyship.tar.gz` of a release, verifies its sha256, unpacks it into a version directory and links `~/.local/bin/polyship`; writes nothing into a repository (`.archcore/architecture/polyship-release.spec.md`).
- `@.github/scripts/package.sh` — CLI. `package.sh vX.Y.Z <dir>`: the release assets `polyship.tar.gz` and `checksums.txt`.
- `@example/demo.sh` — CLI. Three scripted sessions ship at once into a throwaway repository under /tmp; no agent.
- `@lab/race.sh` — CLI. Randomized N-session merge race, `MODE=bare|lock|ship`; one JSON line per event to `OUT`.
- `@lab/summary.py` — CLI. Per-mode numbers from the race JSON lines (gzip read as is).
- `@lab/lock.sh` — CLI. Lock checks T1–T6 against a stub `wt`; a regression guard.
- `@lab/polyship-checks.sh` — CLI. Checks P1–P8 of package.sh, install.sh and bin/polyship in a throwaway HOME; a regression guard.
- `@lab/recover.sh` — CLI. Deterministic replays R1–R10 (with R1b–R1d, R5b, R6c, R8b, R8c, R10b, R10c) for `main`, `master` and `MERGE_TARGET`; a regression guard.
- `@lab/replay.sh` — CLI. `replay.sh <repo> <back-merge-sha>`: one real conflict through ship.sh with a real agent.
- `@lab/merge-race.sh` — CLI. Six fixed scenarios on a throwaway repository; the original acceptance stand.
- `@lab/merge-batch.sh` — CLI. A model of a Bors-style batch queue against the serial lock.
- `@lab/resolve.sh` — CLI. The lab's scripted agent: finishes an open rebase keeping both sides; names a commit a conflict left empty in `merge-dropped`.
- `@lab/swarm.sh` — CLI. N real `claude -p` sessions on coupled tasks (`@lab/swarm/tasks.tsv`), judged by hidden acceptance tests; `@lab/swarm/eval.sh` recomputes a run.
- `@lab/kill-stress.sh` — CLI. One SIGKILL at a random moment of ship.sh, then the recovery its messages ask for; counts landed, lost and stuck sessions.
- `@lab/suite-time.sh` — CLI. An adopter's real suite timed alone and k at once.
- `@lab/sessions.py` — CLI. The owner's Claude Code transcripts: sessions open at once, owner latency, task rhythm (aggregates only).
- `@lab/pairs.py` — CLI. Commit pairs of a real history: chain, textual, clean, semantic dependency.
- `@lab/queue.py` — CLI. `check`: the lock against a single-server queue; `predict`: capacity for a suite time and task rhythm, with what-ifs.
- `@lab/xfit.py`, `@lab/pareto.py`, `@lab/compare.py` — CLI. Model inputs from a campaign; where its time and suite runs go; before/after with bootstrap intervals.

## Other
- `@.config/wt.toml` `[pre-merge]` — hook. Worktrunk runs `lab/recover.sh`, `REPS=5 lab/lock.sh`, `lab/ship-checks.sh` and `lab/polyship-checks.sh` on every `bin/merge.sh` of this repository.
- `@.github/workflows/ci.yml` — CI. The same four checks on macOS and Linux, on a push to `main`, a pull request, and before a release.
- `@.github/workflows/release.yml` — CI. A pushed `vX.Y.Z` tag: the tag check, `ci.yml`, then `package.sh` and the GitHub Release.
- `@bin/ship.sh` → `claude -p` or `codex exec` — subprocess. The agent for the review and each conflict round; `wt hook pre-merge --yes` — subprocess. The adopter's tests.