---
title: "Move polyship to a per-machine install; adopters keep only configuration"
status: draft
tags:
  - "config"
  - "install"
  - "process"
---

## Goal

Replace vendoring with the per-machine install recorded in the ADR, implement the `polyship` command as the spec states it, and move lifecore-app, the only adopter, to configuration only.

## Tasks

### Phase 1 — the command and the installer

1. Add the launcher with the subcommands, layers and checks of the spec. @bin/polyship
2. Rewrite the installer to fetch the newest tag and run its `self-update`. @install.sh
3. Delete the vendoring script. @bin/vendor.sh
4. Add a lab stand for the launcher: layers, empty env, minVersion, self-update from a local tagged repo, interrupted install. @lab/polyship-checks.sh
5. Add the stand to this repository's gate. @.config/wt.toml
6. Land the change with `bin/merge.sh`, then tag `v0.1.0` on `main`. @bin/merge.sh

### Phase 2 — adopter instructions

7. Rewrite steps 4 to 9: install command, `.config/polyship.conf`, `polyship ship` in the Shipping block, smoke via `polyship ship`; drop the alias step and the `scripts/` commit. @INSTALL.md
8. Replace `scripts/ship.sh`, the copy wording and the env table with the command and the key table. @README.md
9. Run the demo through `PATH="$HERE/bin:$PATH" polyship ship`, without copying scripts. @example/demo.sh @example/README.md
10. Check the contributor notes for vendoring wording and update them. @CONTRIBUTING.md

### Phase 3 — canon

11. Run `/archcore:document` to amend the documents listed under Declared Delta.

### Phase 4 — lifecore-app

12. Install polyship on this machine with the new installer.
13. Remove `scripts/`, change the Shipping block to `polyship ship`, add `.config/polyship.conf` with `polyship.minVersion`, and commit. No target found in this repository; the files are lifecore-app's `scripts/`, `CLAUDE.md`, `AGENTS.md`.
14. Run the smoke of `@INSTALL.md` step 9 in lifecore-app with `polyship ship`.

## Acceptance Criteria

- An install into `HOME=$(mktemp -d)` with one command from `@README.md` gives a working `polyship version`.
- `polyship check` on the installed copy prints no `FAIL` line and exits 0.
- In lifecore-app, `git ls-files` lists no polyship script, and the step 9 smoke prints `exit 0`.
- A project whose `polyship.minVersion` is above the installed tag gets exit 2 and the upgrade hint.
- `@lab/polyship-checks.sh` passes inside the `pre-merge` gate of `@.config/wt.toml`.
- `grep -rn 'scripts/ship.sh' README.md INSTALL.md example/` finds nothing.

## Dependencies

- The default install reads tags from `https://github.com/ivklgn/polyship`: task 12 needs `v0.1.0` pushed there, which is the owner's step; before that, `POLYSHIP_REPO=<local checkout>` installs from this checkout.
- Worktrunk `wt` ≥ 0.80, git ≥ 2.40 and perl on every machine that ships (`.archcore/conventions/project-stack.rule.md`).
- `@lab/swarm.sh` keeps copying the scripts into its throwaway repository, so its runs stay comparable with `@measurements/REPORT.md` [assumption].

## Declared Delta

- create research `research/how-dev-tools-install-and-configure` — the comparison behind the decision
- create adr `architecture/install-once-per-machine-config-only-adopters`
- create spec `architecture/polyship-cli`
- create plan `plans/global-install`
- amend rule `conventions/changing-the-merge-flow` — clause 5: tag a release instead of vendoring into each adopter
- amend rule `conventions/repository-layout` — Rationale and Enforcement name `bin/vendor.sh`
- amend doc `architecture/entry-points` — drop `bin/vendor.sh`, describe `bin/polyship` and the new `install.sh`
- amend doc `architecture/architecture-overview` — Layout line
- amend doc `architecture/configuration` — the `polyship.*` keys and their layers
- none spec `architecture/ship-sh`, `architecture/merge-sh` — the scripts keep reading env only

## Clarifications

- Distribution: the owner chose `install.sh` into `~/.local` over a Homebrew tap (2026-10-28).
- Settings place: the owner first chose "a section in `.config/wt.toml`", then asked for the canonical design of comparable tools. Research found that wt 0.80.0 warns about every foreign table and that no studied tool keeps its settings in another tool's file, so the design uses `.config/polyship.conf`. This departs from the first answer and needs the owner's confirmation.
- Command name: the owner did not choose between `wt ship` and `polyship ship`; the design uses `polyship ship`, the pattern of every studied tool [assumption].
- Self-check on update: the owner did not choose; `self-update` runs no tests, as `mise self-update` and `lefthook self-update` run none, and the gate runs before each tag instead [assumption]; `polyship check` stays available.