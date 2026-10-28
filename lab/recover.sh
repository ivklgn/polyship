#!/usr/bin/env bash
# Deterministic replays of the failures found by lab/race.sh and by code review, run against bin/ of a checkout,
# once per target branch shape: `main`, `master`, and MERGE_TARGET=develop in a repository that also has `main`.
#
#   R1  a rebase killed right after it checked out the target, then `git rebase --continue` (what a session does on
#       "rebase in progress"): the rebase finishes with no commit picked, the branch sits on the target. Must not be
#       reported as merged: merge.sh and ship.sh must exit 5 and name the commit to restore.
#   R2  a wt merge killed after it moved the target and before it synced the target's checkout: that checkout's
#       index is at the old target. The next merge of a branch touching the same file must land; the owner's own
#       staged work there (a soft reset, a staged file) must survive.
#   R3  two sessions make the same change; the second rebase drops its commit as already applied. That is a merge,
#       not a loss: exit 0, not 5.
#   R4  a pre-merge hook that exits 5 (pytest: no tests collected) is a red merge, not lost commits: exit 1.
#   R5  a git command killed while it held index.lock (in the branch's worktree or in the target's checkout): an
#       old lock is removed and the merge lands; a fresh one (a command may still run) stops with exit 1 and a reason.
#   R6  a duplicate with a different patch landed first: the original's rebase drops it as empty by itself (exit 0:
#       applying it changes nothing), or stops on a conflict whose right resolution is "already there" and the agent
#       skips it, naming it in merge-dropped (exit 0). A commit half on the target and not named there: still exit 5.
#   R7  a merge killed while git moved the target leaves refs/heads/<target>.lock: an old one is removed and the
#       merge lands; a fresh one stops with exit 1 and a reason (lab/race.sh H.retry seed 4020: the queue never moved).
#   R8  ship.sh's fence while its conflict agent runs: another session's merge.sh moving the target goes through
#       (no exit 4, the branch lands); the agent moving the target itself, alone or under a later merge, is exit 4.
#   R1b R1 through ship.sh's own rebase before the tests: it records the tip first, so a branch that lost its commit
#       there is exit 5, not "already on the target" (review B2).
#   R1c the same with an old index.lock left in the worktree by the kill: ship.sh removes it at the start, so the restore
#       its exit 5 names can run, and the branch lands (stress probe of the rebase before the tests, 1 in 300).
#   R1d the same with the lost commit's file left in the tree, untracked: exit 5 comes before "uncommitted changes" (2),
#       so the session learns the commit is lost (stress probe, 1 in 300). R5b: an old HEAD.lock in the worktree is removed.
#   R1e the R1 aftermath with the session's own uncommitted change: exit 5 also says to git stash -u first, so the
#       reset it names cannot delete that change (review 2, B2).
#   R8d SHIP_AGENT_RUN names this repository only: merge.sh in another repository under it merges (review 2, B1).
#   R8e a move made between merge.sh reading the target and wt merge's rebase is not recorded as this merge (m1).
#   R6c a lost commit whose change conflicts with the target (modify/delete): merge-tree keeps the target's side, so
#       "applying it changes nothing" is not proof; still exit 5 (review B1).
#   R8b the target moved by someone else while a merge.sh holds the lock and its fast-forward is refused: that move is not
#       recorded as a merge, so a session whose agent ran meanwhile gets exit 4 (review B3).
#   R8c ship.sh's agent cannot run merge.sh itself (review Q1).
#   R10c a kill after the rebase moved the branch to its result but before it removed its state: --continue can never
#       pass ("is at X but expected Y"); ship.sh closes that finished rebase and goes on (stress probe, 3 in 300).
#   R10b the same with rebase-merge/git-rebase-todo.lock left by a kill while git wrote the todo (race C30, final).
#   R10 a session killed inside `git rebase --continue` leaves the rebase open and refs/heads/<branch>.lock: ship.sh
#       says a rebase is open (not "on HEAD"), removes the old lock, and once the session finishes the rebase it lands.
#   R9  a branch that needs a change another session landed: ship.sh tests it on the current target, not on its old
#       base, so it lands instead of exiting 1 forever (lab/race.sh H.retry: 15 consumers).
#
#   R19 MERGE_PUSH: the merge reaches the remote (R19); a remote ahead is taken first (R19b); a push rejected because another
#       machine pushed during the merge puts the target back and merges again on top (R19c); an owner's unpushed local
#       commit is never published, exit 2 (R19d); a merge left unpushed by a kill goes out with the next one (R19e); a push
#       the remote refuses puts the target and its checkout back, exit 1 (R19f); ship.sh's fence passes a pushed merge (R19g).
#   R8f a commit the conflict agent adds while resolving: the merge is still recorded as this merge's move.
#   R12b an empty merge-orig left by a kill while it was written: rewritten; the merge recorded and pushed.
#   R19i a merge.sh killed after its merge commit, before its moves line and push: the next one records and pushes it.
#   R19j ship.sh on a branch merged but not pushed pushes it before it says shipped; R19k an owner's merge commit on
#       top of a stale pending record is exit 2, never published.
#   R20 a red commit fixed later on the same branch stays off the target's first-parent history (merge commit, --no-ff).
#   R21 a kill inside ship.sh's rebase before the tests leaves CHERRY_PICK_HEAD with no rebase, or a rebase-merge/ without
#       head-name: with the branch checked out and a clean tree ship.sh clears it and lands (R21, R21b); with an
#       uncommitted edit it leaves it alone, exit 2 (R21c) (lab/kill-stress.sh STUCK, about 3 in 550).
#   R22 SHIP_AGENT=codex finishes a conflict: Codex's workspace-write sandbox keeps a worktree's git dir read-only, so
#       ship.sh runs it without one (the real sandbox on macOS with codex, an imitation of its refusal elsewhere).
#
#   lab/recover.sh                 against bin/ of this checkout
#   BIN=<dir> lab/recover.sh       against another copy (for the before/after comparison)
set -uo pipefail
unset MERGE_PREPARE MERGE_TARGET MERGE_EVENTS  # the stand builds its own repos; the caller's merge config (pnpm ship exports MERGE_PREPARE) must not reach them
HERE=$(cd "$(dirname "$0")/.." && pwd); BIN=${BIN:-$HERE/bin}
LAB=$(mktemp -d /tmp/wt-recover.XXXXXX); trap 'rm -rf "$LAB"' EXIT
status=0
ok() { echo "PASS [$T] $1"; }; bad() { echo "FAIL [$T] $1"; status=1; }
repo() { # fresh repo with the target checked out and one shared file; for develop, a `main` branch exists too
  rm -rf "$LAB/r" "$LAB"/r.*; git init -q -b "$T" "$LAB/r"; cd "$LAB/r" || exit 1
  printf 'a\nb\nc\n' > f.txt; git add f.txt; git commit -qm init
  git config merge.conflictStyle merge
  [ "$T" != develop ] || git branch main
}
branch() { git -C "$LAB/r" worktree add -q -b "$1" "$LAB/r.$1" "$T"; }

run() { # <target>
T=$1; if [ "$T" = develop ]; then export MERGE_TARGET=develop; else unset MERGE_TARGET; fi

# --- R1 ----------------------------------------------------------------------------------------------
repo; branch s1; branch s2
echo s1 >> "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: own line"
echo s2 > "$LAB/r.s2/g.txt"; git -C "$LAB/r.s2" add g.txt; git -C "$LAB/r.s2" commit -qm "s2: new file (intent: keep it)"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)             # the target moves, so s2 needs a rebase
rc=0; (cd "$LAB/r.s2" && MERGE_PREPARE=false "$BIN/merge.sh" >/dev/null 2>&1) || rc=$?   # record_tip runs, then the failed prepare stops it before wt merge
o=$(cat "$(git -C "$LAB/r.s2" rev-parse --git-dir)/merge-orig" 2>/dev/null)
[ "$o" = "$(git -C "$LAB/r.s2" rev-parse HEAD)" ] && [ $rc = 1 ] && [ "$(git -C "$LAB/r" rev-parse s1)" = "$(git -C "$LAB/r" rev-parse "$T^2")" ] ||
  bad "R1 setup: merge.sh with a failing MERGE_PREPARE: exit $rc (want 1), tip recorded '$o', target moved?"
