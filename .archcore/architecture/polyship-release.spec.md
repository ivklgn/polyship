---
title: "polyship release — the published assets, the installer and the version"
status: draft
tags:
  - "install"
  - "release"
  - "spec"
---

## Purpose & Scope

Normative for what one polyship release publishes, what `@install.sh` does with it, and the version the command reports; modelled on polybrief's release spec. Dependents: users who run `curl … install.sh | sh`, scripts that fetch assets by URL, and the maintainer who pushes a tag. Out of scope: the command's arguments (`.archcore/architecture/polyship-cli.spec.md`) and the merge flow.

## Surface

- Trigger: a pushed tag `vMAJOR.MINOR.PATCH` without a suffix; workflow `@.github/workflows/release.yml`; checks `@.github/workflows/ci.yml` on `macos-latest` and `ubuntu-latest`.
- Build: `@.github/scripts/package.sh vX.Y.Z <out dir>`.
- Assets: `polyship.tar.gz` (`bin/polyship`, `bin/merge.sh`, `bin/ship.sh`, `bin/lib.sh`, `lab/recover.sh`, `VERSION`, `README.md`, `LICENSE` at the archive root) and `checksums.txt` with the line `<sha256>  polyship.tar.gz`.
- URLs: `https://github.com/ivklgn/polyship/releases/download/vX.Y.Z/<asset>` and `…/releases/latest/download/<asset>`.
- Installer inputs: `POLYSHIP_VERSION` (default `latest`), `POLYSHIP_INSTALL_DIR` (default `~/.local/bin`), `POLYSHIP_BASE_URL` (a fork or a local build), `XDG_DATA_HOME`.
- Install layout: `${XDG_DATA_HOME:-~/.local/share}/polyship/<X.Y.Z>/` and the link `<install dir>/polyship` → `<X.Y.Z>/bin/polyship`.

## Normative Behavior

1. WHEN a release tag is pushed, the release workflow MUST run the checks of `ci.yml` before it builds an asset.
2. WHEN the checks pass, the release workflow MUST attach `polyship.tar.gz` and `checksums.txt` to the GitHub Release named after the tag.
3. WHEN `package.sh` builds from tag `vX.Y.Z`, it MUST write `X.Y.Z` into the archive's `VERSION`.
4. WHEN `install.sh` runs, it MUST verify the archive's sha256 against `checksums.txt` before it unpacks anything.
5. WHEN the release's version directory is missing, `install.sh` MUST copy the release beside it and rename it into place.
6. WHEN the version directory is in place, `install.sh` MUST replace the command link with one rename.
7. WHEN an installed release runs `polyship --version`, the command MUST print `polyship X.Y.Z`.
8. IF the install directory is not on `PATH`, THEN `install.sh` MUST print the line that adds it.

## Constraints & Invariants

- A published tag is never moved or reused; a fix ships as the next version.
- An installed version directory never changes, because a running `polyship ship` may still start `merge.sh` from it; `install.sh` never deletes one.
- `install.sh` writes nothing into a repository.
- Updating is running `install.sh` again; `POLYSHIP_VERSION` also installs an older release.

## Failure Behavior

1. IF the tag is not `vMAJOR.MINOR.PATCH`, THEN the release workflow and `package.sh` MUST fail before an asset is built.
2. IF the tag is not the next patch, minor or major version after the highest release tag, THEN the release workflow MUST fail before it builds.
3. IF a check fails, THEN the release workflow MUST publish no asset.
4. WHEN the publish job runs again after a partial upload, the release workflow MUST replace the existing assets of that release.
5. IF a download fails or the sha256 differs, THEN `install.sh` MUST exit 1 and leave the installed command unchanged.
6. IF the archive has no valid `VERSION`, THEN `install.sh` MUST exit 1 before it installs anything.

## Conformance

An implementation conforms when it satisfies every MUST above. `@lab/polyship-checks.sh` P1–P4 check `package.sh` and `install.sh` against a local release (`POLYSHIP_BASE_URL=file://…`); clauses 1, 2 and Failure Behavior 2–4 run only on GitHub Actions and are checked by the first release run.