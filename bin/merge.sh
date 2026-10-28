#!/usr/bin/env bash
# Merge the current worktree's branch into the target branch, one session at a time.
# `wt merge` is safe under a race (git refuses a stale fast-forward) but not fair: every loser
# re-runs rebase and the whole test suite, and the slowest branch may never land. This lock makes
# merges serial: rebase → pre-merge hook → merge commit happen while nobody else moves the target.
# A rebase conflict leaves the rebase open in the worktree for the agent; fix it and run again.
#
# Exit 0: on the target (and on MERGE_PUSH's remote). 2: run by ship.sh's agent (SHIP_AGENT_RUN), no target branch, a merge commit with a change of its own, or (MERGE_PUSH) a local commit on the target the remote lacks. 5: the branch is on the target but its commits are not; the message says how to
# restore them. 1: MERGE_PREPARE failed. Anything else: wt merge's own exit code (conflict, red tests, a
# refused fast-forward), except that a 5 from wt (a pre-merge hook's code: pytest exits 5 when it collects no
# tests) becomes 1, so 5 always means lost commits. Arguments go to wt merge as flags; the target is MERGE_TARGET.
#
#   MERGE_PREPARE="pnpm install --frozen-lockfile --prefer-offline"   sh command run under the lock before the
#                                     merge, for worktrees that skipped the wt post-start hook (Codex, `git worktree add`)
#   MERGE_PUSH=origin                 publish the target on this remote: take its target first, push each merge,
#                                     land only what it took (default: local only, nothing fetched or pushed)
#   MERGE_TARGET, MERGE_EVENTS        see lib.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# ship.sh merges when its agent is done; a merge by the agent itself would pass the fence as a recorded move (R8c).
# The marker names the repository, so the agent's children merge elsewhere: a test suite, the lab's stands (R8d).
[ "${SHIP_AGENT_RUN:-}" != "$(git rev-parse --path-format=absolute --git-common-dir)" ] || { echo "merge: refused: run by ship.sh's agent; ship.sh merges this branch when the agent is done" >&2; exit 2; }
# The lock is flock(2) on fd 9, held by this shell: the kernel drops it when the shell exits by any
# means, SIGKILL included, so there is no stale lock, no pid to trust and no takeover race (lab/lock.sh).
# The file's text only names the holder for the waiting message.
lock="$(git rev-parse --git-common-dir)/wt-merge.lock"
exec 9>>"$lock"
ev lock-wait
if ! perl -MFcntl=:flock -e 'open(my $f, ">&=9") or die "fd 9: $!"; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)'; then
  echo "merge: waiting for the merge lock, held by: $(cat "$lock" 2>/dev/null)" >&2
  perl -MFcntl=:flock -e 'open(my $f, ">&=9") or die "fd 9: $!"; flock($f, LOCK_EX) or die "flock: $!"'
fi
printf 'pid %s, worktree %s, since %s\n' $$ "$PWD" "$(date '+%F %T')" > "$lock"
ev lock-taken

# A wt merge killed between moving the target and syncing the target's checkout leaves that checkout's index
# at an older target: every later merge touching those paths is refused ("conflicting uncommitted changes"),
# and a commit made there would revert the merged work (lab/recover.sh R2). Under the lock
# nobody else is syncing it, so finish that sync: only when the index is exactly a recent target, which
# no human edit produces; real uncommitted work is left alone.
tw=$(git worktree list --porcelain | awk -v b="branch refs/heads/$target" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')
# A git command killed while it held an index.lock leaves the file behind, and every later git command in that
# checkout fails "index.lock: File exists" (lab/recover.sh R5; lab/race.sh N=10 ship seed 3017: a session stuck for
# 12 tries). Here: this worktree and the target's checkout, which wt merge writes. Older than MERGE_STALE_INDEX_LOCK
# seconds (60): left by a killed command, removed. Younger: a command may still be running there; stop and say so.
# The same for the target's ref lock and packed-refs.lock: a merge killed while git moved the target leaves
# refs/heads/<target>.lock, and every later merge fails "cannot lock ref": the queue never moves again (R7).
cd_=$(git rev-parse --path-format=absolute --git-common-dir)
for f in "$(git rev-parse --absolute-git-dir)/index.lock" ${tw:+"$(git -C "$tw" rev-parse --absolute-git-dir)/index.lock"} \
         "$cd_/refs/heads/$target.lock" "$cd_/packed-refs.lock"; do
  [ -f "$f" ] || continue
  if [ "$(perl -e 'print int(time - (stat shift)[9])' "$f")" -ge "${MERGE_STALE_INDEX_LOCK:-60}" ]; then
    rm -f "$f"; echo "merge: removed $f, left by a killed git command" >&2
    case $f in *index.lock) ev index-lock-removed ;; *) ev ref-lock-removed ;; esac
  else
    echo "merge: $f exists: a git command is running there, or one was killed less than ${MERGE_STALE_INDEX_LOCK:-60}s ago; retry later" >&2
    ev merge-done '"rc":1'; exit 1
  fi