# The state a SIGKILL leaves inside git's sequencer between saving the todo and applying the pick: the pick line is
# already in rebase-merge/done, gone from git-rebase-todo, and nothing is applied. (lab/race.sh hit it: reflog
# "rebase (start): checkout main" then "rebase (finish)" with no pick.) Built here with a `break` and a moved line.
(cd "$LAB/r.s2" && GIT_SEQUENCE_EDITOR="perl -i -pe 'print qq(break\n) if \$.==1'" git rebase -i "$T" >/dev/null 2>&1)
gd=$(git -C "$LAB/r.s2" rev-parse --git-dir)
grep '^pick' "$gd/rebase-merge/git-rebase-todo" >> "$gd/rebase-merge/done"; perl -i -ne 'print unless /^pick/' "$gd/rebase-merge/git-rebase-todo"
(cd "$LAB/r.s2" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
if git -C "$LAB/r.s2" merge-base --is-ancestor s2 "$T" && ! git -C "$LAB/r" cat-file -e "$T:g.txt" 2>/dev/null; then
  echo "     reproduced [$T]: s2 sits on the target, its g.txt is not there ($(git -C "$LAB/r.s2" reflog -1 --format=%gs s2))"
  rc=0; (cd "$LAB/r.s2" && "$BIN/merge.sh" > "$LAB/r1.merge.log" 2>&1) || rc=$?
  [ $rc = 5 ] && grep -qF "git reset --hard $o" "$LAB/r1.merge.log" && grep -qF "s2: new file" "$LAB/r1.merge.log" && ok "R1 merge.sh exit 5 with the restore command" || bad "R1 merge.sh exit $rc, expected 5 naming $o (it reports a lost commit as merged)"
  rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r1.ship.log" 2>&1) || rc=$?
  [ $rc = 5 ] && ok "R1 ship.sh exit 5" || bad "R1 ship.sh exit $rc, expected 5 ($(tail -1 "$LAB/r1.ship.log"))"
  # following the message lands the work
  git -C "$LAB/r.s2" reset -q --hard "$o" &&
    (cd "$LAB/r.s2" && "$BIN/merge.sh" >/dev/null 2>&1) && git -C "$LAB/r" cat-file -e "$T:g.txt" &&
    ok "R1 restore by the message, then merge: g.txt on the target" || bad "R1 restore and merge did not land g.txt"
else
  bad "R1 setup: the simulated state kept the commit ($(git --version))"
fi

# --- R2 ----------------------------------------------------------------------------------------------
repo; branch s1; branch s2
sed -i.bak 's/^a$/a s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: edit line a"
sed -i.bak 's/^c$/c s2/' "$LAB/r.s2/f.txt"; rm "$LAB/r.s2/f.txt.bak"; git -C "$LAB/r.s2" commit -qam "s2: edit line c"
# s1's merge killed between update-ref and the checkout sync: the target moves, its checkout does not
git -C "$LAB/r.s1" rebase -q "$T"; git -C "$LAB/r" update-ref -m "wt merge: fast-forward" "refs/heads/$T" "$(git -C "$LAB/r.s1" rev-parse HEAD)"
git -C "$LAB/r" diff --cached --quiet "$T" && bad "R2 setup: the target checkout is in sync" || echo "     reproduced [$T]: the target checkout's index is at the old target ($(git -C "$LAB/r" status --short | tr '\n' ' '))"
rc=0; (cd "$LAB/r.s2" && "$BIN/merge.sh" > "$LAB/r2.log" 2>&1) || rc=$?
if [ $rc = 0 ] && git -C "$LAB/r" show "$T:f.txt" | grep -q "c s2" && git -C "$LAB/r" show "$T:f.txt" | grep -q "a s1"; then
  git -C "$LAB/r" diff --quiet "$T" && git -C "$LAB/r" diff --cached --quiet "$T" && ok "R2 next merge landed, target checkout in sync" || bad "R2 landed but the target checkout is still out of sync"
else
  bad "R2 next merge exit $rc: $(grep -m1 '✗' "$LAB/r2.log")"
fi
# real uncommitted work in the target checkout is never touched
# 1) the owner's `git reset --soft HEAD~1`: the index equals target@{1}'s tree like R2, but the target went back, not forward
git -C "$LAB/r" reset -q --soft HEAD~1
branch s3; echo s3 > "$LAB/r.s3/h.txt"; git -C "$LAB/r.s3" add h.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
rc=0; (cd "$LAB/r.s3" && "$BIN/merge.sh" >/dev/null 2>&1) || rc=$?
git -C "$LAB/r" diff --cached "$T" -- f.txt | grep -q "c s2" && grep -q "c s2" "$LAB/r/f.txt" && [ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:h.txt" &&
  ok "R2 the owner's soft-reset work in the target checkout stays staged, s3 landed" || bad "R2 the owner's soft-reset work was wiped by the re-sync (merge exit $rc)"
git -C "$LAB/r" commit -qm "owner: redo s2" >/dev/null 2>&1 || true
# 2) a staged new file
echo owner > "$LAB/r/owner.txt"; git -C "$LAB/r" add owner.txt
branch s4; echo s4 > "$LAB/r.s4/i.txt"; git -C "$LAB/r.s4" add i.txt; git -C "$LAB/r.s4" commit -qm "s4: new file"
rc=0; (cd "$LAB/r.s4" && "$BIN/merge.sh" >/dev/null 2>&1) || rc=$?
git -C "$LAB/r" diff --cached --name-only | grep -qx owner.txt && [ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:i.txt" && ok "R2 the owner's staged file in the target checkout stays staged, s4 landed" || bad "R2 the owner's staged file was lost (merge exit $rc)"

# --- R3 ----------------------------------------------------------------------------------------------
repo; branch s1; branch s2
for b in s1 s2; do sed -i.bak 's/^b$/b fixed/' "$LAB/r.$b/f.txt"; rm "$LAB/r.$b/f.txt.bak"; git -C "$LAB/r.$b" commit -qam "$b: the same lint fix"; sleep 1; done
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s2" && "$BIN/merge.sh" > "$LAB/r3.log" 2>&1) || rc=$?
[ $rc = 0 ] && ok "R3 a change already on the target, dropped by the rebase: exit 0" || bad "R3 merge.sh exit $rc for a change already on the target ($(grep -m1 'not on' "$LAB/r3.log"))"

# --- R4 ----------------------------------------------------------------------------------------------
repo; branch s1
mkdir -p "$LAB/r/.config"; printf '[pre-merge]\nsuite = "exit 5"\n' > "$LAB/r/.config/wt.toml"; git -C "$LAB/r" add .config; git -C "$LAB/r" commit -qm "hook that exits 5"
git -C "$LAB/r.s1" rebase -q "$T"; (cd "$LAB/r" && wt config approvals add --yes >/dev/null 2>&1)
echo s1 > "$LAB/r.s1/j.txt"; git -C "$LAB/r.s1" add j.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r4.log" 2>&1) || rc=$?
[ $rc = 1 ] && ! git -C "$LAB/r" cat-file -e "$T:j.txt" 2>/dev/null && ok "R4 a pre-merge hook's exit 5 is exit 1, the target unmoved" || bad "R4 merge.sh exit $rc for a hook that exits 5 (want 1; 5 means lost commits)"

# --- R5 ----------------------------------------------------------------------------------------------
old() { touch -t "$(perl -MPOSIX -e 'print strftime("%Y%m%d%H%M.%S", localtime(time - 120))')" "$1"; }  # 2 minutes ago
repo; branch s1; branch s2
echo s1 > "$LAB/r.s1/k.txt"; git -C "$LAB/r.s1" add k.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
gd=$(git -C "$LAB/r.s1" rev-parse --git-dir); : > "$gd/index.lock"
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r5.log" 2>&1) || rc=$?
[ $rc = 1 ] && [ -f "$gd/index.lock" ] && grep -q "index.lock exists" "$LAB/r5.log" && ok "R5 a fresh index.lock: exit 1 with the reason, lock kept" || bad "R5 a fresh index.lock: exit $rc, lock kept? $([ -f "$gd/index.lock" ] && echo yes || echo no)"
old "$gd/index.lock"
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r5.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:k.txt" && ok "R5 an old index.lock in the worktree: removed, merge landed" || bad "R5 an old index.lock in the worktree: exit $rc ($(grep -m1 -E 'index.lock|✗' "$LAB/r5.log"))"
echo s2 > "$LAB/r.s2/l.txt"; git -C "$LAB/r.s2" add l.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
: > "$LAB/r/.git/index.lock"; old "$LAB/r/.git/index.lock"
rc=0; (cd "$LAB/r.s2" && "$BIN/merge.sh" > "$LAB/r5.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:l.txt" && git -C "$LAB/r" diff --quiet "$T" && ok "R5 an old index.lock in the target checkout: removed, merge landed, checkout in sync" || bad "R5 an old index.lock in the target checkout: exit $rc ($(grep -m1 -E 'index.lock|✗' "$LAB/r5.log"))"

# --- R6 ----------------------------------------------------------------------------------------------
repo; branch c; branch d; branch a
sed -i.bak 's/^b$/b c-edit/' "$LAB/r.c/f.txt"; git -C "$LAB/r.c" commit -qam "c: its own edit of line b"
for b in d a; do sed -i.bak 's/^b$/b fixed/' "$LAB/r.$b/f.txt"; git -C "$LAB/r.$b" commit -qam "$b: the same fix of line b"; sleep 1; done
rm -f "$LAB"/r.*/f.txt.bak
(cd "$LAB/r.c" && "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.d" && "$BIN/merge.sh" >/dev/null 2>&1)   # conflict with c: d's agent keeps both
printf 'a\nb fixed c-edit\nc\n' > "$LAB/r.d/f.txt"; git -C "$LAB/r.d" add f.txt; (cd "$LAB/r.d" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
(cd "$LAB/r.d" && "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.a" && "$BIN/merge.sh" >/dev/null 2>&1)   # conflict: main already has a's fix through d
# the agent, as ship.sh's conflict prompt says: the intent is there, name the commit in merge-dropped, skip it
gd=$(git -C "$LAB/r.a" rev-parse --git-dir)
(cd "$LAB/r.a" && git rev-parse REBASE_HEAD >> "$gd/merge-dropped" && git checkout -q --ours f.txt && git add f.txt && git rebase --skip >/dev/null 2>&1)
rc=0; (cd "$LAB/r.a" && "$BIN/merge.sh" > "$LAB/r6.log" 2>&1) || rc=$?
[ $rc = 0 ] && [ ! -f "$gd/merge-dropped" ] && ok "R6 a duplicate on the target through a conflict, named by the agent and skipped: exit 0" || bad "R6 merge.sh exit $rc for a duplicate the agent named ($(grep -m1 'not on' "$LAB/r6.log"))"
# R6b: the same fix twice, the duplicate also adds a file (so its patch differs): the original's rebase drops its commit
# as empty by itself, no conflict, no agent to name it. Applying it to the target changes nothing: exit 0
repo; branch d; branch a
sed -i.bak 's/^b$/b fixed/' "$LAB/r.d/f.txt"; rm "$LAB/r.d/f.txt.bak"; echo d > "$LAB/r.d/d.txt"; git -C "$LAB/r.d" add -A; git -C "$LAB/r.d" commit -qm "d: fix line b, and a note"
sleep 1; sed -i.bak 's/^b$/b fixed/' "$LAB/r.a/f.txt"; rm "$LAB/r.a/f.txt.bak"; git -C "$LAB/r.a" commit -qam "a: fix line b"
(cd "$LAB/r.d" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.a" && "$BIN/merge.sh" > "$LAB/r6c.log" 2>&1) || rc=$?
[ $rc = 0 ] && ok "R6 a duplicate the rebase dropped as empty by itself: exit 0" || bad "R6 a duplicate dropped as empty by the rebase: merge.sh exit $rc ($(grep -m1 'not on' "$LAB/r6c.log"))"
# R1 must still hold with R6: a commit whose change is not in the target is lost (covered above); and a partial one
repo; branch s1
printf 'x\n' > "$LAB/r.s1/m.txt"; sed -i.bak 's/^a$/a s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" add -A; git -C "$LAB/r.s1" commit -qm "s1: two changes"
echo "$(git -C "$LAB/r.s1" rev-parse HEAD)" > "$(git -C "$LAB/r.s1" rev-parse --git-dir)/merge-orig"
git -C "$LAB/r" checkout -q "$T" 2>/dev/null; sed -i.bak 's/^a$/a s1/' "$LAB/r/f.txt"; rm "$LAB/r/f.txt.bak"; git -C "$LAB/r" commit -qam "owner: half of s1"
git -C "$LAB/r.s1" reset -q --hard "$T"
git -C "$LAB/r" rev-parse "$T" > "$(git -C "$LAB/r.s1" rev-parse --git-dir)/merge-dropped"   # names another commit
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r6b.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R6 a commit half on the target, not named in merge-dropped: still exit 5" || bad "R6 a half-lost commit: exit $rc, expected 5"

# --- R7 ----------------------------------------------------------------------------------------------
repo; branch s1
echo s1 > "$LAB/r.s1/n.txt"; git -C "$LAB/r.s1" add n.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
rl="$LAB/r/.git/refs/heads/$T.lock"; git -C "$LAB/r" rev-parse "$T" > "$rl"
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r7.log" 2>&1) || rc=$?
[ $rc = 1 ] && [ -f "$rl" ] && grep -q "$T.lock exists" "$LAB/r7.log" && ok "R7 a fresh ref lock: exit 1 with the reason, lock kept" || bad "R7 a fresh ref lock: exit $rc, lock kept? $([ -f "$rl" ] && echo yes || echo no) ($(grep -m1 -i lock "$LAB/r7.log"))"
old "$rl"
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r7.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:n.txt" && ok "R7 an old ref lock: removed, merge landed" || bad "R7 an old ref lock: exit $rc ($(grep -m1 -i 'lock' "$LAB/r7.log"))"

# --- R8 ----------------------------------------------------------------------------------------------
# a stub agent on PATH: resolves the conflict by keeping the branch's side; STUB_ALSO says what else happens meanwhile
# (another session's merge.sh runs with env -u SHIP_AGENT_RUN: it is not a child of this agent)
mkdir -p "$LAB/bin"; cat > "$LAB/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
case "${STUB_ALSO:-}" in
  other-merge) (cd "$STUB_OTHER" && env -u SHIP_AGENT_RUN "$STUB_BIN/merge.sh" >/dev/null 2>&1) ;;
  agent-moves) t=$(git rev-parse "$STUB_T"); c=$(git commit-tree -p "$t" -m "agent: moved the target" "$t^{tree}"); git update-ref "refs/heads/$STUB_T" "$c" ;;
  agent-then-merge) t=$(git rev-parse "$STUB_T"); c=$(git commit-tree -p "$t" -m "agent: moved the target" "$t^{tree}"); git update-ref "refs/heads/$STUB_T" "$c"
                    (cd "$STUB_OTHER" && env -u SHIP_AGENT_RUN "$STUB_BIN/merge.sh" >/dev/null 2>&1) ;;
  # another session's merge.sh caught between its fast-forward and the line it writes in wt-merge.moves: it holds the
  # lock, moves the target, and writes the line a second later
  agent-merges) git checkout -q --theirs f.txt && git add f.txt && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
    r=0; "$STUB_BIN/merge.sh" >/dev/null 2>&1 || r=$?; echo "$r" > "$STUB_RC"; echo RESOLVED; exit 0 ;;
  mid-merge) cd_=$(git rev-parse --path-format=absolute --git-common-dir)
    ( exec 7>>"$cd_/wt-merge.lock"; perl -MFcntl=:flock -e 'open(my $f, ">&=7") or die; flock($f, LOCK_EX) or die'
      t=$(git rev-parse "$STUB_T"); c=$(git commit-tree -p "$t" -m "another session" "$t^{tree}"); git update-ref "refs/heads/$STUB_T" "$c"
      touch "$cd_/mid-merge.moved"; sleep 1; printf '%s %s\n' "$t" "$c" >> "$cd_/wt-merge.moves" ) >/dev/null 2>&1 &   # not on the agent's output: ship.sh would wait for it
    while [ ! -f "$cd_/mid-merge.moved" ]; do sleep 0.05; done ;;
esac
git checkout -q --theirs f.txt && git add f.txt && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
echo RESOLVED
STUB
chmod +x "$LAB/bin/claude"
for also in other-merge mid-merge agent-moves agent-then-merge; do
  repo; branch s1; branch s2; branch s3
  sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: line b"
  sed -i.bak 's/^b$/b s2/' "$LAB/r.s2/f.txt"; git -C "$LAB/r.s2" commit -qam "s2: line b"
  echo s3 > "$LAB/r.s3/o.txt"; git -C "$LAB/r.s3" add o.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
  rm -f "$LAB"/r.*/f.txt.bak
  (cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
  rc=0; (cd "$LAB/r.s2" && PATH="$LAB/bin:$PATH" STUB_ALSO=$also STUB_OTHER="$LAB/r.s3" STUB_BIN="$BIN" STUB_T="$T" SHIP_REVIEW=0 SHIP_TEST=true SHIP_AGENT=claude "$BIN/ship.sh" > "$LAB/r8.log" 2>&1) || rc=$?
  case $also in
    other-merge) [ $rc = 0 ] && git -C "$LAB/r" merge-base --is-ancestor s2 "$T" && git -C "$LAB/r" cat-file -e "$T:o.txt" && ok "R8 another session's merge during the agent run: no exit 4, s2 landed" || bad "R8 another session's merge during the agent run: ship.sh exit $rc ($(tail -1 "$LAB/r8.log"))" ;;
    mid-merge) [ $rc = 0 ] && git -C "$LAB/r" merge-base --is-ancestor s2 "$T" && ok "R8 another session's merge not yet recorded when the agent ends: waits for the lock, no exit 4" || bad "R8 a merge not yet recorded when the agent ends: ship.sh exit $rc ($(grep 'ship:' "$LAB/r8.log" | tail -1))" ;;
    *) [ $rc = 4 ] && ok "R8 the agent moved the target ($also): exit 4" || bad "R8 the agent moved the target ($also): ship.sh exit $rc, expected 4" ;;
  esac
