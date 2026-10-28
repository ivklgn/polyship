# Installing polyship into a repository

Reader: a coding agent, or a person, working **in the repository that adopts polyship**. Do the steps in
order. Every step ends with a check; when a check fails, stop and report the step and its output. Do not
skip the end-to-end check in step 8: it is the only proof that the install works.

polyship is installed once per machine. The repository gets only configuration: `.config/wt.toml` and a block
in `CLAUDE.md` or `AGENTS.md` that names the command with its arguments. Never copy polyship's scripts into it.

Facts to collect before you start, from the owner or from the repository (lockfile, Makefile, CI config).
Say which ones you inferred.

| Fact | Example |
|---|---|
| install command for a fresh worktree | `pnpm install --frozen-lockfile --prefer-offline` |
| test command, the merge gate | `pnpm test` |
| target branch | `main` |
| whether new worktrees start from `origin/<target>` (Claude Code and Codex worktrees usually do) | yes |
| whether some worktrees skip `post-start` (Codex, plain `git worktree add`) | no |
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

## 2. polyship on this machine

`polyship --version` already prints a version: run the install anyway, it updates to the newest release.

```sh
curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh
polyship --version
polyship check; echo "exit $?"
```

`polyship check` builds throwaway repositories under `/tmp` and runs the known failure replays against the
installed scripts. It touches nothing in this repository and takes a few minutes (about 4 on a laptop).

Check: the install prints `Installed polyship <version>` (it verified the sha256 of the release); `polyship
--version` prints the same (if the shell does not find `polyship`, add the PATH line the installer printed); in
the `check` output no line starts with `FAIL`, and the last line is `exit 0`. Other lines (`reproduced …`,
`Killed: 9`, git messages) are the replays' own output, not failures.

## 3. The project's hooks

Create `.config/wt.toml` at the repository root with the two commands from the facts table. Leave out
`[post-start]` if the project needs no install step. If some worktrees skip `post-start`, add the install step
to `[pre-merge]` before the tests; wt runs its commands in file order:

```toml
[post-start]
deps = "<install command>"

[pre-merge]
deps = "[ -d node_modules ] || <install command>"   # only if some worktrees skip post-start
test = "<test command>"
```

Check: `cat .config/wt.toml` shows the commands, and they are the project's real commands, not the examples.

## 4. Approve the hooks

Once per repository. Without it a non-interactive session hangs at an approval prompt.

```sh
wt config approvals add --yes
wt config approvals list
```

Check: the list shows the `pre-merge` commands (and `post-start`, if any) as approved.

## 5. The command and its arguments

Settings are arguments of the command, `-o KEY=VALUE`; there is no settings file. Choose them from the facts
table; with the defaults the command is plain `polyship ship`:

- new worktrees start from `origin/<target>`: `-o push=origin`. Every merge is then pushed under the lock, so the
  next session starts from the merged code; without it, new sessions start from a stale target.
- the project has its own review skill or checklist: `-o review_how='with /<skill>'` (or the checklist in plain
  words). Without it the agent reviews for correctness, the task in the commit messages and tests;
  `-o review=off` skips the review step.
- Codex sessions must be able to write the worktree's git directory to commit. Codex's `workspace-write` sandbox
  keeps it read-only, so run non-interactive Codex sessions with `--dangerously-bypass-approvals-and-sandbox` (or
  approve `git commit` by hand). The Codex agent that `polyship ship` starts already runs without the sandbox.

Check: `polyship config <your -o arguments>` prints each key you set with source `flag`, and exits 0.

## 6. Tell the agents

Add this to `CLAUDE.md` or `AGENTS.md`, worded for this repository, with the command from step 5. A later
session that resolves a conflict sees only the commits, not the chat, so the intent must be in the commits.

```markdown
## Shipping

- A task ends with `<the command from step 5>`. Commit first. Exit code 0 means the branch is on `<target>`.
- `polyship ship` runs for minutes (review, tests, the queue). Run it in the foreground and wait for its exit
  code; do not end your turn while it runs, and do not report the task shipped without exit code 0.
- Write the intent of the task into the commit message, not only what changed.
- If a conflict is between two incompatible product behaviors, do not choose. Leave the rebase open
  and ask the owner, with both options (`polyship ship` exits with 3).
- Exit code 5 means lost commits: run the `git reset --hard` command from the message. If the tree has
  uncommitted changes, `git stash -u` first and `git stash pop` after: the reset deletes them.
```

Check: `grep -n 'polyship ship' CLAUDE.md AGENTS.md` finds the block with the command of step 5.

## 7. Commit

Commit `.config/wt.toml` and the agent instructions, with the intent in the
message (why this repository adopts polyship). The configuration must be in a commit before step 8: a
worktree is created from a commit.

Check: `git status --porcelain` is empty, and `git ls-files` lists no polyship script.

## 8. End-to-end check

Ship a throwaway commit into a throwaway target, so the real target branch is not touched. Run from the
repository root, on the target branch.

```sh
git branch polyship-smoke-target
wt switch --create polyship-smoke --base polyship-smoke-target --no-cd
smoke=$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/polyship-smoke"{print w; exit}')
cd "$smoke"
echo "polyship smoke $(date +%s)" > .polyship-smoke
git add .polyship-smoke && git commit -qm "chore: polyship smoke test, delete after the check"
polyship ship -o target=polyship-smoke-target -o review=off; echo "exit $?"
```

This run has no `push`, so it pushes nothing, and it merges into the throwaway target.

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

Exit codes other than 0 and what they mean: the exit code table in "Quick reference" of polyship's README. The
common ones here: exit 1 with `tests are red` means the `pre-merge` commands of step 3 fail on a clean tree;
exit 2 with `no target branch` means `wt config state default-branch set <target>` was never run and
`-o target` is not given; exit 2 with `polyship:` names a bad argument.

## 9. Report

Report to the owner:

- the files you changed and the commit;
- the polyship version from step 2 and the result of `polyship check`;
- the output of step 8, checks 1 to 4;
- the facts you inferred rather than were given, and the command with its arguments from step 5;
- whether you set `-o push` in step 5, and why: without it `polyship ship` merges into the **local** target only.
