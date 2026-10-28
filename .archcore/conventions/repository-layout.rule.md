---
title: "Repository layout: bin/, lab/, measurements/"
status: draft
tags:
  - "conventions"
  - "layout"
---

## Rule
1. The contributor MUST NOT put a stack-specific command (an install, a test runner) in `bin/`; an adopter's commands live in its own `.config/wt.toml` hooks.
2. WHEN a stand or a lab helper is added, the contributor MUST place it in `lab/`, not in `bin/`.
3. WHEN a measurement is published, the contributor MUST put its raw data under `measurements/<date>/` with a README, and its line in `measurements/REPORT.md`.
4. `bin/lib.sh` MUST stay a file that `merge.sh` and `ship.sh` source, never an executable entry point.

## Rationale
`@bin/polyship` runs `bin/merge.sh`, `bin/ship.sh` and `bin/lib.sh` as they are in every adopter on the machine, so a stack-specific line in `bin/` would reach repositories of another stack. The project-side contract is the pair of hooks `[post-start]` and `[pre-merge]` in the adopter's `.config/wt.toml`. Every number in `@measurements/REPORT.md` is computed from the raw files under `@measurements/2026-10-21/`, so a report line without its data cannot be re-checked.

## Examples
### Good
```
bin/merge.sh                       # stack-agnostic: wt merge, flock, git
lab/race.sh                        # a stand
measurements/2026-10-21/race/*.jsonl.gz   # raw data; the line in measurements/REPORT.md
```
### Bad
```sh
# bin/merge.sh
pnpm install --frozen-lockfile     # an adopter's install command inside the shared script
```

## Enforcement
Manual review; a release tag ships `bin/` to every adopter without a check of its own.