done

# --- R1b ---------------------------------------------------------------------------------------------
repo; branch s1; branch s2
echo s1 >> "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: own line"
echo s2 > "$LAB/r.s2/g.txt"; git -C "$LAB/r.s2" add g.txt; git -C "$LAB/r.s2" commit -qm "s2: new file (intent: keep it)"
tip=$(git -C "$LAB/r.s2" rev-parse HEAD)
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
# ship.sh rebases s2 onto the moved target before its tests; red tests stop it there
(cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=false "$BIN/ship.sh" >/dev/null 2>&1)
o=$(cat "$(git -C "$LAB/r.s2" rev-parse --git-dir)/merge-orig" 2>/dev/null)
# what a SIGKILL inside that rebase leaves once the session continues it (R1): the branch on the target, the commit gone
git -C "$LAB/r.s2" reset -q --hard "$T"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r1b.log" 2>&1) || rc=$?
[ "$o" = "$tip" ] && [ $rc = 5 ] && ok "R1b ship.sh records the tip before its own rebase; the lost commit is exit 5" || bad "R1b tip recorded '$o' (want $tip), ship.sh exit $rc (want 5): $(tail -1 "$LAB/r1b.log")"
# R1c: the kill also left index.lock: without its removal the restore fails and every ship.sh is exit 5 again
il="$(git -C "$LAB/r.s2" rev-parse --git-dir)/index.lock"; : > "$il"; old "$il"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r1c.log" 2>&1) || rc=$?
rr=0; git -C "$LAB/r.s2" reset -q --hard "$tip" 2>/dev/null || rr=$?
rc2=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" >/dev/null 2>&1) || rc2=$?
[ $rc = 5 ] && [ $rr = 0 ] && [ $rc2 = 0 ] && git -C "$LAB/r" cat-file -e "$T:g.txt" && ok "R1c an old index.lock with the lost commit: removed at the start, the restore runs, the branch lands" || bad "R1c old index.lock: ship.sh exit $rc, restore rc $rr, then ship.sh exit $rc2"
# R1d: the R1 aftermath of ship.sh's rebase, with the lost commit's file left untracked by the kill
repo; branch s1; branch s2
echo s1 >> "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: own line"
echo s2 > "$LAB/r.s2/g.txt"; git -C "$LAB/r.s2" add g.txt; git -C "$LAB/r.s2" commit -qm "s2: new file (intent: keep it)"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=false "$BIN/ship.sh" >/dev/null 2>&1)
git -C "$LAB/r.s2" reset -q --hard "$T"; echo s2 > "$LAB/r.s2/g.txt"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r1d.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R1d the lost commit's file left untracked: exit 5, not 2" || bad "R1d lost commit with its file untracked: ship.sh exit $rc, expected 5 ($(grep 'ship:' "$LAB/r1d.log" | tail -1))"
rm -f "$LAB/r.s2/g.txt"
# R1e: the same aftermath, and the session has edited a tracked file since: the reset exit 5 names would delete it
git -C "$LAB/r.s2" reset -q --hard "$T"; echo "the session's own edit" >> "$LAB/r.s2/f.txt"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r1e.log" 2>&1) || rc=$?
[ $rc = 5 ] && grep -q "git stash -u" "$LAB/r1e.log" && ok "R1e lost commit and uncommitted work: exit 5 says git stash -u before the reset" || bad "R1e lost commit with uncommitted work: ship.sh exit $rc, stash advice? $(grep -c 'git stash -u' "$LAB/r1e.log")"
git -C "$LAB/r.s2" checkout -q -- f.txt
# R5b: an old HEAD.lock in the worktree (a killed checkout): the rebase before the tests must write HEAD, so the target moves first
repo; branch s0; branch s1
echo s0 > "$LAB/r.s0/j.txt"; git -C "$LAB/r.s0" add j.txt; git -C "$LAB/r.s0" commit -qm "s0: new file"
echo s1 > "$LAB/r.s1/k.txt"; git -C "$LAB/r.s1" add k.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
(cd "$LAB/r.s0" && "$BIN/merge.sh" >/dev/null 2>&1)
hl="$(git -C "$LAB/r.s1" rev-parse --git-dir)/HEAD.lock"; : > "$hl"; old "$hl"
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r5b.log" 2>&1) || rc=$?
[ $rc = 0 ] && [ ! -f "$hl" ] && grep -q "tests before the queue" "$LAB/r5b.log" && git -C "$LAB/r" cat-file -e "$T:k.txt" && ok "R5b an old HEAD.lock: removed, the rebase before the tests runs, landed" || bad "R5b an old HEAD.lock: ship.sh exit $rc, lock kept? $([ -f "$hl" ] && echo yes || echo no), tests ran? $(grep -c 'tests before the queue' "$LAB/r5b.log")"

