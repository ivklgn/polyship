---
title: "Running the project locally"
status: accepted
tags:
  - "onboarding"
---

Reader: a contributor changing the scripts or the lab; the reader runs every step. Source: `@CONTRIBUTING.md`.

## Prerequisites

- bash, perl, git ≥ 2.40 (`bin/`: `rev-parse --path-format` since 2.31, `merge-tree --merge-base` since 2.40), Worktrunk `wt` ≥ 0.80 (`brew install worktrunk`, `wt config shell install`)
- once per repository: `wt config approvals add --yes`

## Test

```sh
lab/recover.sh
REPS=5 lab/lock.sh
```

## Measure a change to the merge flow

```sh
RUNS=100 N=10 MODE=lock OUT=/tmp/r.jsonl lab/race.sh
RUNS=100 N=10 MODE=ship OUT=/tmp/r.jsonl lab/race.sh
python3 lab/summary.py /tmp/r.jsonl
```

## Land

```sh
bin/merge.sh    # from a worktree; the pre-merge hook runs the two tests above
```