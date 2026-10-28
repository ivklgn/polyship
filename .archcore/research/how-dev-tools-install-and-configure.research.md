---
title: "How developer tools install, update and read project configuration"
status: draft
tags:
  - "config"
  - "install"
  - "source:primary"
---

## Goal

Find the common way established developer tools are installed once per machine, updated, and configured per project, so that polyship's global install follows precedent instead of inventing a scheme. The decision this serves: how polyship stops copying `bin/` into adopters (`@bin/vendor.sh`, `@install.sh`) and where an adopter keeps its settings.

## Scope

In scope: pre-commit, lefthook, mise, direnv, GitHub CLI extensions, git custom subcommands and `git config` (with git-lfs `.lfsconfig` and git-absorb as git-tool precedents), Worktrunk `wt` v0.80.0, Mergify. Dimensions: install, update, project config file and format, personal override, user config, precedence, project-declared minimum version, trust for repo-supplied commands, env passing, invocation.

Out of scope: Windows install paths, release signing, CI caching, bors-ng.

Method: official documentation and source code read on 2026-10-28; Worktrunk and git also checked by experiment in throwaway repositories under /tmp; every cell carries its source, and a cell without one reads "not found".

## Coverage

| Dimension | Covered for | Gap |
|---|---|---|
| Install / update | all eight | Worktrunk install docs not read (local binary is Homebrew's) |
| Project config | all eight | direnv: whether `.envrc` is committed not stated |
| Personal override | lefthook, mise, git | pre-commit, direnv: none |
| Precedence | lefthook, mise, git, Worktrunk | pre-commit, direnv: not documented |
| Minimum version | all eight | exit codes of pre-commit, mise, direnv not found |
| Trust | all eight | — |

## Sources

- pre-commit: https://pre-commit.com/ (#installation, #top_level-minimum_pre_commit_version), `pre_commit/clientlib.py` — accessed 2026-10-28
- lefthook: https://lefthook.dev/configuration/ , /configuration/extends/ , /examples/lefthook-local/ ; `internal/command/run.go` `checkVersion`; `docs/usage/commands/self-update.md` — accessed 2026-10-28
- mise: https://mise.jdx.dev/installing-mise.html , /configuration.html (#minimum-mise-version, #configuration-hierarchy), /cli/trust.html , /directories.html — accessed 2026-10-28
- direnv: https://direnv.net/man/direnv.1.html , /man/direnv-stdlib.1.html , /man/direnv.toml.1.html — accessed 2026-10-28
- gh: `gh extension install|upgrade --help` (gh 2.83.1); cli/cli `pkg/cmd/extension/manager.go`, `command.go` — accessed 2026-10-28
- git: `man git-config` (FILES, SCOPES, Includes), `man gitrepository-layout`; git-lfs `docs/man/git-lfs-config.adoc`; git-absorb `Documentation/git-absorb.adoc` — accessed 2026-10-28
- Worktrunk: `wt config --help`, `wt config approvals --help`, `wt hook --help` (v0.80.0), https://worktrunk.dev/extending/ , experiments in /tmp — 2026-10-28
- Mergify: https://docs.mergify.com/configuration/file-format/ — accessed 2026-10-28

## Findings

| Tool | Install | Update itself | Project file (committed) | Personal override | User config | Min version in project | Trust for repo commands |
|---|---|---|---|---|---|---|---|
| pre-commit | pip, zipapp | package manager | `.pre-commit-config.yaml` | none | none (cache only) | `minimum_pre_commit_version`: validation error with upgrade hint | none |
| lefthook | brew, npm, go, binary… | `lefthook self-update` | `lefthook.yml` or `.config/lefthook.yml` | `lefthook-local.yml`, wins over all | none | `min_version`: error, non-zero exit | none |
| mise | `curl https://mise.run \| sh` → `~/.local/bin`, brew… | `mise self-update` | `mise.toml` or `.config/mise.toml` | `mise.local.toml` | `~/.config/mise/config.toml` | `min_version`: hard error with upgrade steps | `mise trust`, store in `~/.local/state/mise` |
| direnv | OS packages, curl installer | not found | `.envrc` (bash) | `.envrc.private` by convention | `~/.config/direnv/` | `direnv_version` in `.envrc`: error | `direnv allow`, keyed by path and content |
| gh extension | `gh extension install owner/gh-x` → `~/.local/share/gh/extensions` | `gh extension upgrade --all`; `--pin` | none | none | `~/.config/gh` | not found | none ("you are trusting its publisher") |
| git subcommand / `git config` | `git-<name>` on PATH | none | git-lfs: `.lfsconfig`, git-config syntax | `.git/config` (never committed) | `~/.gitconfig`, `~/.config/git/config` | only `extensions.*` in `.git/config` | git-lfs reads a fixed key set from `.lfsconfig` "for security reasons" |
| Worktrunk | Homebrew (observed) | not read | `.config/wt.toml` (TOML) | `[projects."…"]` in user config | `~/.config/worktrunk/config.toml` | not supported: `min-version` is "unknown field … (will be ignored)" | hooks and aliases approved by command text in `approvals.toml` |
| Mergify | service | service | `.mergify.yml` and 5 other paths | none | none | not found | n/a |

Precedence, as documented:

- mise: "uses the first of these that sets it": flag, `MISE_*` env, nearest project (`mise.local.toml` over `mise.toml`), global, system, default.
- lefthook: "`lefthook-local.yml` can override everything".
- git: files read system → global → local → worktree, "last value found taking precedence"; git-lfs: "Settings from Git configuration files override the `.lfsconfig` file".
- Worktrunk: `--config-set`, then `WORKTRUNK_*` env, then `[projects.…]`, then global; hooks and aliases accumulate.

Worktrunk facts measured on v0.80.0 (2026-10-28):

- An unknown project table (`[polyship]`, `[env]`, `min-version`) is ignored with a warning on every `wt` command.
- `[aliases]` run as `wt <name>` in `sh`; the exit code and an env prefix pass through (alias `exit 3` → `wt ship` exit 3); arguments reach the command only through `{{ args }}`.
- An alias or hook needs approval; editing its text makes it unapproved again; without a TTY an unapproved alias stops with "Cannot prompt for approval".
- `[pre-merge]` commands run in file order (`zeta` before `alpha`).

## Synthesis

The majority pattern has five parts:

1. The tool is a binary on PATH, installed per machine by a package manager or a `curl … | sh` installer into `~/.local/bin` (mise, direnv, lefthook binaries); script tools live in an XDG data directory (`~/.local/share/gh/extensions`).
2. The tool updates itself with one command (`mise self-update`, `lefthook self-update`, `gh extension upgrade --all`).
3. Each tool owns one committed project file (`.pre-commit-config.yaml`, `lefthook.yml`, `mise.toml`, `.lfsconfig`, `.mergify.yml`); no tool studied stores its settings in another tool's file, and Worktrunk warns on foreign keys.
4. Settings layer as env > personal override > project file > user config > default; tools built on git use `git config` for the user and personal layers and a committed git-config-syntax file for the project layer (git-lfs).
5. The project declares a minimum tool version, and an older tool stops with an upgrade hint (pre-commit, lefthook, mise, direnv).

Repo-supplied commands are gated by trust only in tools whose purpose is to run them (direnv, mise, Worktrunk); git-lfs instead limits the keys a committed file may set.

## Open Gaps

- Exit codes for the minimum-version error in pre-commit, mise and direnv were not found; lefthook exits non-zero.
- Worktrunk v0.81.0 behavior was not checked.
- Homebrew tap mechanics were not studied; the installer path above covers the chosen distribution.