# --- R6c ---------------------------------------------------------------------------------------------
repo; branch s1
echo x > "$LAB/r/x.txt"; git -C "$LAB/r" add x.txt; git -C "$LAB/r" commit -qm "x"; git -C "$LAB/r.s1" rebase -q "$T"
git -C "$LAB/r.s1" rm -q x.txt; git -C "$LAB/r.s1" commit -qm "s1: delete x"
git -C "$LAB/r.s1" rev-parse HEAD > "$(git -C "$LAB/r.s1" rev-parse --git-dir)/merge-orig"
echo y >> "$LAB/r/x.txt"; git -C "$LAB/r" commit -qam "owner: change x"
git -C "$LAB/r.s1" reset -q --hard "$T"     # the R1 aftermath: on the target, the deletion gone
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r6c.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R6c a lost deletion that conflicts with the target: exit 5" || bad "R6c a lost deletion that conflicts with the target: merge.sh exit $rc, expected 5"

# --- R8b, R8c ----------------------------------------------------------------------------------------
# R8b: s3's pre-merge hook moves the target as another process would; s3's fast-forward is then refused
repo
mkdir -p "$LAB/r/.config"
printf '[pre-merge]\nmove = "sh -c '"'"'[ \\"$(git rev-parse --abbrev-ref HEAD)\\" = s3 ] || exit 0; t=$(git rev-parse %s); c=$(git commit-tree -p $t -m outsider $t^{tree}); git update-ref refs/heads/%s $c'"'"'"\n' "$T" "$T" > "$LAB/r/.config/wt.toml"
git -C "$LAB/r" add .config; git -C "$LAB/r" commit -qm "a hook that moves the target during s3's merge"; (cd "$LAB/r" && wt config approvals add --yes >/dev/null 2>&1)
branch s1; branch s2; branch s3
sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: line b"
sed -i.bak 's/^b$/b s2/' "$LAB/r.s2/f.txt"; rm "$LAB/r.s2/f.txt.bak"; git -C "$LAB/r.s2" commit -qam "s2: line b"
echo s3 > "$LAB/r.s3/o.txt"; git -C "$LAB/r.s3" add o.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s2" && PATH="$LAB/bin:$PATH" STUB_ALSO=other-merge STUB_OTHER="$LAB/r.s3" STUB_BIN="$BIN" STUB_T="$T" SHIP_REVIEW=0 SHIP_TEST=true SHIP_AGENT=claude "$BIN/ship.sh" > "$LAB/r8b.log" 2>&1) || rc=$?
[ $rc = 4 ] && ok "R8b a target move inside another merge whose fast-forward was refused: not recorded, exit 4" || bad "R8b a target move inside a refused merge: ship.sh exit $rc, expected 4 ($(grep 'ship:' "$LAB/r8b.log" | tail -1))"
# R8c: the agent tries to merge its own branch itself
repo; branch s1; branch s2
sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: line b"
sed -i.bak 's/^b$/b s2/' "$LAB/r.s2/f.txt"; rm "$LAB/r.s2/f.txt.bak"; git -C "$LAB/r.s2" commit -qam "s2: line b"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s2" && PATH="$LAB/bin:$PATH" STUB_ALSO=agent-merges STUB_BIN="$BIN" STUB_T="$T" STUB_RC="$LAB/r8c.rc" SHIP_REVIEW=0 SHIP_TEST=true SHIP_AGENT=claude "$BIN/ship.sh" > "$LAB/r8c.log" 2>&1) || rc=$?
[ "$(cat "$LAB/r8c.rc" 2>/dev/null)" = 2 ] && [ $rc = 0 ] && ok "R8c merge.sh refuses to run under ship.sh's agent; ship.sh lands the branch itself" || bad "R8c the agent's own merge.sh: exit $(cat "$LAB/r8c.rc" 2>/dev/null) (want 2), ship.sh exit $rc (want 0)"

