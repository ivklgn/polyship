---
title: "Install polyship once per machine; an adopter commits only configuration"
status: draft
tags:
  - "architecture"
  - "config"
  - "install"
---

## Context

`@install.sh` and `@bin/vendor.sh` copy `merge.sh`, `ship.sh`, `lib.sh` and `lab/recover.sh` into every adopter: in lifecore-app the adoption commit 3171938 added 1080 lines of polyship code under `scripts/`, and every polyship change reaches an adopter only through a new vendoring commit there (`.archcore/conventions/changing-the-merge-flow.rule.md`, clause 5). The copy does not make an adopter self-sufficient, because Worktrunk `wt` must be installed on every machine anyway (`@INSTALL.md`, step 1). Per-project settings (`MERGE_PUSH`, `SHIP_REVIEW_HOW`, `MERGE_PREPARE`) have no file of their own; `@INSTALL.md` step 6 puts them into task-runner aliases, and lifecore-app has no task runner. The comparison of eight tools in the linked research shows one common pattern: a per-machine command, a self-update command, one committed project file owned by the tool, and a project-declared minimum version.

## Decision

Install polyship per machine with `@install.sh` into `${XDG_DATA_HOME:-~/.local/share}/polyship/<tag>/`, behind a `current` link and the `polyship` command in `~/.local/bin`, updated by `polyship self-update` to the newest `v*` tag; an adopter commits only `.config/polyship.conf` in git-config syntax, its hooks in `.config/wt.toml`, and the Shipping block in `CLAUDE.md`/`AGENTS.md`.

## Alternatives Considered

1. Keep vendoring into `scripts/` (polyship bddc77d) — rejected because each adopter carries about 1080 lines of copied code and each polyship change costs one commit per adopter.
2. A Homebrew tap formula — deferred because it needs a separate tap repository and release automation; it can install the same `<tag>` layout later.
3. Settings inside `.config/wt.toml`, as a `[polyship]` table or as `[aliases] ship = "MERGE_PUSH=origin polyship ship"` — rejected because wt 0.80.0 warns about an unknown table on every command, and an alias needs a new approval after every edit of its text (measured 2026-10-28).
4. A TOML or YAML `.config/polyship.toml` — rejected because bash 3.2 has no parser for it, while `git config --file` reads git-config syntax with the git polyship already requires, as git-lfs reads `.lfsconfig`.
5. A git submodule with the scripts — rejected because every new worktree needs `git submodule update --init`, and polyship creates one worktree per task.
6. Track the tip of `main` instead of tags — rejected because a minimum version needs an order between versions, and a tag marks a commit that passed the polyship gate.

## Consequences

Positive:

- An adopter holds no polyship code: lifecore-app drops 1080 lines under `scripts/` and keeps two config files and one instruction block.
- One `polyship self-update` moves every repository on the machine to the new version, instead of one vendoring commit per adopter.
- An agent ends every task with the same command, `polyship ship`, and the project's settings apply without an alias or an env prefix.
- A project's `polyship.minVersion` stops an older install with an upgrade hint, as lefthook, mise and pre-commit do.

Negative:

- Every machine and sandbox that ships needs the install; a cloud agent without it cannot run `polyship ship` [expected].
- All repositories on a machine change version at the same moment, so a regression in `bin/` reaches all of them; the polyship `pre-merge` gate (`@.config/wt.toml`) is the only guard before a tag.
- A release now needs a `v*` tag, a step the maintainer did not have before.
- `.config/polyship.conf` cannot set a command (`MERGE_PREPARE`, `SHIP_TEST`), as git-lfs limits `.lfsconfig` to a fixed key set; a project puts its install step into its `[pre-merge]` hook instead, which wt approves.

## Superseded when

- An adopter must ship from a sandbox where installing polyship is impossible (for example a hosted agent with no shell setup step).
- Two repositories on one machine need versions that one install cannot serve, that is, a maximum version, not only a minimum.
- Worktrunk supports third-party project settings or plugins that carry scripts.