---
title: "Architecture overview"
status: accepted
tags:
  - "architecture"
  - "architecture-overview"
---

4 modules; Bash + Python; Worktrunk (`wt merge`, hooks); lab stands as the test runner.

Layout: `@bin/` the product (merge.sh, ship.sh, lib.sh, and polyship, the per-machine command); `@install.sh` the one-line install and update per machine; `@.github/` the CI and the tag-driven release; `@example/` a runnable demo; `@lab/` the stands; `@measurements/` REPORT.md and the raw data per measurement day; `@.config/wt.toml` this repository's own pre-merge gate.

| Area | Type | Covers |
|---|---|---|
| Stack | rule | language, Worktrunk and git versions, stack-agnostic bin/, test runner |
| Running locally | guide | prerequisites / the gate / a race measurement / landing a change |
| Entry points | doc | the CLI scripts of bin/ and lab/, the hook-bound and subprocess entries |
| Configuration | doc | MERGE_* and SHIP_* names and purpose, the polyship -o arguments, the install inputs, the adopter's wt.toml hooks, lab inputs |
| Hotspot: merge.sh | spec | the locked merge contract: lock, tip record, moves log, exit codes 0/1/2/5, recovery R1–R10 |
| Hotspot: ship.sh | spec | the ship contract: review verdict, tests, merge rounds, fence, exit codes 0–5 |