done
if [ -n "$tw" ] && ! git -C "$tw" diff --cached --quiet "$target" 2>/dev/null; then
  it=$(git -C "$tw" write-tree 2>/dev/null || true)
  for k in 1 2 3 4 5 6 7 8; do
    c=$(git rev-parse -q --verify "$target@{$k}") || break
    [ "$(git rev-parse "$c^{tree}")" = "$it" ] || continue
    # a forward move only: after an owner's `git reset --soft` the index also equals a recent target, but the target went back
    git merge-base --is-ancestor "$c" "$target" || continue
    git -C "$tw" read-tree -m -u "$c" "$target" && { echo "merge: synced $tw to $target, left behind by an interrupted merge" >&2; ev target-resynced; }
    break
  done
fi

refuse_edited_merges
record_tip
# 9>&-: children do not inherit the lock, so a daemon left by a test cannot hold it forever (lab/lock.sh T6).
# ponytail: wt runs hooks in their own process group, so a SIGKILL of this merge leaves its pre-merge suite running
# next to the next holder's (lab/race.sh, overlap-orphan); main stays safe, the cost is two suites at once.
[ -z "${MERGE_PREPARE:-}" ] || sh -c "$MERGE_PREPARE" 9>&- || { echo "merge: MERGE_PREPARE failed: $MERGE_PREPARE" >&2; ev merge-done '"rc":1'; exit 1; }
moves="$cd_/wt-merge.moves"
# A merge.sh SIGKILLed after wt merge moved the target and before it wrote the move (and pushed it) leaves a move no
# fence knows; with MERGE_PUSH every later merge then stopped with 2 (R19i, lab/race.sh PUSH=1). Before wt merge the
# target and the branch are written to wt-merge.pending; that move is a merge commit on top of the target whose second
# parent is that branch's tip. The shape alone is not enough: an owner's own merge commit has it too (R19k).
pending="$cd_/wt-merge.pending"
if [ -f "$pending" ]; then
  read -r p0 pb < "$pending" || true; pt=$(git rev-parse "$target")
  if [ -n "${pb:-}" ] && [ "$pt" != "$p0" ] && [ "$(git rev-parse -q --verify "$pt^1")" = "$p0" ] &&
     [ "$(git rev-parse -q --verify "$pt^2")" = "$(git rev-parse -q --verify "refs/heads/$pb")" ] && ! by_merges "$p0" "$pt"; then
    printf '%s %s\n' "$p0" "$pt" >> "$moves"; echo "merge: recorded the move of a merge that was killed before it could ($p0..$pt)" >&2; ev pending-recorded
  fi
  rm -f "$pending"
fi
trap 'rm -f "$pending"' EXIT   # every exit but a kill: a pending record outlives only a killed merge.sh
# MERGE_PUSH=<remote>: the target is published there, and new worktrees start from <remote>/<target>. Under the lock the
# target first takes what the remote has, and a merge counts only once the remote took it: a rejected push (another
# machine pushed meanwhile) puts the target back and merges again on top (R19c); any other refusal puts it back, exit 1
# (R19f). A local commit on the target that no merge.sh made is the owner's: never published here, exit 2 (R19d).
rt=${MERGE_PUSH:+refs/remotes/$MERGE_PUSH/$target}
fetch_target() { GIT_TERMINAL_PROMPT=0 git fetch -q "$MERGE_PUSH" "+refs/heads/$target:$rt" 9>&- ||
  { echo "merge: git fetch $MERGE_PUSH $target failed (offline, no rights?); nothing merged" >&2; ev merge-done '"rc":1'; exit 1; }; }