# R10c: the rebase picked and moved the branch, the kill came before it removed rebase-merge/
repo; branch s1; branch s2
sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: line b"
echo s2 > "$LAB/r.s2/h.txt"; git -C "$LAB/r.s2" add h.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.s2" && GIT_SEQUENCE_EDITOR="perl -i -pe 'print qq(break\\n) if eof'" git rebase -i "$T" >/dev/null 2>&1)
git -C "$LAB/r.s2" update-ref refs/heads/s2 HEAD    # what the rebase's last step does; the kill comes right after it
(cd "$LAB/r.s2" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1) && bad "R10c setup: --continue passed"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r10c.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:h.txt" && ok "R10c a finished rebase whose state the kill left: closed, the branch lands" || bad "R10c a finished rebase left open: ship.sh exit $rc ($(grep 'ship:' "$LAB/r10c.log" | tail -1))"
# --- R8d, R8e ----------------------------------------------------------------------------------------
# R8d: the marker of another repository's agent does not stop a merge here
repo; branch s1
echo s1 > "$LAB/r.s1/p.txt"; git -C "$LAB/r.s1" add p.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
rc=0; (cd "$LAB/r.s1" && SHIP_AGENT_RUN=/some/other/repo/.git "$BIN/merge.sh" > "$LAB/r8d.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:p.txt" && ok "R8d under another repository's SHIP_AGENT_RUN: merge.sh merges here" || bad "R8d another repository's marker: merge.sh exit $rc ($(tail -1 "$LAB/r8d.log"))"
# R8e: a wt that first moves the target as an outsider would, after merge.sh read it, then runs the real wt merge
repo; branch s1
echo s1 > "$LAB/r.s1/q.txt"; git -C "$LAB/r.s1" add q.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
realwt=$(command -v wt); rm -rf "$LAB/wtwrap"; mkdir -p "$LAB/wtwrap"
cat > "$LAB/wtwrap/wt" <<WT
#!/usr/bin/env bash
if [ "\$1" = merge ] && [ ! -f "$LAB/wtwrap/moved" ]; then
  touch "$LAB/wtwrap/moved"; t=\$(git rev-parse $T); c=\$(git commit-tree -p \$t -m outsider \$t^{tree}); git update-ref refs/heads/$T \$c
fi
exec "$realwt" "\$@"
WT
chmod +x "$LAB/wtwrap/wt"
t0=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s1" && PATH="$LAB/wtwrap:$PATH" "$BIN/merge.sh" > "$LAB/r8e.log" 2>&1) || rc=$?
grep -q "^$t0 " "$LAB/r/.git/wt-merge.moves" 2>/dev/null && bad "R8e a move between merge.sh's read and the rebase: recorded as this merge (merge.sh exit $rc)" || ok "R8e a move between merge.sh's read and the rebase: not recorded (merge.sh exit $rc)"

# --- R9 ----------------------------------------------------------------------------------------------
repo; branch p; branch q
echo api > "$LAB/r.p/api.txt"; git -C "$LAB/r.p" add api.txt; git -C "$LAB/r.p" commit -qm "p: add the api"
echo use > "$LAB/r.q/use.txt"; git -C "$LAB/r.q" add use.txt; git -C "$LAB/r.q" commit -qm "q: use the api"
(cd "$LAB/r.p" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.q" && SHIP_REVIEW=0 SHIP_TEST="test -f api.txt" "$BIN/ship.sh" > "$LAB/r9.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:use.txt" && ok "R9 a branch that needs a landed change: tested on the current target, landed" || bad "R9 a branch that needs a landed change: ship.sh exit $rc ($(grep -m1 'ship:' "$LAB/r9.log" | tail -1))"
# R9b: the same, and the branch also conflicts with the target (the stand's usual case): the rebase before the tests
# stops, so the tests before the queue are skipped; the merge rounds resolve it and the pre-merge hook tests the result
repo; branch p; branch q
echo api > "$LAB/r.p/api.txt"; sed -i.bak 's/^b$/b p/' "$LAB/r.p/f.txt"; rm "$LAB/r.p/f.txt.bak"; git -C "$LAB/r.p" add -A; git -C "$LAB/r.p" commit -qm "p: add the api, edit line b"
echo use > "$LAB/r.q/use.txt"; sed -i.bak 's/^b$/b q/' "$LAB/r.q/f.txt"; rm "$LAB/r.q/f.txt.bak"; git -C "$LAB/r.q" add -A; git -C "$LAB/r.q" commit -qm "q: use the api, edit line b"
(cd "$LAB/r.p" && "$BIN/merge.sh" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.q" && PATH="$LAB/bin:$PATH" SHIP_REVIEW=0 SHIP_AGENT=claude SHIP_TEST="test -f api.txt" "$BIN/ship.sh" > "$LAB/r9b.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:use.txt" && ok "R9 the same with a conflict: tests before the queue skipped, resolved in the rounds, landed" || bad "R9 the same with a conflict: ship.sh exit $rc ($(grep 'ship:' "$LAB/r9b.log" | tail -1))"

# --- R10 ---------------------------------------------------------------------------------------------
repo; branch s1; branch s2
sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: line b"
sed -i.bak 's/^b$/b s2/' "$LAB/r.s2/f.txt"; rm "$LAB/r.s2/f.txt.bak"; git -C "$LAB/r.s2" commit -qam "s2: line b"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1); (cd "$LAB/r.s2" && "$BIN/merge.sh" >/dev/null 2>&1)   # s2 stops on the conflict
# the agent resolved and committed, then was killed inside --continue before the branch ref moved
(cd "$LAB/r.s2" && git checkout -q --theirs f.txt && git add f.txt && GIT_EDITOR=true git commit -q --no-edit 2>/dev/null)
bl="$LAB/r/.git/refs/heads/s2.lock"; git -C "$LAB/r.s2" rev-parse HEAD > "$bl"; old "$bl"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r10.log" 2>&1) || rc=$?
[ $rc = 2 ] && [ ! -f "$bl" ] && grep -q "rebase is open" "$LAB/r10.log" && ok "R10 an open rebase with an old branch ref lock: exit 2 naming the rebase, lock removed" || bad "R10 an open rebase with an old branch ref lock: exit $rc, lock kept? $([ -f "$bl" ] && echo yes || echo no) ($(tail -1 "$LAB/r10.log"))"
(cd "$LAB/r.s2" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r10.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" merge-base --is-ancestor s2 "$T" && ok "R10 the session finishes the rebase: ship.sh lands it" || bad "R10 after the rebase is finished: ship.sh exit $rc ($(tail -1 "$LAB/r10.log"))"
# R10b: a kill while git wrote the rebase's todo leaves rebase-merge/git-rebase-todo.lock; --continue then fails
repo; branch s1; branch s2
sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: line b"
echo s2 > "$LAB/r.s2/h.txt"; git -C "$LAB/r.s2" add h.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.s2" && GIT_SEQUENCE_EDITOR="perl -i -pe 'print qq(break\n) if \$.==1'" git rebase -i "$T" >/dev/null 2>&1)
tl="$(git -C "$LAB/r.s2" rev-parse --git-dir)/rebase-merge/git-rebase-todo.lock"; : > "$tl"; old "$tl"
(cd "$LAB/r.s2" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1) && bad "R10b setup: --continue passed with the todo lock"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r10b.log" 2>&1) || rc=$?
(cd "$LAB/r.s2" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
rc2=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" >/dev/null 2>&1) || rc2=$?
[ $rc = 2 ] && [ ! -f "$tl" ] && [ $rc2 = 0 ] && ok "R10b an old git-rebase-todo.lock of an open rebase: removed, the rebase finishes, lands" || bad "R10b the todo lock: ship.sh exit $rc, lock kept? $([ -f "$tl" ] && echo yes || echo no), then exit $rc2"

# --- R11-R14: review 3, exit 0 with the work missing ---------------------------------------------------
stub() { mkdir -p "$LAB/stub"; printf '#!/bin/sh\ncat >/dev/null\n%s\n' "$1" > "$LAB/stub/claude"; chmod +x "$LAB/stub/claude"; }
# R11: the conflict agent skips the branch's only commit in the last round: ancestry alone says "landed"
repo; branch s1
echo s1 > "$LAB/r.s1/f.txt"; printf 'a\nb s1\nc\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: own behavior"
printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: other behavior"
stub 'git rebase --skip; echo resolved'
rc=0; (cd "$LAB/r.s1" && PATH="$LAB/stub:$PATH" SHIP_AGENT=claude SHIP_ROUNDS=1 SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r11.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R11 the last round ends with a skipped commit: exit 5" || bad "R11 exit $rc, expected 5 ($(tail -1 "$LAB/r11.log"))"
# R12: one of two commits lost, then a retry: the second record_tip must not forget the first tip
repo; branch s1
echo u > "$LAB/r.s1/unique"; git -C "$LAB/r.s1" add unique; git -C "$LAB/r.s1" commit -qm "s1: unique change"
echo k > "$LAB/r.s1/kept"; git -C "$LAB/r.s1" add kept; git -C "$LAB/r.s1" commit -qm "s1: kept change"
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other change"
(cd "$LAB/r.s1" && MERGE_PREPARE=false "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.s1" && GIT_SEQUENCE_EDITOR="sed -i.bak '1s/^pick /drop /'" git rebase -q -i "$T" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r12.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R12 a partial loss before a retry: exit 5" || bad "R12 exit $rc, expected 5 ($(tail -1 "$LAB/r12.log"))"
# R13: the target has a commit with the same author, second and subject, and another patch
repo; branch s1
export GIT_AUTHOR_DATE="2026-10-26T12:00:00+05:00" GIT_COMMITTER_DATE="2026-10-26T12:00:00+05:00"
echo u > "$LAB/r.s1/unique"; git -C "$LAB/r.s1" add unique; git -C "$LAB/r.s1" commit -qm "fix: update"
(cd "$LAB/r.s1" && MERGE_PREPARE=false "$BIN/merge.sh" >/dev/null 2>&1)
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "fix: update"
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
git -C "$LAB/r.s1" reset -q --hard "$T"
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r13.log" 2>&1) || rc=$?
[ $rc = 5 ] && ok "R13 same author, second and subject, another patch: exit 5" || bad "R13 exit $rc, expected 5 ($(tail -1 "$LAB/r13.log"))"
# R14: a merge commit that carries its own change is dropped by the rebase: refused before anything runs
repo; branch s1
git -C "$LAB/r" branch side "$T"; echo x > "$LAB/r/side.txt"; git -C "$LAB/r" worktree add -q "$LAB/r.side" side
echo x > "$LAB/r.side/side.txt"; git -C "$LAB/r.side" add side.txt; git -C "$LAB/r.side" commit -qm "side: file"
echo own > "$LAB/r.s1/own"; git -C "$LAB/r.s1" add own; git -C "$LAB/r.s1" commit -qm "s1: own"
git -C "$LAB/r.s1" merge -q --no-ff --no-commit side >/dev/null; echo fix > "$LAB/r.s1/only-in-merge"; git -C "$LAB/r.s1" add only-in-merge
git -C "$LAB/r.s1" commit -qm "s1: merge side with an extra file"
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other change"
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r14.log" 2>&1) || rc=$?
[ $rc = 2 ] && ! git -C "$LAB/r" cat-file -e "$T:only-in-merge" 2>/dev/null && ok "R14 an edited merge commit: ship.sh exit 2" || bad "R14 exit $rc, expected 2 ($(tail -1 "$LAB/r14.log"))"
# R14b: a clean merge of the target into the branch is not an edit: it lands
repo; branch s1
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other change"
echo own > "$LAB/r.s1/own"; git -C "$LAB/r.s1" add own; git -C "$LAB/r.s1" commit -qm "s1: own"
git -C "$LAB/r.s1" merge -q --no-edit "$T" >/dev/null
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r14b.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:own" && ok "R14b a clean merge of the target into the branch lands" || bad "R14b exit $rc ($(tail -1 "$LAB/r14b.log"))"
# R15: the fence sees a changed URL of an existing remote and core.hooksPath
repo; branch s1
echo s > "$LAB/r.s1/s"; git -C "$LAB/r.s1" add s; git -C "$LAB/r.s1" commit -qm "s1: file"
git -C "$LAB/r" remote add origin https://example.invalid/a.git
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other change"
stub 'git remote set-url origin https://example.invalid/b.git'
printf 'x\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: conflict" ; printf 'y\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: conflict"
rc=0; (cd "$LAB/r.s1" && PATH="$LAB/stub:$PATH" SHIP_AGENT=claude SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r15.log" 2>&1) || rc=$?
[ $rc = 4 ] && ok "R15 a remote URL changed by the agent: exit 4" || bad "R15 exit $rc, expected 4 ($(tail -1 "$LAB/r15.log"))"
stub 'git config core.hooksPath /tmp/evil-hooks'
repo; branch s1
printf 'x\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: conflict"; printf 'y\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: conflict"
rc=0; (cd "$LAB/r.s1" && PATH="$LAB/stub:$PATH" SHIP_AGENT=claude SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r15b.log" 2>&1) || rc=$?
[ $rc = 4 ] && ok "R15b core.hooksPath set by the agent: exit 4" || bad "R15b exit $rc, expected 4 ($(tail -1 "$LAB/r15b.log"))"
# R6d: the landed copy of a conflict-resolved commit touches fewer files than the original, because the rebase dropped
# a file the target already had (race lock seed 57593): same author, second and subject, the files of the match are a
# subset of the original's: landed, exit 0. The original conflicts with the target, so only the identity can match it.
repo; branch s2
echo same > "$LAB/r.s2/new.txt"; printf 'a\nb s2\nc\n' > "$LAB/r.s2/f.txt"; git -C "$LAB/r.s2" add new.txt f.txt
export GIT_AUTHOR_DATE="2026-10-26T12:00:00+05:00" GIT_COMMITTER_DATE="2026-10-26T12:00:00+05:00"
git -C "$LAB/r.s2" commit -qm "s2: new file and edit"
echo same > "$LAB/r/new.txt"; printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" add new.txt f.txt; git -C "$LAB/r" commit -qm "main: new file"
printf 'a\nb merged\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "s2: new file and edit"   # the resolved copy: f.txt only
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
git -C "$LAB/r.s2" rev-parse HEAD > "$(git -C "$LAB/r.s2" rev-parse --git-dir)/merge-orig"
git -C "$LAB/r.s2" reset -q --hard "$T"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r6d.log" 2>&1) || rc=$?
[ $rc = 0 ] && ok "R6d the match touches a subset of the original's files: landed" || bad "R6d exit $rc ($(tail -1 "$LAB/r6d.log"))"
# R17: R17 with a backslash in the subject (awk -v would read it as an escape and never match): the landed copy of a conflict-resolved commit touches fewer files than the original, because the rebase dropped
# a file the target already had (race lock seed 57593): same author, second and subject, the files of the match are a
# subset of the original's: landed, exit 0. The original conflicts with the target, so only the identity can match it.
repo; branch s2
echo same > "$LAB/r.s2/new.txt"; printf 'a\nb s2\nc\n' > "$LAB/r.s2/f.txt"; git -C "$LAB/r.s2" add new.txt f.txt
export GIT_AUTHOR_DATE="2026-10-26T12:00:00+05:00" GIT_COMMITTER_DATE="2026-10-26T12:00:00+05:00"
git -C "$LAB/r.s2" commit -qm "s2: handle \\n escape"
echo same > "$LAB/r/new.txt"; printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" add new.txt f.txt; git -C "$LAB/r" commit -qm "main: new file"
printf 'a\nb merged\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "s2: handle \\n escape"   # the resolved copy: f.txt only
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
git -C "$LAB/r.s2" rev-parse HEAD > "$(git -C "$LAB/r.s2" rev-parse --git-dir)/merge-orig"
git -C "$LAB/r.s2" reset -q --hard "$T"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r17.log" 2>&1) || rc=$?
[ $rc = 0 ] && ok "R17 the match touches a subset of the original's files: landed" || bad "R17 exit $rc ($(tail -1 "$LAB/r17.log"))"
# R18: the owner amended the branch after merge.sh recorded its tip: the record is stale. Exit 5 is the safe side (a
# loss cannot be told from a rewrite); the message names the file to remove, and after that the branch lands
repo; branch s2
echo a > "$LAB/r.s2/a.txt"; git -C "$LAB/r.s2" add a.txt; git -C "$LAB/r.s2" commit -qm "s2: first"
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other"
(cd "$LAB/r.s2" && MERGE_PREPARE=false "$BIN/merge.sh" >/dev/null 2>&1)
echo b > "$LAB/r.s2/b.txt"; git -C "$LAB/r.s2" add b.txt; git -C "$LAB/r.s2" commit -q --amend -m "s2: reworked"; git -C "$LAB/r.s2" mv a.txt a2.txt; git -C "$LAB/r.s2" commit -q --amend --no-edit
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r18.log" 2>&1) || rc=$?
rm_ok=0; grep -q "the record is stale: rm " "$LAB/r18.log" && rm_ok=1
rm -f "$(git -C "$LAB/r.s2" rev-parse --git-dir)/merge-orig"
rc2=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" >/dev/null 2>&1) || rc2=$?
[ $rc = 5 ] && [ $rm_ok = 1 ] && [ $rc2 = 0 ] && ok "R18 a stale record after an owner's amend: exit 5 naming rm, then it lands" || bad "R18 exit $rc (names rm: $rm_ok), after rm: exit $rc2"
# --- R19: MERGE_PUSH, the target published on a remote -----------------------------------------------
# New worktrees of bb, Claude Code and Codex start from origin/<target>: a target that only moves locally gives every
# new session stale code. With MERGE_PUSH=<remote> merge.sh brings the target up to the remote's under the lock,
# merges, and lands only what the remote took.
origin() { # a bare remote with the target, and a second clone that pushes as another machine would
  rm -rf "$LAB/origin.git" "$LAB/other"; git init -q --bare "$LAB/origin.git"
  git -C "$LAB/r" remote add origin "$LAB/origin.git"; git -C "$LAB/r" push -q origin "$T"
  git clone -q -b "$T" "$LAB/origin.git" "$LAB/other"
}
other_push() { git -C "$LAB/other" pull -q --ff-only origin "$T"; echo "$1" > "$LAB/other/$1"; git -C "$LAB/other" add "$1"; git -C "$LAB/other" commit -qm "other machine: $1"; git -C "$LAB/other" push -q origin "$T"; }
on_origin() { git --git-dir="$LAB/origin.git" cat-file -e "$T:$1" 2>/dev/null; }
in_step() { [ "$(git -C "$LAB/r" rev-parse "$T")" = "$(git --git-dir="$LAB/origin.git" rev-parse "$T")" ] && git -C "$LAB/r" diff --quiet "$T" && git -C "$LAB/r" diff --cached --quiet "$T"; }
repo; origin; branch s1
echo s1 > "$LAB/r.s1/q1.txt"; git -C "$LAB/r.s1" add q1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin q1.txt && in_step && ok "R19 MERGE_PUSH: the merge is on the remote's target too" || bad "R19 MERGE_PUSH: merge.sh exit $rc, on the remote? $(on_origin q1.txt && echo yes || echo no) ($(tail -1 "$LAB/r19.log"))"
# R19b: another machine pushed first: the local target is behind; the merge goes on top of the remote's
branch s2; other_push x.txt
echo s2 > "$LAB/r.s2/q2.txt"; git -C "$LAB/r.s2" add q2.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
rc=0; (cd "$LAB/r.s2" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19b.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin q2.txt && on_origin x.txt && in_step && ok "R19b the remote's target moved ahead: brought in under the lock, merged on top, pushed" || bad "R19b the remote ahead: merge.sh exit $rc ($(tail -1 "$LAB/r19b.log"))"
# R19c: another machine pushes while this merge runs its pre-merge hook: the push is rejected; the target goes back to
# what the remote has, and the merge is done again on top of it
mkdir -p "$LAB/r/.config"
printf '[pre-merge]\nrace = "sh -c '"'"'[ -f %s/raced ] && exit 0; touch %s/raced; cd %s && echo y > y.txt && git add y.txt && git commit -qm \\"other machine: y\\" && git push -q origin %s'"'"'"\n' "$LAB" "$LAB" "$LAB/other" "$T" > "$LAB/r/.config/wt.toml"
git -C "$LAB/r" add .config; git -C "$LAB/r" commit -qm "a hook that pushes from another machine once"; (cd "$LAB/r" && wt config approvals add --yes >/dev/null 2>&1)
git -C "$LAB/r" push -q origin "$T"; git -C "$LAB/other" pull -q --ff-only origin "$T"
branch s3; echo s3 > "$LAB/r.s3/q3.txt"; git -C "$LAB/r.s3" add q3.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
rc=0; (cd "$LAB/r.s3" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19c.log" 2>&1) || rc=$?
[ $rc = 0 ] && [ -f "$LAB/raced" ] && on_origin q3.txt && on_origin y.txt && in_step && ok "R19c a push from elsewhere during the merge: rejected, the target back to the remote's, merged again on top" || bad "R19c a push race: merge.sh exit $rc, raced? $([ -f "$LAB/raced" ] && echo yes || echo no), q3 on the remote? $(on_origin q3.txt && echo yes || echo no), in step? $(in_step && echo yes || echo no) ($(tail -1 "$LAB/r19c.log"))"
rm -f "$LAB/raced"
# R19d: the owner committed on the local target and did not push: merge.sh must not publish it
repo; origin; branch s1
echo own > "$LAB/r/owner.txt"; git -C "$LAB/r" add owner.txt; git -C "$LAB/r" commit -qm "owner: local only"
echo s1 > "$LAB/r.s1/q1.txt"; git -C "$LAB/r.s1" add q1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19d.log" 2>&1) || rc=$?
[ $rc = 2 ] && ! on_origin owner.txt && ! on_origin q1.txt && ok "R19d a local commit on the target that no merge made: exit 2, nothing pushed" || bad "R19d an owner's unpushed commit: merge.sh exit $rc, published? $(on_origin owner.txt && echo yes || echo no)"
# R19e: a merge whose push a kill cut off (recorded in the moves file, not on the remote): the next merge pushes it too
repo; origin; branch s1; branch s2
echo s1 > "$LAB/r.s1/q1.txt"; git -C "$LAB/r.s1" add q1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
echo s2 > "$LAB/r.s2/q2.txt"; git -C "$LAB/r.s2" add q2.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)   # no MERGE_PUSH: the state a kill after the fast-forward leaves
rc=0; (cd "$LAB/r.s2" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19e.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin q1.txt && on_origin q2.txt && in_step && ok "R19e a merge left unpushed by a kill: pushed with the next one" || bad "R19e an unpushed recorded merge: merge.sh exit $rc ($(tail -1 "$LAB/r19e.log"))"
# R19f: the remote refuses the push for another reason (a hook, no rights): the target goes back, exit 1, nothing lost
repo; origin; branch s1
printf '#!/bin/sh\necho "remote: no rights" >&2\nexit 1\n' > "$LAB/origin.git/hooks/pre-receive"; chmod +x "$LAB/origin.git/hooks/pre-receive"
echo s1 > "$LAB/r.s1/q1.txt"; git -C "$LAB/r.s1" add q1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
t_before=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19f.log" 2>&1) || rc=$?
[ $rc = 1 ] && [ "$(git -C "$LAB/r" rev-parse "$T")" = "$t_before" ] && git -C "$LAB/r" diff --quiet "$T" && ! git -C "$LAB/r" cat-file -e "$T:q1.txt" 2>/dev/null && git -C "$LAB/r.s1" cat-file -e HEAD:q1.txt &&
  ok "R19f a push the remote refuses: exit 1, the target and its checkout back, the branch keeps its commit" || bad "R19f a refused push: merge.sh exit $rc, target back? $([ "$(git -C "$LAB/r" rev-parse "$T")" = "$t_before" ] && echo yes || echo no) ($(tail -1 "$LAB/r19f.log"))"
rm -f "$LAB/origin.git/hooks/pre-receive"
# R19g: ship.sh with MERGE_PUSH: a session whose conflict agent runs while another session's merge pushes goes on (no exit 4)
branch s2; branch s3
sed -i.bak 's/^b$/b s2/' "$LAB/r.s2/f.txt"; rm "$LAB/r.s2/f.txt.bak"; git -C "$LAB/r.s2" commit -qam "s2: line b"
echo s3 > "$LAB/r.s3/o3.txt"; git -C "$LAB/r.s3" add o3.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: line b"; git -C "$LAB/r" push -q origin "$T"
stub "(cd $LAB/r.s3 && env -u SHIP_AGENT_RUN MERGE_PUSH=origin $BIN/merge.sh >/dev/null 2>&1); printf 'a\\nb main s2\\nc\\n' > f.txt; git add f.txt; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; echo resolved"
rc=0; (cd "$LAB/r.s2" && PATH="$LAB/stub:$PATH" MERGE_PUSH=origin SHIP_AGENT=claude SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r19g.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin o3.txt && git --git-dir="$LAB/origin.git" merge-base --is-ancestor "$(git -C "$LAB/r.s2" rev-parse HEAD)" "$T" && in_step && ok "R19g ship.sh with MERGE_PUSH: another session's pushed merge during the agent run, landed and pushed" || bad "R19g ship.sh with MERGE_PUSH: exit $rc ($(grep 'ship:\|merge:' "$LAB/r19g.log" | tail -1))"
# R8f: the conflict agent adds a commit of its own while it resolves (lab/swarm.sh N=20: "fix: remove leftover conflict
# marker"): still this merge's own move, recorded, so other sessions' fences let it through (7 exit 4 in that run)
repo; branch s1
printf 'a\nb s1\nc\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: line b"
printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: line b"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)   # stops on the conflict, tip recorded
printf 'a\nb main s1\nc\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" add f.txt; (cd "$LAB/r.s1" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
echo extra > "$LAB/r.s1/extra.txt"; git -C "$LAB/r.s1" add extra.txt; git -C "$LAB/r.s1" commit -qm "s1: the agent's own fix"
t0=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r8f.log" 2>&1) || rc=$?
[ $rc = 0 ] && grep -q "^$t0 $(git -C "$LAB/r" rev-parse "$T")\$" "$LAB/r/.git/wt-merge.moves" && ok "R8f a commit the conflict agent added: the merge is still recorded as this merge's move" || bad "R8f an agent-added commit: merge.sh exit $rc, recorded? $(grep -c "^$t0 " "$LAB/r/.git/wt-merge.moves" 2>/dev/null)"
# R19h: MERGE_PUSH and a merge that moved the target while a recorded commit is lost (exit 5): the target is pushed
# anyway; left unpushed, the next merge of every session stopped with 2 ("commits the remote lacks"), lab/swarm.sh N=20
repo; origin; branch s1
echo u > "$LAB/r.s1/unique"; git -C "$LAB/r.s1" add unique; git -C "$LAB/r.s1" commit -qm "s1: unique change"
echo k > "$LAB/r.s1/kept"; git -C "$LAB/r.s1" add kept; git -C "$LAB/r.s1" commit -qm "s1: kept change"
echo o > "$LAB/r/other"; git -C "$LAB/r" add other; git -C "$LAB/r" commit -qm "main: other change"; git -C "$LAB/r" push -q origin "$T"
(cd "$LAB/r.s1" && MERGE_PREPARE=false "$BIN/merge.sh" >/dev/null 2>&1)
(cd "$LAB/r.s1" && GIT_SEQUENCE_EDITOR="sed -i.bak '1s/^pick /drop /'" git rebase -q -i "$T" >/dev/null 2>&1)
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19h.log" 2>&1) || rc=$?
[ $rc = 5 ] && on_origin kept && in_step && ok "R19h a merge with a lost commit (exit 5) under MERGE_PUSH: the moved target is pushed, nothing left diverged" || bad "R19h exit $rc (want 5), kept on the remote? $(on_origin kept && echo yes || echo no), in step? $(in_step && echo yes || echo no)"
# R12b: a kill while record_tip wrote merge-orig leaves it empty (lab/race.sh PUSH=1 seed 261050): the record must be
# written again, the merge recorded as a move and, under MERGE_PUSH, pushed; an empty record left main ahead of origin
repo; origin; branch s1
echo s1 > "$LAB/r.s1/e.txt"; git -C "$LAB/r.s1" add e.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
echo o > "$LAB/r/o.txt"; git -C "$LAB/r" add o.txt; git -C "$LAB/r" commit -qm "main: other file"; git -C "$LAB/r" push -q origin "$T"
: > "$(git -C "$LAB/r.s1" rev-parse --absolute-git-dir)/merge-orig"
t0=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r12b.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin e.txt && in_step && grep -q "^$t0 " "$LAB/r/.git/wt-merge.moves" && ! grep -q "fatal" "$LAB/r12b.log" && ok "R12b an empty merge-orig left by a kill: rewritten, the merge recorded and pushed" || bad "R12b an empty merge-orig: merge.sh exit $rc, pushed? $(on_origin e.txt && echo yes || echo no) ($(grep -m1 fatal "$LAB/r12b.log"))"
# R19i: a merge.sh SIGKILLed right after wt merge moved the target, before its moves line and its push (lab/race.sh
# PUSH=1 seed 261035: every later merge stopped with 2, nothing landed). The next merge.sh finds the pending record of
# the killed one, records that move and pushes it, then merges its own branch
repo; origin; branch s1; branch s2
echo s1 > "$LAB/r.s1/k1.txt"; git -C "$LAB/r.s1" add k1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
echo s2 > "$LAB/r.s2/k2.txt"; git -C "$LAB/r.s2" add k2.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
mkdir -p "$LAB/kwt"; printf '#!/bin/sh\n"%s" "$@"; r=$?; [ "$1" = merge ] && kill -9 $PPID; exit $r\n' "$(command -v wt)" > "$LAB/kwt/wt"; chmod +x "$LAB/kwt/wt"
(cd "$LAB/r.s1" && PATH="$LAB/kwt:$PATH" MERGE_PUSH=origin "$BIN/merge.sh" >/dev/null 2>&1)
t_k=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s2" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19i.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin k1.txt && on_origin k2.txt && in_step && grep -q " $t_k\$" "$LAB/r/.git/wt-merge.moves" && ok "R19i a merge.sh killed between its merge and its push: the next one records and pushes that merge, then lands" || bad "R19i a killed merge's move: merge.sh exit $rc, k1 on the remote? $(on_origin k1.txt && echo yes || echo no) ($(grep '^merge:' "$LAB/r19i.log" | tail -1))"
# R19j: ship.sh run again after its merge moved the target and the push did not happen (a kill, the network): the branch
# is on the local target, so "already on the target" said 0 while the remote lacked it (review 3, B1)
repo; origin; branch s1
echo s1 > "$LAB/r.s1/j1.txt"; git -C "$LAB/r.s1" add j1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
(cd "$LAB/r.s1" && "$BIN/merge.sh" >/dev/null 2>&1)   # merged and recorded, not pushed: the state the kill leaves
rc=0; (cd "$LAB/r.s1" && MERGE_PUSH=origin SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r19j.log" 2>&1) || rc=$?
[ $rc = 0 ] && on_origin j1.txt && in_step && ok "R19j ship.sh on a branch merged but not pushed: pushes it before it says shipped" || bad "R19j exit $rc, on the remote? $(on_origin j1.txt && echo yes || echo no) ($(tail -1 "$LAB/r19j.log"))"
# R19k: a merge.sh killed after it wrote wt-merge.pending and before wt merge moved anything, then the owner's own merge
# commit on the target: not a killed merge's move, so never recorded or published (review 3, B2)
repo; origin; branch s1; branch s2
echo s1 > "$LAB/r.s1/m1.txt"; git -C "$LAB/r.s1" add m1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
echo s2 > "$LAB/r.s2/m2.txt"; git -C "$LAB/r.s2" add m2.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
mkdir -p "$LAB/kwt0"; printf '#!/bin/sh\n[ "$1" = merge ] && kill -9 $PPID\nexec "%s" "$@"\n' "$(command -v wt)" > "$LAB/kwt0/wt"; chmod +x "$LAB/kwt0/wt"
(cd "$LAB/r.s1" && PATH="$LAB/kwt0:$PATH" MERGE_PUSH=origin "$BIN/merge.sh" >/dev/null 2>&1)
git -C "$LAB/r" branch feat; git -C "$LAB/r" checkout -q feat; echo own > "$LAB/r/own.txt"; git -C "$LAB/r" add own.txt; git -C "$LAB/r" commit -qm "owner: local feature"
git -C "$LAB/r" checkout -q "$T"; git -C "$LAB/r" merge -q --no-ff -m "owner: merge feat" feat
rc=0; (cd "$LAB/r.s2" && MERGE_PUSH=origin "$BIN/merge.sh" > "$LAB/r19k.log" 2>&1) || rc=$?
[ $rc = 2 ] && ! on_origin own.txt && ok "R19k an owner's merge commit on top of a stale pending record: exit 2, not published" || bad "R19k exit $rc (want 2), published? $(on_origin own.txt && echo yes || echo no)"
# R20: a red commit fixed by a later one on the same branch (lab/swarm.sh with real agents: 2 of 11 commits of main red,
# one of them a review fix): the gate tests the tip, so the red commit must not become a first-parent commit of the target
repo; mkdir -p "$LAB/r/.config"; printf '[pre-merge]\ngreen = "grep -qx ok state"\n' > "$LAB/r/.config/wt.toml"; echo ok > "$LAB/r/state"
git -C "$LAB/r" add .config state; git -C "$LAB/r" commit -qm "a suite: state must be ok"; (cd "$LAB/r" && wt config approvals add --yes >/dev/null 2>&1)
branch s1; echo broken > "$LAB/r.s1/state"; git -C "$LAB/r.s1" commit -qam "s1: step one, red"
echo ok > "$LAB/r.s1/state"; echo s1 > "$LAB/r.s1/s1.txt"; git -C "$LAB/r.s1" add -A; git -C "$LAB/r.s1" commit -qm "s1: step two, green again"
t0=$(git -C "$LAB/r" rev-parse "$T")
rc=0; (cd "$LAB/r.s1" && "$BIN/merge.sh" > "$LAB/r20.log" 2>&1) || rc=$?
red=0; for c in $(git -C "$LAB/r" rev-list --first-parent "$t0..$T"); do [ "$(git -C "$LAB/r" show "$c:state")" = ok ] || red=$((red+1)); done
[ $rc = 0 ] && [ $red = 0 ] && [ "$(git -C "$LAB/r" rev-parse "$T^2")" = "$(git -C "$LAB/r.s1" rev-parse HEAD)" ] && grep -q "^$t0 $(git -C "$LAB/r" rev-parse "$T")\$" "$LAB/r/.git/wt-merge.moves" &&
  ok "R20 a red commit inside a branch: under a merge commit, every first-parent commit green, the move recorded" || bad "R20 red first-parent commits: $red, merge.sh exit $rc ($(tail -1 "$LAB/r20.log"))"
# R21: a SIGKILL inside ship.sh's rebase before the tests (lab/kill-stress.sh, about 3 in 550 reps) can leave git state
# that every later round trips on, though the branch never moved and the tree is clean: CHERRY_PICK_HEAD (and its .lock)
# with no rebase open ("a git operation is already in progress"), or a rebase-merge/ cut short, without head-name
# (the kill came while git created or removed it). With HEAD on the branch and a clean tree there is nothing to keep.
repo; branch s1; echo s1 > "$LAB/r.s1/u.txt"; git -C "$LAB/r.s1" add u.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
echo t > "$LAB/r/t.txt"; git -C "$LAB/r" add t.txt; git -C "$LAB/r" commit -qm "main: another file"
gd=$(git -C "$LAB/r.s1" rev-parse --absolute-git-dir)
git -C "$LAB/r.s1" rev-parse HEAD > "$gd/CHERRY_PICK_HEAD"; : > "$gd/CHERRY_PICK_HEAD.lock"; old "$gd/CHERRY_PICK_HEAD.lock"
rc=0; (cd "$LAB/r.s1" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r21.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:u.txt" && [ ! -f "$gd/CHERRY_PICK_HEAD" ] && ok "R21 a cherry-pick state left by a kill, branch unmoved, tree clean: cleared, landed" || bad "R21 the cherry-pick state: ship.sh exit $rc ($(grep 'ship:\|✗' "$LAB/r21.log" | tail -1))"
# R21b: rebase-merge/ with only author-script and msgnum, HEAD on the branch, the tree clean
branch s2; echo s2 > "$LAB/r.s2/v.txt"; git -C "$LAB/r.s2" add v.txt; git -C "$LAB/r.s2" commit -qm "s2: new file"
gd=$(git -C "$LAB/r.s2" rev-parse --absolute-git-dir); mkdir -p "$gd/rebase-merge"; : > "$gd/rebase-merge/author-script"; echo 1 > "$gd/rebase-merge/msgnum"
rc=0; (cd "$LAB/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r21b.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" cat-file -e "$T:v.txt" && [ ! -d "$gd/rebase-merge" ] && ok "R21b a rebase-merge/ without head-name, branch checked out, tree clean: removed, landed" || bad "R21b a cut-short rebase-merge/: ship.sh exit $rc ($(grep 'ship:' "$LAB/r21b.log" | tail -1))"
# R21c: the same leftovers with the session's uncommitted edit: not touched, exit 2
branch s3; echo s3 > "$LAB/r.s3/w.txt"; git -C "$LAB/r.s3" add w.txt; git -C "$LAB/r.s3" commit -qm "s3: new file"
gd=$(git -C "$LAB/r.s3" rev-parse --absolute-git-dir); git -C "$LAB/r.s3" rev-parse HEAD > "$gd/CHERRY_PICK_HEAD"; echo edit >> "$LAB/r.s3/f.txt"
rc=0; (cd "$LAB/r.s3" && SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r21c.log" 2>&1) || rc=$?
[ $rc = 2 ] && [ -f "$gd/CHERRY_PICK_HEAD" ] && grep -q edit "$LAB/r.s3/f.txt" && ok "R21c the cherry-pick state with an uncommitted edit: left alone, exit 2" || bad "R21c exit $rc, state kept? $([ -f "$gd/CHERRY_PICK_HEAD" ] && echo yes || echo no), edit kept? $(grep -c edit "$LAB/r.s3/f.txt")"
# R22: SHIP_AGENT=codex resolving a conflict. In Codex's workspace-write sandbox a worktree's git dir is read-only (the
# .git pointer's target is protected, even when added as a writable root): git add and rebase --continue fail, and
# no conflict can be resolved (lab/swarm.sh SWARM_AGENT=codex: 0 of 10 sessions could commit). The stub runs the
# resolution under Codex's real sandbox when ship.sh asks for one (macOS with codex), elsewhere it acts as that
# sandbox does: the git writes fail and nothing is resolved.
real_codex=""; command -v codex >/dev/null 2>&1 && [ "$(uname)" = Darwin ] && real_codex=$(command -v codex)
repo; branch s1
printf 'a\nb s1\nc\n' > "$LAB/r.s1/f.txt"; git -C "$LAB/r.s1" commit -qam "s1: line b"
printf 'a\nb main\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" commit -qam "main: line b"
mkdir -p "$LAB/cstub"; cat > "$LAB/cstub/codex" <<STUB
#!/bin/sh
cat >/dev/null
fix='printf "a\\\\nb main s1\\\\nc\\\\n" > f.txt && git add f.txt && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; echo resolved'
case " \$* " in *" workspace-write "*) [ -n "$real_codex" ] || { echo "sandbox: git dir read-only"; exit 0; }; exec "$real_codex" sandbox -P :workspace -C "\$PWD" -- sh -c "\$fix" ;; esac
exec sh -c "\$fix"
STUB
chmod +x "$LAB/cstub/codex"
rc=0; (cd "$LAB/r.s1" && PATH="$LAB/cstub:$PATH" SHIP_AGENT=codex SHIP_REVIEW=0 SHIP_TEST=true "$BIN/ship.sh" > "$LAB/r22.log" 2>&1) || rc=$?
[ $rc = 0 ] && git -C "$LAB/r" show "$T:f.txt" | grep -qx "b main s1" && ok "R22 SHIP_AGENT=codex resolves a conflict: its git writes are not sandboxed away, landed" || bad "R22 SHIP_AGENT=codex conflict: ship.sh exit $rc ($(grep 'ship:\|fatal' "$LAB/r22.log" | tail -1))"
# R16: lab/race.sh draws a session's plan from RANDOM in the parent shell: one SEED, one plan (bash 3.2 did not advance
# RANDOM inside $(...), so the same seed gave other plans and the before/after pairs compared other tasks)
# a vendored copy has no lab/race.sh: nothing to check there
if [ -f "$HERE/lab/race.sh" ]; then
sed -n '/^rnd()/p;/^plan_session()/,/^}/p' "$HERE/lab/race.sh" > "$LAB/plan.sh"
plan() { bash -c 'FILES=4; EDITS=2; LINES=6; WINDOW=3; SUITE=0.5; P_FLAKY=10; P_SEM=15; P_KILL=15; P_DUP=20; P_DEP=20; . "$1"; RANDOM=$2; for i in 1 2 3 4 5 6 7 8 9 10; do plan_session $i; done; declare -p S_START S_EDITS S_FLAKY S_SEM S_KILL S_LABEL S_NEED' _ "$LAB/plan.sh" "$1"; }
p1=$(plan 261026); p2=$(plan 261026); p3=$(plan 261027)
[ -n "$p1" ] && [ "$p1" = "$p2" ] && [ "$p1" != "$p3" ] && ok "R16 race.sh: one seed, one plan; another seed, another plan" || bad "R16 race.sh plan is not fixed by the seed"
fi

}

for t in main master develop; do run "$t"; done
exit $status
