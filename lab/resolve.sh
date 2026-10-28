#!/usr/bin/env bash
# The scripted agent of the lab: finish an open rebase in the current worktree, keeping both sides of
# every conflict (the lab's edits are independent lines, so "both intents hold" is always right here).
#   lab/resolve.sh <think-seconds>
# Last line: RESOLVED, or the reason it could not.
set -uo pipefail
sleep "${1:-0}"
gd=$(git rev-parse --git-dir)
for _ in 1 2 3 4 5 6 7 8; do
  [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || { echo RESOLVED; exit 0; }
  conflicted=$(git diff --name-only --diff-filter=U)
  for f in $conflicted; do
    # drop the markers and a diff3 base section, keep ours then theirs
    perl -i -ne 'if(/^<<<<<<< /){$s=1;next} if(/^\|\|\|\|\|\|\| /){$s=2;next} if(/^=======$/){$s=1;next} if(/^>>>>>>> /){$s=0;next} print unless $s==2' "$f"
    git add "$f"
  done
  # a conflict resolved to nothing: this commit's intent is already on the target. Do what ship.sh's conflict prompt
  # says: name it in merge-dropped (old bin/ ignores the file), skip it. Only after a real conflict: a rebase stopped by
  # a SIGKILL also has the index at HEAD, and skipping there would drop work
  if [ -n "$conflicted" ] && [ -d "$gd/rebase-merge" ] && git diff --cached --quiet HEAD 2>/dev/null; then
    git rev-parse REBASE_HEAD >> "$gd/merge-dropped" 2>/dev/null; git rebase --skip >/dev/null 2>&1 || true; continue
  fi
  GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
done
echo "NOT RESOLVED: rebase still open"
