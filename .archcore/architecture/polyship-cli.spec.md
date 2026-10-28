---
title: "polyship — the per-machine command and its arguments"
status: draft
tags:
  - "config"
  - "install"
  - "spec"
---

## Purpose & Scope

Normative for the `polyship` launcher (`@bin/polyship`): its commands, the `-o KEY=VALUE` settings, how a command reaches `bin/ship.sh` and `bin/merge.sh` of its own version, and its refusals. Dependents: agents and people in adopter repositories (they run `polyship ship` with the arguments their Shipping block names), `@INSTALL.md`, `@README.md` and `@example/demo.sh`.

Not covered: the release and the install (`.archcore/architecture/polyship-release.spec.md`), the merge flow (`.archcore/architecture/merge-sh.spec.md`, `.archcore/architecture/ship-sh.spec.md`), Worktrunk hooks and approvals.

## Surface

- `polyship ship [-C DIR] [-o KEY=VALUE]...` — runs `bin/ship.sh`; exit codes are ship.sh's.
- `polyship merge [-C DIR] [-o KEY=VALUE]... [FLAGS]` — runs `bin/merge.sh`; FLAGS go to `wt merge`.
- `polyship config [-o KEY=VALUE]...` — one line `CONFIG<TAB>key<TAB>value<TAB>source` per key; source `flag` or `default`.
- `polyship check` — runs `lab/recover.sh` with `BIN` set to the version's `bin/`.
- `polyship --version` — `polyship <version>` from the release's `VERSION` file, or `polyship dev` in a checkout.
- Settings, each mapped to the variable the scripts read:

| Key | Values | Variable |
|---|---|---|
| `target` | branch | `MERGE_TARGET` |
| `push` | remote | `MERGE_PUSH` |
| `prepare` | command | `MERGE_PREPARE` |
| `test` | command | `SHIP_TEST` |
| `agent` | `claude`, `codex` | `SHIP_AGENT` |
| `review` | `on`, `off` | `SHIP_REVIEW` (`1`, `0`) |
| `review_how` | text | `SHIP_REVIEW_HOW` |
| `rounds` | whole number ≥ 1 | `SHIP_ROUNDS` |
| `stale_index_lock` | whole number ≥ 1 | `MERGE_STALE_INDEX_LOCK` |

## Normative Behavior

1. WHEN a command starts, the launcher MUST resolve its own path through every symlink and use that version directory for the whole run.
2. WHEN `-o` names a known key, the launcher MUST export its value under the key's variable for that command.
3. WHEN `-o` repeats a key, the launcher MUST use the last value.
4. WHEN no argument sets a key, the launcher MUST unset the key's variable, so the script's default applies.
5. WHEN `-C DIR` is given, the launcher MUST run the command in DIR.
6. WHEN `polyship config` runs, the launcher MUST print every key with its effective value and source.
7. WHEN `config` prints `review`, the launcher MUST print `on` or `off`, as the argument takes it.
8. WHEN `polyship merge` gets an argument that is not `-C` or `-o`, the launcher MUST pass it to `bin/merge.sh`.

## Constraints & Invariants

- The launcher MUST read no settings file and no settings variable: a variable left in the caller's shell does not reach the scripts. Rationale: one approach with polybrief (`arguments-only-runtime.adr` there).
- The launcher MUST NOT write any file.
- `bin/merge.sh`, `bin/ship.sh` and `bin/lib.sh` keep reading env only; the launcher is their only public entry.
- The launcher MUST run on bash 3.2 with perl and git (`.archcore/conventions/project-stack.rule.md`).

## Failure Behavior

1. IF the command is missing or unknown, THEN the launcher MUST print the usage and exit 2.
2. IF an override lacks `=`, THEN the launcher MUST exit 2 naming the override.
3. IF an override names an unknown key, THEN the launcher MUST exit 2 naming the key.
4. IF a value is outside its allowed values, THEN the launcher MUST exit 2 naming the key and the value.
5. IF `ship` gets an argument that is not `-C` or `-o`, THEN the launcher MUST exit 2 naming it.
6. IF `-C` names no directory, THEN the launcher MUST exit 2 naming it.
7. IF `ship` or `merge` runs outside a git worktree, THEN the launcher MUST exit 2 naming the directory.

## Conformance

An implementation conforms when it satisfies every MUST above. `@lab/polyship-checks.sh` P4–P8 check clauses 1–8 and Failure Behavior 1–7 against a stub `ship.sh` and `merge.sh` in a throwaway HOME.

```
Given the caller's shell sets MERGE_PUSH=evil
When the agent runs polyship ship -o review=off
Then ship.sh sees SHIP_REVIEW=0 and no MERGE_PUSH
```