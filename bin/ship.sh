#!/usr/bin/env bash
# The tail of every task in a worktree, as code instead of prose: review → test → merge, with an
# agent called only where judgment is needed. Exit 0 means the branch is on the target branch (lib.sh);
# anything else names what stopped it: 1 red tests or no progress, 2 not ready to ship, 3 the owner must
# choose between two behaviors, 4 the target, the remotes or the hooks changed during an agent run other than by
# merge.sh, 5 commits lost (merge.sh). The same
# command from Claude Code, Codex and bb.
#
#   ship.sh                 review by an agent, the tests, merge.sh, conflict rounds
#   SHIP_REVIEW=0 ship.sh   skip the review step (the session already reviewed)
#   SHIP_AGENT=codex        agent for review and conflicts (default: claude, else codex)
#   SHIP_TEST="pnpm test"   the tests before the queue (default: the project's wt pre-merge hook)
#   SHIP_ROUNDS=10          merge rounds per run (each round: merge.sh, and the agent when the rebase stops)
#   SHIP_REVIEW_HOW="…"     how the agent reviews (default: "for correctness, the task in the commit messages, tests";
#                           e.g. "with /my-review-skill")
#
# Commits are the session's job: the message must carry the intent, and only the
# session knows it. A dirty tree stops here.
# ponytail: one agent call per step, no retries of the agent itself; a loop over the merge only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
trap 'ev ship-exit "\"rc\":$?"' EXIT
cd "$(git rev-parse --show-toplevel)"
# A session killed inside a rebase leaves it open, often with a lock of its own (refs/heads/<branch>.lock, index.lock,
# rebase-merge/git-rebase-todo.lock, R10b):
# then --continue fails until someone removes the file (R10). Remove the old ones, as merge.sh does (R5, R7), and say what
# is open instead of "on HEAD".
gd=$(git rev-parse --absolute-git-dir)
stale() { [ -f "$1" ] && [ "$(perl -e 'print int(time - (stat shift)[9])' "$1")" -ge "${MERGE_STALE_INDEX_LOCK:-60}" ] &&
  { rm -f "$1"; echo "ship: removed $1, left by a killed git command" >&2; } || true; }
# always: a kill can leave index.lock with no rebase open, and then even the restore that exit 5 names fails (R1c)
stale "$gd/index.lock"; stale "$gd/HEAD.lock"   # HEAD.lock: a killed checkout; every commit here fails until it goes (R5b)
# A kill inside the rebase before the tests can also leave CHERRY_PICK_HEAD (and its .lock) with no rebase open, or a
# rebase-merge/ without head-name (cut short while git made or removed it): every round then fails "a git operation is
# already in progress" (R21, R21b; lab/kill-stress.sh, about 3 in 550). With HEAD on a branch and a clean tree there is
# nothing in it to keep, so clear it; anything else stays for the session (R21c).
settled() { git symbolic-ref -q HEAD >/dev/null && git diff --quiet HEAD && git diff --cached --quiet HEAD; }
if [ -f "$gd/CHERRY_PICK_HEAD" ] && [ ! -d "$gd/rebase-merge" ] && [ ! -d "$gd/rebase-apply" ] && settled; then
  stale "$gd/CHERRY_PICK_HEAD.lock"; git cherry-pick --quit && echo "ship: cleared a cherry-pick state a killed rebase left (nothing in it to keep)"
fi
if [ -d "$gd/rebase-merge" ] && [ ! -f "$gd/rebase-merge/head-name" ] && settled; then
  rm -rf "$gd/rebase-merge"; echo "ship: removed a rebase-merge/ a kill cut short (no head-name; the branch is checked out, the tree clean)"
