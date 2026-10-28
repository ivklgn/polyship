---
title: "Distribute polyship like polybrief; adopters keep only configuration"
status: draft
tags:
  - "config"
  - "install"
  - "process"
---

## Goal

Distribute and configure polyship the way polybrief is distributed and configured, in Bash: a tag publishes a checked release archive, `install.sh` installs and updates it, and settings are command arguments. Adopters keep only configuration; lifecore-app is moved to it.

## Tasks

### Phase 1 — done in 3cce83b, afeb901 (first per-machine design)

1. Add the launcher and the version directories; delete the vendoring script. @bin/polyship @bin/vendor.sh
2. Move lifecore-app off `scripts/`. No target in this repository: lifecore-app commit 441c435.

### Phase 2 — align with polybrief

3. Take settings only as `-o KEY=VALUE`; add `config` and `--version`; drop `self-update` and the file and git config layers. @bin/polyship
4. Build the release assets from a tag. @.github/scripts/package.sh
5. Download, verify and install a release, as polybrief's installer does. @install.sh
6. Run the four checks on macOS and Linux. @.github/workflows/ci.yml
7. Check the tag, run the checks, publish the assets. @.github/workflows/release.yml
8. Rewrite the stand for the archive, the installer and the arguments. @lab/polyship-checks.sh
9. Rewrite the install, settings and agent-instruction steps. @INSTALL.md @README.md
10. Update the release note for contributors and the demo command. @CONTRIBUTING.md @example/demo.sh
11. Update the canon listed under Declared Delta.

### Phase 3 — land and move the adopter

12. Land the branch with `bin/merge.sh`. @bin/merge.sh
13. Install from a local build with `POLYSHIP_BASE_URL`, replacing the first design's install.
14. Delete `.config/polyship.conf` in lifecore-app and run the smoke of INSTALL.md step 8. No target in this repository.
15. Push `main` and the first tag, then watch the release run. Owner's step.

## Acceptance Criteria

- `@lab/polyship-checks.sh` passes inside the `pre-merge` gate: archive, sha256 refusal, version switch, arguments only, refusals, `config`.
- `polyship --version` on this machine prints `polyship X.Y.Z` of a release built by `package.sh`.
- `polyship check` on the installed copy prints no `FAIL` line and exits 0.
- In lifecore-app, `git ls-files` lists no polyship file besides `.config/wt.toml`, and the step 8 smoke prints `exit 0`.
- `grep -rn 'self-update\|polyship.conf' README.md INSTALL.md CONTRIBUTING.md example/ bin/ install.sh` finds nothing.
- The first pushed tag produces a GitHub Release with `polyship.tar.gz` and `checksums.txt`.

## Dependencies

- GitHub Actions runners with Homebrew for `brew install worktrunk` (macOS: present; Linux: assumed at `/home/linuxbrew/.linuxbrew` [assumption], unchecked until the first CI run).
- The release workflow needs the repository pushed to `github.com/ivklgn/polyship`; until then installs use `POLYSHIP_BASE_URL=file://…`.
- `@lab/swarm.sh` keeps copying the scripts into its throwaway repository, so its runs stay comparable with `@measurements/REPORT.md` [assumption].

## Declared Delta

- amend adr `architecture/install-once-per-machine-config-only-adopters` — the decision becomes polybrief's distribution and arguments-only settings
- amend spec `architecture/polyship-cli` — arguments, `config`, `--version`; no layers, no `self-update`
- create spec `architecture/polyship-release` — assets, installer, version
- amend rule `conventions/changing-the-merge-flow` — clause 5: push the next tag
- amend doc `architecture/configuration` — arguments and install inputs
- amend doc `architecture/entry-points` — launcher, installer, package script, workflows
- amend doc `architecture/architecture-overview` — Layout and Configuration row
- none research `research/how-dev-tools-install-and-configure` — still the external evidence
- none spec `architecture/ship-sh`, `architecture/merge-sh` — the scripts keep reading env only

## Clarifications

- Distribution: the owner chose `install.sh` into `~/.local` over a Homebrew tap (2026-10-28).
- One approach for polyship and polybrief: the owner asked for it after comparing the two (2026-10-28); settings become arguments only, updating is running `install.sh` again, releases come from a tag through GitHub Actions.
- Language: the owner decided to keep Bash, not Go (2026-10-28).
- Earlier, the owner chose "a section in `.config/wt.toml`", then the canonical design `.config/polyship.conf`; both are replaced by the arguments-only decision above.