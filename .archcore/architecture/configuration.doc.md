---
title: "Configuration & environment surface"
status: accepted
tags:
  - "architecture"
  - "config"
---

Source: the variable table in `@README.md` and the headers of `@bin/lib.sh`, `@bin/merge.sh`, `@bin/ship.sh`; the project-side contract is the Worktrunk hook config `.config/wt.toml` of the adopter. Names and purpose only.

## Merge (bin/merge.sh, bin/lib.sh)
- MERGE_TARGET — the branch every session merges into; default from `wt config state default-branch`
- MERGE_PUSH — a remote: under the lock take its target before each merge, push each merge, land only what it took; unset means local only
- MERGE_PREPARE — `sh -c` command run under the lock before the merge, for worktrees that skipped `post-start`
- MERGE_STALE_INDEX_LOCK — seconds after which an `index.lock`, the target's ref lock, `packed-refs.lock` or an open rebase's branch ref lock counts as left by a killed git command (default 60, `@bin/merge.sh`, `@bin/ship.sh`)
- MERGE_EVENTS — file that receives JSON lines of lab events; unset outside the lab

## Ship (bin/ship.sh)
- SHIP_TEST — the test command before the queue; default `wt hook pre-merge --yes`
- SHIP_AGENT — `claude` or `codex`, the agent for review and conflicts
- SHIP_REVIEW — `0` skips the review step
- SHIP_REVIEW_HOW — how the agent reviews, appended to the review prompt; default `for correctness, the task in the commit messages, tests`; a review skill can be named here
- SHIP_ROUNDS — merge rounds per ship.sh run; default 10
- SHIP_AGENT_RUN — set by ship.sh for its agent runs to this repository's git common dir; merge.sh refuses to run in that repository

## Settings layers (bin/polyship)
`@bin/polyship` sets each variable above from the first layer that defines it: the env variable (an empty value counts), `git config polyship.<key>` in git's own scope order, the worktree's committed `.config/polyship.conf` (git-config syntax), the script default. Keys: target → MERGE_TARGET, push → MERGE_PUSH, review (bool) → SHIP_REVIEW, reviewHow → SHIP_REVIEW_HOW, rounds → SHIP_ROUNDS, agent → SHIP_AGENT, staleIndexLock → MERGE_STALE_INDEX_LOCK, prepare → MERGE_PREPARE, test → SHIP_TEST; minVersion sets no variable. The committed file cannot set prepare or test. Contract: `.archcore/architecture/polyship-cli.spec.md`.
- POLYSHIP_REPO — where `install.sh` and `polyship self-update` read releases (`v*` tags); default the GitHub URL
- XDG_DATA_HOME — the install root, `polyship/<tag>/` and the `current` link under it; default `~/.local/share`

## Worktrunk hooks (the adopter's `.config/wt.toml`)
- `[post-start]` — commands that prepare a new worktree (dependency install)
- `[pre-merge]` — the gate run on the rebased tree under the lock, before the merge commit

## Lab inputs
- RUNS, N, MODE, SEED, OUT, FILES, EDITS, LINES, P_DEP, P_DUP, DEP_POLICY, DEP_WAIT (`@lab/race.sh`); PUSH (`@lab/race.sh`); SUITE, START_WINDOW, CAP, CLUSTERS, BIN, SHIP_AGENT_MODEL, SHIP_AGENT_EFFORT, SWARM_AGENT, SWARM_REVIEW, SWARM_PUSH (`@lab/swarm.sh`); REPS, LAB (`@lab/suite-time.sh`); REPS, W, MERGE_SH (`@lab/lock.sh`); BIN (`@lab/recover.sh`); N, SUITE_SLEEP, BAD (`@lab/merge-batch.sh`); HOME, POLYSHIP_REPO (`@lab/polyship-checks.sh`, both set to throwaway paths)