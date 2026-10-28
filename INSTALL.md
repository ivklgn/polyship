# Installing polyship into a repository

Reader: a coding agent, or a person, working **in the repository that adopts polyship**. Do the steps in
order. Every step ends with a check; when a check fails, stop and report the step and its output. Do not
skip the end-to-end check in step 9: it is the only proof that the install works.

Facts to collect before you start, from the owner or from the repository (lockfile, Makefile, CI config).
Say which ones you inferred.

| Fact | Example |
|---|---|
| install command for a fresh worktree | `pnpm install --frozen-lockfile --prefer-offline` |
| test command, the merge gate | `pnpm test` |
| task runner for aliases | `package.json` scripts, `Makefile`, `justfile`, none |
| target branch | `main` |
| whether new worktrees start from `origin/<target>` (Claude Code and Codex worktrees usually do) | yes |
| the project's own review skill or checklist, if any | none |

## 1. Prerequisites

```sh
bash --version | head -1     # any bash ≥ 3.2
perl -v | sed -n 2p          # any perl; it provides flock
git --version                # 2.40 or newer (merge-tree --merge-base; rev-parse --path-format needs 2.31)
wt --version                 # wt v0.80.0 or newer
```

If `wt` is missing or older than 0.80, once per machine (Homebrew works on macOS and Linux):

```sh
brew install worktrunk
wt config shell install
wt config plugins claude install     # only for Claude Code
```

Check: all four commands print a version, and `wt --version` is at least `v0.80.0`.

## 2. The project's hooks

Create `.config/wt.toml` at the repository root with the two commands from the facts table. Leave out
`[post-start]` if the project needs no install step.

```toml
[post-start]
deps = "<install command>"

[pre-merge]
test = "<test command>"
```

Check: `cat .config/wt.toml` shows both commands, and they are the project's real commands, not the examples.

## 3. Approve the hooks

Once per repository. Without it a non-interactive session hangs at an approval prompt.

```sh
wt config approvals add --yes
wt config approvals list
```

Check: the list shows the `pre-merge` command (and `post-start`, if any) as approved.

## 4. Copy the scripts

```sh
curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh
head -2 scripts/ship.sh
```

Check: the output has a line `vendor: polyship <sha> → <path>/scripts`. The directory holds
`merge.sh`, `ship.sh`, `lib.sh` and `lab/recover.sh`. Line 2 of each script starts with
`# Vendored from polyship`.

## 5. Self-check of the copy

```sh
scripts/lab/recover.sh; echo "exit $?"
```

This builds throwaway repositories under `/tmp` and runs the known failure replays against the copied
scripts. It touches nothing in this repository. It takes a few minutes (about 4 on a laptop).

Check: every line starts with `PASS`, the last line is `exit 0`.

## 6. Aliases

Add two aliases to the task runner, so every session calls the same command:

| Runner | Lines |
|---|---|
| `package.json` | `"ship": "scripts/ship.sh"`, `"merge": "scripts/merge.sh"` |
| `Makefile` | `ship: ; scripts/ship.sh` and `merge: ; scripts/merge.sh` |
| `justfile` | `ship: scripts/ship.sh` and `merge: scripts/merge.sh` |
| none | sessions call `scripts/ship.sh` directly |

Prefix the alias with environment variables when the facts table says so:

- some worktrees skip `post-start` (Codex, plain `git worktree add`):
  `MERGE_PREPARE='[ -d node_modules ] || <install command>'`
- new worktrees start from `origin/<target>`: `MERGE_PUSH=origin`. Every merge is then pushed under the lock, so
  the next session starts from the merged code; without it, new sessions start from a stale target.
- sessions run in Codex: they must be able to write the worktree's git directory to commit. Codex's
  `workspace-write` sandbox keeps it read-only, so a non-interactive Codex session in that sandbox cannot
  commit or ship; run those sessions with `--dangerously-bypass-approvals-and-sandbox` (or approve `git commit`
  by hand). `ship.sh`'s own Codex agent already runs without the sandbox.
- the project has its own review skill or checklist: `SHIP_REVIEW_HOW='with /<skill>'` (or the checklist in
  plain words). Without it the agent reviews for correctness, the task in the commit messages and tests.
  `SHIP_REVIEW=0` skips the review step.

Check: the runner resolves the alias (for example `pnpm run ship --help` or `make -n ship` prints the
script path).

## 7. Tell the agents

Add this to `CLAUDE.md` or `AGENTS.md`, worded for this repository. A later session that resolves a
conflict sees only the commits, not the chat, so the intent must be in the commits.

```markdown
## Shipping

- A task ends with `<alias or scripts/ship.sh>`. Commit first. Exit code 0 means the branch is on `<target>`.
- `ship.sh` runs for minutes (review, tests, the queue). Run it in the foreground and wait for its exit code;
  do not end your turn while it runs, and do not report the task shipped without exit code 0.
- Write the intent of the task into the commit message, not only what changed.
- If a conflict is between two incompatible product behaviors, do not choose. Leave the rebase open
  and ask the owner, with both options (`ship.sh` exits with 3).
- Exit code 5 means lost commits: run the `git reset --hard` command from the message. If the tree has
  uncommitted changes, `git stash -u` first and `git stash pop` after: the reset deletes them.
```

Check: `grep -n ship.sh CLAUDE.md AGENTS.md` finds the block.

## 8. Commit

Commit `.config/wt.toml`, `scripts/`, the runner file and the agent instructions, with the intent in the
message (why this repository adopts polyship). The scripts must be in a commit before step 9: a worktree
is created from a commit.

Check: `git status --porcelain` is empty.

## 9. End-to-end check

Ship a throwaway commit into a throwaway target, so the real target branch is not touched. Run from the
repository root, on the target branch.

```sh
git branch polyship-smoke-target
wt switch --create polyship-smoke --base polyship-smoke-target --no-cd
smoke=$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/polyship-smoke"{print w; exit}')
cd "$smoke"
echo "polyship smoke $(date +%s)" > .polyship-smoke
git add .polyship-smoke && git commit -qm "chore: polyship smoke test, delete after the check"
MERGE_PUSH= SHIP_REVIEW=0 MERGE_TARGET=polyship-smoke-target scripts/ship.sh; echo "exit $?"
```

Check, in this order:

1. `ship: tests before the queue` appears, then `ship: merge (round 1)`.
2. The last two lines are `ship: polyship-smoke is on polyship-smoke-target` and `exit 0`.
3. `git log -1 --format=%s polyship-smoke-target^2` prints `chore: polyship smoke test, delete after the check`
   (the target's tip is the merge commit; its second parent is the branch).
4. `git log -1 --format=%s <target>` is unchanged.

Clean up:

```sh
cd "$(git rev-parse --path-format=absolute --git-common-dir)/.."
wt remove -D polyship-smoke --foreground
git branch -D polyship-smoke-target
```

Check: `git worktree list` has no `polyship-smoke`, `git branch --list 'polyship-smoke*'` is empty.

Exit codes other than 0 and what they mean: the exit code table in "Quick reference" of polyship's README. The two common
ones here: exit 1 with `tests are red` means the `pre-merge` command of step 2 fails on a clean tree; exit 2
with `no target branch` means `wt config state default-branch set <target>` was never run and
`MERGE_TARGET` is unset.

## 10. Report

Report to the owner:

- the files you changed and the commit;
- the output of step 9, checks 1 to 4;
- the facts you inferred rather than were given, and the environment variables you set in step 6;
- whether you set `MERGE_PUSH` in step 6, and why: without it `ship.sh` merges into the **local** target only.