fi
if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
  hb=$(cat "$gd"/rebase-*/head-name 2>/dev/null | sed 's#^refs/heads/##' | head -n1) || true
  for f in ${hb:+"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/$hb.lock"} "$gd"/rebase-merge/*.lock "$gd"/rebase-apply/*.lock; do stale "$f"; done
  # The rebase already moved the branch to its result and the kill came before its cleanup: --continue can never pass
  # then ("is at X but expected Y"). Close it only when that is certain: nothing left to do, the branch at HEAD, HEAD not
  # the old tip, a clean tree (R10c).
  todo=$(grep -v -e '^#' -e '^[[:space:]]*$' "$gd/rebase-merge/git-rebase-todo" 2>/dev/null || true)
  if [ -d "$gd/rebase-merge" ] && [ -z "$todo" ] && [ -n "$hb" ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse -q --verify "refs/heads/$hb")" ] &&
     [ "$(git rev-parse HEAD)" != "$(cat "$gd/rebase-merge/orig-head" 2>/dev/null)" ] && git diff --quiet HEAD && git diff --cached --quiet HEAD; then
    git rebase --quit && git checkout -q "$hb" && echo "ship: closed a rebase that had already finished (killed before its cleanup)"
  else
    echo "ship: a rebase is open in this worktree (git status): finish it (resolve, git add, GIT_EDITOR=true git rebase --continue), or go back to the branch as it was with git rebase --abort; then run ship.sh again" >&2; exit 2
  fi
fi
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != "$target" ] && [ "$branch" != HEAD ] || { echo "ship: on $branch; work in a worktree on a branch (Codex: git switch -c <name>)" >&2; exit 2; }
# lost commits first: after a kill the lost commit's files can be left in the tree, and "uncommitted changes" would hide
# that the commit is gone (R1d); "already on the target" stays after the check, so uncommitted work never reads as shipped
l=0; landed || l=$?
if [ $l = 5 ]; then
  [ -z "$(git status --porcelain)" ] || echo "ship: this worktree also has uncommitted changes, and the git reset --hard above would delete them: save them first (git stash -u), then the reset, then git stash pop" >&2
  exit 5   # the reset the message names deletes uncommitted work; the line above stops that (R1e)
fi
[ -z "$(git status --porcelain)" ] || { echo "ship: uncommitted changes; commit them with the intent in the message first" >&2; exit 2; }
# with MERGE_PUSH the local target is not the whole answer: a merge whose push a kill or the network cut off is local
# only, and merge.sh is what pushes it (R19j)
if [ $l = 0 ]; then
  m=0; [ -z "${MERGE_PUSH:-}" ] || "$here/merge.sh" || m=$?
  [ $m = 0 ] || exit $m
  echo "ship: $branch is already on $target"; exit 0
fi

AGENT=${SHIP_AGENT:-$(command -v claude >/dev/null && echo claude || echo codex)}
case "$AGENT" in claude|codex) ;; *) echo "ship: unknown SHIP_AGENT=$AGENT" >&2; exit 2 ;; esac
# the agent's marker names this repository only: its children (a test suite, the lab's stands) still merge elsewhere (R8d)
agent_run=$(git rev-parse --path-format=absolute --git-common-dir)
logs=$(git rev-parse --git-dir) # per worktree; the logs stay for diagnosis (ship-review.log, ship-test.log, ship-conflict.log)
agent() { # <prompt> <log>: a non-interactive agent run in this worktree that may edit files and run git; never fails the script, the caller reads the log
  before=$(fence)
  case "$AGENT" in
    # No allow-list: a review skill may need subagents, MCP and arbitrary shell, and every allow-list
    # tried so far broke it. guard() below checks the target, the remotes and the hooks
    # after each run. Codex runs in the same shape: its workspace-write sandbox keeps a worktree's git dir read-only
    # even when added as a writable root, so the agent could neither commit a review fix nor finish a rebase (R22).
    claude) printf %s "$1" | SHIP_AGENT_RUN="$agent_run" claude -p --permission-mode bypassPermissions ;;
    codex)  printf %s "$1" | SHIP_AGENT_RUN="$agent_run" codex exec --dangerously-bypass-approvals-and-sandbox - ;;
  esac 2>&1 | tee "$logs/$2" | tail -20 || true
  guard
}
# The agent runs without an allow-list, so the prompt is not the only fence: whatever it read in the diff, it must not
# have moved the target, added a remote or planted a git hook. Checked after every agent step, before anything merges.
hooks=$(git rev-parse --git-common-dir)/hooks
fence() { echo "$(git rev-parse "$target") $(git remote -v | tr '\n\t' '  ') $(git config --get core.hooksPath) $(ls -A "$hooks" 2>/dev/null | tr '\n' ' ') $(cat "$hooks"/* 2>/dev/null | shasum)"; }
# Another session's merge moving the target is not the agent: it goes through when the remotes and hooks are the same and
# every step from the target seen before the run to the current one is a move merge.sh recorded under its lock (R8).
# Anything else (the agent moved it, alone or under a later merge) stops with 4. Measured: exit 4 was the largest
# cost past 8 sessions (lab/pareto.py, measurements/REPORT.md 2026-10-22).
guard() {
  local now; now=$(fence); [ "$now" = "$before" ] && return 0
  if [ "${now#* }" = "${before#* }" ] && ! by_merges "${before%% *}" "${now%% *}"; then
    # a merge.sh may be between its fast-forward and its line in the moves file: wait for its lock, look again under it
    exec 8>>"$(git rev-parse --path-format=absolute --git-common-dir)/wt-merge.lock"
    perl -MFcntl=:flock -e 'open(my $f, ">&=8") or die "fd 8: $!"; flock($f, LOCK_EX) or die "flock: $!"'
    now=$(fence); exec 8>&-
  fi
  if [ "${now#* }" = "${before#* }" ] && by_merges "${before%% *}" "${now%% *}"; then
    echo "ship: $target moved by another session's merge while $AGENT ran; going on"; ev ship-fence-pass; return 0
  fi
  echo "ship: $target, the remotes or .git/hooks changed while the agent ran, and not only by merge.sh; stopped. Check git reflog $target, git remote and .git/hooks, then run ship.sh again." >&2; exit 4
}
# The verdict is the last non-empty line, exactly: a phrase quoted in the agent's prose is not a verdict.
verdict() { grep -v '^[[:space:]]*$' "$logs/$1" | tail -n1; }

if [ "${SHIP_REVIEW:-1}" != 0 ]; then
  echo "ship: review by $AGENT"
  how=${SHIP_REVIEW_HOW:-for correctness, the task in the commit messages, tests}
  agent "Review the changes of this branch against $target (git diff $target...HEAD) $how. Nobody can answer questions: do not ask any. Fix every blocker and major finding in place and commit the fixes with a message that names the finding. If a finding cannot be fixed here or needs the owner's product decision, do not fix it. Do not merge, do not touch $target, do not run ship.sh, do not add remotes or git hooks. Your last line is exactly REVIEW OK, or REVIEW BLOCKED: <reason> when a blocker or major finding is left." ship-review.log
  v=$(verdict ship-review.log)
  case "$v" in
    "REVIEW OK") ;;
    "REVIEW BLOCKED"*) echo "ship: $v" >&2; exit 1 ;;
    *) echo "ship: the review did not end with a verdict line (last line: $v); see $logs/ship-review.log" >&2; exit 1 ;;
  esac
  [ -z "$(git status --porcelain)" ] || { echo "ship: the review left uncommitted changes; commit or drop them, then run ship.sh again" >&2; exit 1; }
fi

# Test what will merge: the branch on the current target, not on its old base, where a branch that needs another
# session's landed change stays red forever (R9). When that rebase conflicts, the old base is no answer either: skip
# the tests here; the merge rounds resolve the conflict and the pre-merge hook tests the result under the lock (R9b).
refuse_edited_merges
pre=1
if ! git merge-base --is-ancestor "$target" HEAD; then
  record_tip   # before the rewrite: a SIGKILL inside this rebase is R1 again, and landed needs the tip to see it (R1b)
  git rebase -q "$target" >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; pre=0
    echo "ship: the branch conflicts with $target; no tests before the queue: the merge rounds resolve it, the pre-merge hook tests it"; }
fi
if [ $pre = 1 ]; then
  echo "ship: tests before the queue"
  sh -c "${SHIP_TEST:-wt hook pre-merge --yes}" >"$logs/ship-test.log" 2>&1 || { tail -40 "$logs/ship-test.log" >&2; echo "ship: tests are red on $branch (full log: $logs/ship-test.log); fix the branch, then run ship.sh again" >&2; exit 1; }
fi

# more rounds than before: another session's merge no longer ends the run with 4, so one run sees more moves
for round in $(seq 1 "${SHIP_ROUNDS:-10}"); do
  echo "ship: merge (round $round)"; ev ship-round "\"round\":$round"
  m=0; "$here/merge.sh" || m=$?
  [ $m = 0 ] && break
  [ $m = 5 ] && exit 5
  if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then
    echo "ship: rebase stopped on a conflict; asking $AGENT"; ev ship-conflict
    agent "A rebase onto $target stopped on a conflict in this worktree (git status). Read both sides and the commit messages (git log $target -5, git log REBASE_HEAD -1): they carry the intent. If both intents can hold, resolve, git add, GIT_EDITOR=true git rebase --continue. If this commit's intent is already on $target (another session did the same thing, in other code), run git rev-parse REBASE_HEAD >> $dropped, then git rebase --skip. If the two sides want incompatible product behaviors, do NOT choose: leave the rebase open, commit nothing, and make your last line exactly: OWNER DECISION NEEDED: <option A> vs <option B>." ship-conflict.log
    # A product conflict stays open for the owner, with the conflict visible in the worktree.
    v=$(verdict ship-conflict.log)
    case "$v" in "OWNER DECISION NEEDED"*) echo "ship: $v (the rebase is left open in this worktree)" >&2; exit 3 ;; esac
    [ -d "$(git rev-parse --git-dir)/rebase-merge" ] && { echo "ship: rebase still open after the agent; finish it by hand" >&2; exit 1; }
  else
    [ $m = 2 ] && { echo "ship: merge.sh refused (see above); not a test failure" >&2; exit 2; }   # e.g. MERGE_PUSH and an owner's local commit
    echo "ship: merge failed without a conflict (red tests after the rebase, a git lock, MERGE_PREPARE: see above)" >&2; exit 1
  fi
done
# the same test as merge.sh: ancestry alone passes a branch whose last conflict round skipped its commit (R11)
l=0; landed || l=$?
[ $l = 0 ] || { [ $l != 1 ] || echo "ship: $branch is not on $target after ${SHIP_ROUNDS:-10} rounds" >&2; exit $l; }
echo "ship: $branch is on $target"
