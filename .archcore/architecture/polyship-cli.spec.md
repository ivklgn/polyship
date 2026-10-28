---
title: "polyship — the per-machine command and its configuration layers"
status: draft
tags:
  - "config"
  - "install"
  - "spec"
---

## Purpose & Scope

Normative for the `polyship` launcher (`@bin/polyship`) and the installer `@install.sh`: how polyship is installed and updated per machine, how a subcommand reaches `bin/ship.sh` and `bin/merge.sh`, and how settings are read from the environment, `git config` and an adopter's committed `.config/polyship.conf`. Dependents: agents and people in adopter repositories (they run `polyship ship`), the adopter instructions in `@INSTALL.md` and `@README.md`, and `@example/demo.sh`.

Not covered: the merge flow itself (`.archcore/architecture/merge-sh.spec.md`, `.archcore/architecture/ship-sh.spec.md`), Worktrunk hooks and approvals, and the polyship repository's own gate.

## Surface

- `polyship ship` — runs `bin/ship.sh` of the running version; exit codes are ship.sh's.
- `polyship merge [flags]` — runs `bin/merge.sh`; flags go to `wt merge`; exit codes are merge.sh's.
- `polyship self-update [<tag>]` — installs the newest `v*` tag, or `<tag>`, and makes it current.
- `polyship check` — runs `lab/recover.sh` with `BIN` set to the running version's `bin/`.
- `polyship version` — prints the running version: its tag, or `dev <short sha>` for a checkout.
- Install layout: `${XDG_DATA_HOME:-$HOME/.local/share}/polyship/<tag>/{bin,lab/recover.sh}`, the link `…/polyship/current` → `<tag>`, and `~/.local/bin/polyship` → `…/current/bin/polyship`.
- `POLYSHIP_REPO` — the git URL or path of polyship releases; default `https://github.com/ivklgn/polyship`.
- Settings — key, env variable it sets, allowed in `.config/polyship.conf`:

| Key | Env variable | In project file |
|---|---|---|
| `polyship.target` | `MERGE_TARGET` | yes |
| `polyship.push` | `MERGE_PUSH` | yes |
| `polyship.review` (bool) | `SHIP_REVIEW` (`0`/`1`) | yes |
| `polyship.reviewHow` | `SHIP_REVIEW_HOW` | yes |
| `polyship.rounds` | `SHIP_ROUNDS` | yes |
| `polyship.agent` | `SHIP_AGENT` | yes |
| `polyship.staleIndexLock` | `MERGE_STALE_INDEX_LOCK` | yes |
| `polyship.minVersion` | — | yes |
| `polyship.prepare` | `MERGE_PREPARE` | no |
| `polyship.test` | `SHIP_TEST` | no |

## Normative Behavior

1. WHEN a subcommand starts, the launcher MUST resolve its own path through every symlink and use that real version directory for the whole run.
2. WHEN `polyship ship` or `polyship merge` runs, the launcher MUST execute the script from the resolved version directory, never from `current`.
3. WHEN a setting is resolved, the launcher MUST take the first layer that defines it: env variable, `git config`, `.config/polyship.conf`, the script default.
4. The launcher MUST treat an env variable that is set to an empty string as defined.
5. WHEN the launcher reads `git config`, it MUST use git's own scope order (command, worktree, local, global, system).
6. WHEN the launcher reads `.config/polyship.conf`, it MUST read the file at the top level of the current worktree with `git config --file`.
7. WHEN a setting resolves to a value, the launcher MUST export it under its env variable before executing the script.
8. WHEN the current worktree's `polyship.minVersion` is higher than the running tag, the launcher MUST stop before executing any script.
9. WHILE the running version is a checkout (`dev`), the launcher MUST skip the minimum-version check.
10. WHEN `polyship self-update` runs, the launcher MUST list tags with `git ls-remote --tags` on `POLYSHIP_REPO` and pick the highest `vMAJOR.MINOR.PATCH`.
11. WHEN the chosen tag is not installed, the launcher MUST install it into a temporary directory and rename it to `<tag>`.
12. WHEN the new version directory is complete, the launcher MUST replace the `current` link with one `rename(2)`.
13. WHEN `@install.sh` runs, it MUST clone `POLYSHIP_REPO` and hand the install to the clone's `polyship self-update`.
14. IF `~/.local/bin` is not on `PATH`, THEN `@install.sh` MUST print the line that adds it.

## Constraints & Invariants

- The launcher MUST run on bash 3.2 and use only git, perl and the shell; `@install.sh` may also use `curl` only for its own download. Rationale: the stack rule, `.archcore/conventions/project-stack.rule.md`.
- The launcher MUST NOT write any file inside an adopter repository.
- `bin/merge.sh`, `bin/ship.sh` and `bin/lib.sh` MUST keep reading their settings from env variables only; the launcher is the only reader of `git config` and `.config/polyship.conf`.
- An installed `<tag>` directory MUST NOT change after its rename; `self-update` never deletes a version directory, because a running `ship.sh` may still use it.
- A committed `.config/polyship.conf` MUST NOT set a command: `polyship.prepare` and `polyship.test` come from env or `git config` only, as git-lfs limits `.lfsconfig`.

## Failure Behavior

1. IF the subcommand is missing or unknown, THEN the launcher MUST print the usage and exit 2.
2. IF `polyship ship` or `polyship merge` runs outside a git worktree, THEN the launcher MUST exit 2 with a message naming the directory.
3. IF `polyship.minVersion` is higher than the running tag, THEN the launcher MUST exit 2 with "polyship <min> is required, <tag> is installed; run polyship self-update".
4. IF `polyship.minVersion` is not `vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH`, THEN the launcher MUST exit 2 naming the value and the file.
5. IF `.config/polyship.conf` sets `polyship.prepare` or `polyship.test`, THEN the launcher MUST ignore the key and print one warning naming it.
6. IF `self-update` cannot list or fetch tags, THEN the launcher MUST exit 1 and leave `current` unchanged.
7. IF `POLYSHIP_REPO` has no `v*` tag, THEN `self-update` MUST exit 1 with a message naming the repository.
8. IF the requested `<tag>` does not exist, THEN `self-update` MUST exit 1 and leave `current` unchanged.
9. IF the launcher is interrupted during `self-update`, THEN the next `self-update` MUST NOT treat the leftover temporary directory as an installed version.

## Conformance

An implementation conforms when it satisfies every MUST in Normative Behavior, Constraints & Invariants and Failure Behavior. `@lab/polyship-checks.sh` (P1–P8) checks the launcher and the installer in a throwaway HOME. Also: `polyship check` reports no `FAIL` line and exits 0; an install into `HOME=$(mktemp -d)` from a local `POLYSHIP_REPO` with a tag gives a working `polyship version`; a project with `polyship.minVersion` above the installed tag exits 2.

```
Given .config/polyship.conf sets polyship.push = origin and the shell sets MERGE_PUSH=
When the agent runs polyship ship
Then ship.sh runs with MERGE_PUSH set to the empty string (no push)
```