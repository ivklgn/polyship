---
title: "Distribute and configure polyship as polybrief is: release archive, installer, arguments only"
status: draft
tags:
  - "architecture"
  - "config"
  - "install"
---

## Context

`@install.sh` and `@bin/vendor.sh` copied `merge.sh`, `ship.sh`, `lib.sh` and `lab/recover.sh` into every adopter: in lifecore-app the adoption commit 3171938 added 1080 lines under `scripts/`, and every polyship change reached an adopter only through a vendoring commit there. A first per-machine design (commits 3cce83b, afeb901) installed from a git clone, updated with `polyship self-update` and read settings from env, `git config` and a committed `.config/polyship.conf`; it read that file from the branch being shipped, so a branch could set `review = false` for itself. The owner's other tool, polybrief, already settled the same questions in accepted decisions (`release-distribution.adr` and `arguments-only-runtime.adr` in that repository): a tag publishes a GitHub Release with archives and `checksums.txt`, `install.sh` verifies the sha256 and places the command, and settings are `-o KEY=VALUE` arguments with no settings file. The owner asked on 2026-10-28 to use one approach for both tools and to keep polyship in Bash.

## Decision

A pushed `vMAJOR.MINOR.PATCH` tag runs `@.github/workflows/release.yml`, which runs the checks of `@.github/workflows/ci.yml` and publishes `polyship.tar.gz` with `checksums.txt`; `@install.sh` verifies the sha256 and unpacks the release into `${XDG_DATA_HOME:-~/.local/share}/polyship/<version>/` behind the link `~/.local/bin/polyship`, and `@bin/polyship` takes its settings only as `-o KEY=VALUE` arguments, so an adopter keeps `.config/wt.toml` and the Shipping block that names the command with its arguments.

## Alternatives Considered

1. Keep vendoring into `scripts/` (polyship bddc77d) — rejected because each adopter carries about 1080 lines of copied code and each change costs one commit per adopter.
2. Keep the first per-machine design: git-clone install, `polyship self-update`, settings from env, `git config` and `.config/polyship.conf` — rejected because it differs from polybrief on every point, and its committed file is read from the branch being shipped, the risk polybrief rejected in `polybrief-home.adr` alternative 2.
3. Rewrite polyship in Go and release it with GoReleaser like polybrief — rejected on 2026-10-28 because the merge flow's guarantees are measured on the Bash code (`@measurements/REPORT.md`), and its known failures are git states under kills and races (`@lab/recover.sh`), which a port keeps.
4. One file on PATH, as polybrief's binary — rejected because `ship.sh` runs for minutes and starts `merge.sh` from disk later, so replacing files in place could mix two versions inside one run; a directory per version never changes once installed.
5. A Homebrew tap — deferred, as in polybrief, because it needs a second repository and a token with write access.

## Consequences

Positive:

- polyship and polybrief install, update, pin a version and report their settings the same way: `curl … install.sh | sh`, `POLY*_VERSION`, `-o KEY=VALUE`, `config`, `--version`.
- An adopter holds no polyship code: lifecore-app drops 1080 lines under `scripts/`.
- A branch cannot change its own ship settings through a file; the settings are in the command the session runs.
- A download is checked against the release's sha256 before anything is installed.

Negative:

- Every machine that ships needs the install; a cloud agent without it cannot run `polyship ship` [expected].
- All repositories on a machine change version at once; the checks before each release are the only guard.
- A repository's settings live in the text of its agent instructions: a person who types `polyship ship` without `-o push=origin` merges locally only. The next run with `-o push=origin` publishes that recorded merge; if the remote moved in between, `merge.sh` stops with exit 2 (the two diverged, `@bin/merge.sh` `sync_remote`). Until then new sessions start from the older remote target.
- No project-declared minimum version: polybrief has none either.
- Updating is running `install.sh` again; nothing reminds a user that a newer release exists (polybrief stayed at 0.0.3 while 0.1.0 was out, seen 2026-10-28).

## Superseded when

- polyship must ship from a sandbox where installing it is impossible.
- polybrief changes its distribution or configuration decision: both tools follow one approach.
- Bash defects of the kind polybrief's `go-runtime.adr` lists start to appear in `bin/`, which reopens alternative 3.