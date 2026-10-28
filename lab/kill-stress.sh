#!/usr/bin/env bash
# One SIGKILL inside ship.sh at a random moment, then the recovery its messages ask for, repeated: the regression
# stand of the kill paths around ship.sh's rebase before the tests (R1b-R1d, R5b, R10-R10c). Each rep: a target moved
# by another branch, ship.sh killed after rand(KILL_MAX) seconds, then up to 12 rounds of: resolve an open rebase
# (lab/resolve.sh), git rebase --abort when ship.sh says a rebase is open and it is still open, ship.sh, and on exit 5
# the git reset --hard it names. Outcome per rep: ok (landed), LOST (the branch on the target without its file),
# STUCK (not landed after 12 rounds), or NOKILL (ship.sh had ended before the kill: not a test of anything, not
# counted as ok); a LOST or STUCK lab is kept.
#   REPS=300 BIN=<bin dir> lab/kill-stress.sh      prints one line per rep, then the counts
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd); B=${BIN:-$H/bin}; REPS=${REPS:-100}; KILL_MAX=${KILL_MAX:-0.4}
export MERGE_TARGET=main MERGE_STALE_INDEX_LOCK=1; unset MERGE_PREPARE MERGE_EVENTS
rep() {
  local L d pid gd seq="" rc=0 t k=no
  L=$(mktemp -d /tmp/kill-stress.XXXXXX); git init -q -b main "$L/r"; cd "$L/r" || return
  git config commit.gpgsign false; printf 'a\nb\nc\n' > f.txt; git add f.txt; git commit -qm init
  git worktree add -q -b s1 "$L/r.s1" main; git worktree add -q -b s2 "$L/r.s2" main
  echo s1 >> "$L/r.s1/f.txt"; git -C "$L/r.s1" commit -qam s1
  echo s2 > "$L/r.s2/g.txt"; git -C "$L/r.s2" add g.txt; git -C "$L/r.s2" commit -qm "s2: file"
  (cd "$L/r.s1" && "$B/merge.sh" >/dev/null 2>&1)
  d=$(perl -e "printf '%.3f', rand($KILL_MAX)")
  (cd "$L/r.s2" && exec perl -e 'setpgrp(0,0); exec @ARGV' env SHIP_REVIEW=0 SHIP_TEST="sleep 0.2" "$B/ship.sh") > "$L/a.log" 2>&1 & pid=$!
  sleep "$d"; kill -9 -- "-$pid" 2>/dev/null && k=yes; wait "$pid" 2>/dev/null   # k: the signal reached a live group
  gd=$(git -C "$L/r.s2" rev-parse --git-dir)
  for t in $(seq 1 12); do
    if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then (cd "$L/r.s2" && "$H/lab/resolve.sh" 0 >/dev/null 2>&1); fi
    [ "$t" -gt 1 ] && grep -q "rebase is open" "$L/last.log" 2>/dev/null && git -C "$L/r.s2" rebase --abort 2>/dev/null
    rc=0; (cd "$L/r.s2" && SHIP_REVIEW=0 SHIP_TEST=true "$B/ship.sh" > "$L/last.log" 2>&1) || rc=$?; cat "$L/last.log" >> "$L/a.log"; seq="$seq $rc"
    [ $rc = 5 ] && git -C "$L/r.s2" reset -q --hard "$(cat "$gd/merge-orig")" 2>> "$L/a.log"
    [ $rc = 0 ] && break
  done
  if git -C "$L/r" merge-base --is-ancestor s2 main && ! git -C "$L/r" cat-file -e main:g.txt 2>/dev/null; then echo "LOST d=$d rcs:$seq lab $L"
  elif [ $k = no ]; then echo "NOKILL d=$d rcs:$seq"; rm -rf "$L"
  elif [ $rc != 0 ]; then echo "STUCK d=$d rcs:$seq lab $L"
  else echo "ok d=$d rcs:$seq"; rm -rf "$L"; fi
}
out=$(for i in $(seq 1 "$REPS"); do (rep); done); printf '%s\n' "$out"
echo "== $(printf '%s\n' "$out" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')"
printf '%s\n' "$out" | grep -qE '^(LOST|STUCK)' && exit 1 || exit 0