push_target() { GIT_TERMINAL_PROMPT=0 git push -q "$MERGE_PUSH" "$1:refs/heads/$target" 9>&-; }
move_target() { # <to>: the target and its checkout to <to>, recorded as a move like a merge's (ship.sh's fence, R8)
  local from; from=$(git rev-parse "$target")
  if [ -n "$tw" ]; then git -C "$tw" reset -q --keep "$1"; else git update-ref "refs/heads/$target" "$1" "$from"; fi ||
    { echo "merge: cannot move $target to $1 in $tw (uncommitted changes there in the way?)" >&2; ev merge-done '"rc":1'; exit 1; }
  printf '%s %s\n' "$from" "$1" >> "$moves"
}
sync_remote() {
  fetch_target
  local r l; r=$(git rev-parse "$rt"); l=$(git rev-parse "$target")
  [ "$r" != "$l" ] || return 0
  if git merge-base --is-ancestor "$l" "$r"; then move_target "$r"; echo "merge: $target taken from $MERGE_PUSH ($l..$r)" >&2; ev target-pulled
  # ahead only by recorded merges: a kill came between a fast-forward and its push (R19e)
  elif git merge-base --is-ancestor "$r" "$l" && by_merges "$r" "$l"; then
    push_target "$l" || { echo "merge: $target has merges $MERGE_PUSH lacks, and pushing them failed; nothing merged" >&2; ev merge-done '"rc":1'; exit 1; }
    echo "merge: pushed merges of $target that an interrupted merge left unpushed" >&2; ev target-pushed
  else
    echo "merge: $target has commits that $MERGE_PUSH/$target lacks and no merge.sh made (an owner's local commit, or the two diverged): push or drop them by hand, then merge again" >&2
    ev merge-done '"rc":2'; exit 2
  fi
}
for try in 1 2 3 4 5; do
  [ -z "${MERGE_PUSH:-}" ] || sync_remote
  # --no-squash: a squash replaces the commit messages with "Squash commits from <branch>" and a list of
  # subjects, and the intent written into the bodies never reaches the target. --no-ff: the rebased branch comes in
  # under a merge commit whose tree the pre-merge hook tested, so every first-parent commit of the target is green; a
  # red commit inside the branch, fixed by a later one, stays on the second parent (seen with real agents: lab/swarm.sh).
  t0=$(git rev-parse "$target"); echo "$t0 $(git symbolic-ref -q --short HEAD)" > "$pending"
  rc=0; wt merge --yes --no-remove --no-squash --no-ff "$target" "$@" 9>&- || rc=$?
  [ $rc != 5 ] || rc=1
  if [ $rc = 0 ]; then landed || rc=$?; fi
  # Every move of the target made here, under the lock, as "<from> <to>": ship.sh lets a move through its fence only
  # when the whole chain from the target it saw to the current one is in this file (R8). An agent could forge a line;
  # the fence is against mistakes, not against an adversary. Only this merge's own move: the target now a merge commit
  # of the target read before wt merge and this branch's tip. A move someone else made while this merge ran is not a
  # merge: its fast-forward refused (R8b), or a commit slipped in before the rebase (R8e), which makes the merge's first
  # parent another commit. How many commits the branch brings is not checked: a conflict agent adds its own (R8f).
  # Grows a line per merge; trim if it ever matters.
  t1=$(git rev-parse "$target")
  own_move() { [ "$t1" != "$t0" ] && [ "$(git rev-parse -q --verify "$t1^1")" = "$t0" ] &&
    [ "$(git rev-parse -q --verify "$t1^2")" = "$(git rev-parse HEAD)" ]; }
  own=0; ! own_move || { own=1; printf '%s %s\n' "$t0" "$t1" >> "$moves"; }
  # a merge that moved the target is pushed even when it ends 5 (a recorded commit lost): left unpushed, the target
  # would differ from the remote's and every next merge would stop with 2 (R19h)
  [ -n "${MERGE_PUSH:-}" ] && [ $own = 1 ] && { [ $rc = 0 ] || [ $rc = 5 ]; } || break
  push_target "$t1" && { ev target-pushed; break; }
  # not on the remote, so not merged: the target and its checkout go back; the branch keeps its rebased commits
  [ $rc = 5 ] && { echo "merge: the push failed too; the next merge.sh pushes this merge (it is recorded)" >&2; break; }
  r0=$(git rev-parse "$rt"); fetch_target; move_target "$t0"; record_tip
  if [ "$(git rev-parse "$rt")" = "$r0" ]; then
    echo "merge: $MERGE_PUSH refused the push of $target (see above); $target is back at $t0, nothing merged" >&2; rc=1; break
  fi
  ev push-rejected; rc=1
  [ $try = 5 ] && { echo "merge: $MERGE_PUSH/$target moved during each of 5 tries; nothing merged, run it again" >&2; break; }
  echo "merge: $MERGE_PUSH/$target moved while this merge ran; merging again on top (try $try)" >&2
done
rm -f "$pending"
ev merge-done "\"rc\":$rc"
exit $rc
