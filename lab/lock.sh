#!/usr/bin/env bash
# Targeted checks of the merge lock in bin/merge.sh: the places where a lock written by hand usually
# breaks. `wt` is replaced by a stub that only marks a critical section, so a rep takes milliseconds
# and any overlap is the lock's fault, not git's. The checks do not depend on how the lock is built.
#
#   lab/lock.sh               every check, REPS=50 reps each
#   REPS=200 lab/lock.sh T1   one check
#   MERGE_SH=<path>           the merge.sh under test (default: bin/merge.sh of this checkout); the lab runs a copy,
#                             so its cleanup never touches merges of other labs or real sessions
#
#   T1  the holder is SIGKILLed while W waiters poll: no two waiters may be inside at once
#   T2  a merge is SIGKILLed at a random moment of its start (0–40 ms): the next merge must not hang
#   T3  the dead holder's pid is reused by a live, unrelated process: the next merge must not hang
#   T4  the holder gets SIGTERM / SIGINT / SIGHUP: the next merge must get the lock
#   T5  takeover latency after a SIGKILL of the holder (printed, no pass/fail)
#   T6  the merge leaves a long-lived child behind (a test daemon): the next merge must still get the lock
#   (T3 needs a pid in the lock; with flock there is none, so it passes trivially and guards only a pid lock)
#
# Output: one line per check, `PASS|FAIL <check> <failed>/<reps> …`; exit 1 when any check fails.
set -uo pipefail; set +m
unset MERGE_PREPARE MERGE_TARGET MERGE_EVENTS  # the stand builds its own repos; the caller's merge config (pnpm ship exports MERGE_PREPARE) must not reach them
REPS=${REPS:-50}; W=${W:-5}; ONLY=${1:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(mktemp -d /tmp/wt-lock.XXXXXX); trap 'pkill -9 -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
status=0

git init -q -b main "$LAB/repo"; R="$LAB/repo"; git -C "$R" commit -q --allow-empty -m init
# the copy brings lib.sh along: a merge.sh that cannot source it fails at once, and every check below would pass
# with no merge ever run; cnt() below makes each check prove the stub was entered
src=${MERGE_SH:-$HERE/bin/merge.sh}; M="$LAB/merge.sh"; cp "$src" "$M"; [ ! -f "$(dirname "$src")/lib.sh" ] || cp "$(dirname "$src")/lib.sh" "$LAB/"
mkdir "$LAB/bin"
# The stub wt: `wt merge` is the critical section; entering while another section is open is an overlap. Any other
# wt call (lib.sh asks for the default branch) must not count as an entry, or a merge.sh that dies before the lock
# would still look like it ran.
cat > "$LAB/bin/wt" <<EOF
#!/usr/bin/env bash
[ "\$1" = merge ] || { echo main; exit 0; }
# a section left by a SIGKILLed holder is not an overlap: only a live pid counts
for d in "$LAB"/cs.*; do [ -d "\$d" ] && kill -0 "\${d##*.}" 2>/dev/null && echo "\$\$ inside with \${d##*.}" >> "$LAB/overlaps"; done
mkdir "$LAB/cs.\$\$"
echo "\$\$ \$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" >> "$LAB/entered"
sleep "\${CS_SLEEP:-0.3}"
rmdir "$LAB/cs.\$\$"
# a daemon left by a test: inherits every open fd of wt, and outlives the merge
[ -z "\${STUB_DAEMON:-}" ] || { perl -e "setpgrp(0,0); exec qw(sleep 60)" & echo \$! >> "$LAB/daemons"; }
EOF
chmod +x "$LAB/bin/wt"
export PATH="$LAB/bin:$PATH" MERGE_TARGET=main

start() { # <name>: merge.sh in its own process group; pid in BG
  (cd "$R" && exec perl -e 'setpgrp(0,0); exec @ARGV' "$M") >>"$LAB/$1.log" 2>&1 </dev/null &
  BG=$!
}
wait_for() { # <cmd> <seconds>: poll a condition
  local end; end=$(perl -e "print time+$2")
  until eval "$1"; do [ "$(perl -e 'print time')" -lt "$end" ] || return 1; sleep 0.05; done
}
in_cs() { ls -d "$LAB"/cs.* >/dev/null 2>&1; }
cnt() { wc -l < "$LAB/entered" 2>/dev/null | tr -d ' ' || echo 0; }   # critical sections entered so far
reset() { pkill -9 -f "$M" 2>/dev/null; pkill -9 -f "$LAB/bin/wt" 2>/dev/null; sleep 0.1
  rm -rf "$R/.git/wt-merge.lock" "$LAB"/cs.* "$LAB/overlaps" "$LAB/entered"; }
waitall() { # <seconds> <pids…>: wait for pids, kill what is left; returns 1 on a timeout
  local t=$1 p left=0; shift
  wait_for "! kill -0 $* 2>/dev/null" "$t" || left=1
  for p in "$@"; do kill -9 -- "-$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  return $left
}
report() { # <check> <failed> <detail>
  if [ "$2" = 0 ]; then echo "PASS $1 0/$REPS $3"; else echo "FAIL $1 $2/$REPS $3"; status=1; fi
}
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

if want T1; then
  bad=0; lost=0
  for _ in $(seq "$REPS"); do
    reset
    CS_SLEEP=30 start holder; h=$BG; wait_for in_cs 5 || { lost=$((lost+1)); continue; }
    pids=(); for i in $(seq "$W"); do start "w$i"; pids+=("$BG"); done
    sleep 0.5; kill -9 -- "-$h"; wait "$h" 2>/dev/null
    waitall $((10 + W * 3)) "${pids[@]}" || lost=$((lost+1))
    [ "$(cnt)" -ge $((W + 1)) ] || lost=$((lost+1))   # the holder and every waiter entered
    [ ! -s "$LAB/overlaps" ] || bad=$((bad+1))
  done
  report T1 $((bad + lost)) "(reps with two waiters inside at once: $bad; reps timed out or with a waiter that never entered: $lost; W=$W)"
fi

if want T2; then
  bad=0
  for _ in $(seq "$REPS"); do
    reset
    CS_SLEEP=0 start victim; v=$BG
    perl -MTime::HiRes=sleep -e 'sleep(rand(0.04))'; kill -9 -- "-$v" 2>/dev/null; wait "$v" 2>/dev/null
    n0=$(cnt); CS_SLEEP=0 start next; n=$BG
    { waitall 10 "$n" && [ "$(cnt)" -gt "${n0:-0}" ]; } || bad=$((bad+1))
  done
  report T2 "$bad" "(reps where the next merge hung >10 s after a kill during start)"
fi

if want T3; then
  bad=0
  for _ in $(seq "$REPS"); do
    reset
    CS_SLEEP=30 start holder; h=$BG; wait_for in_cs 5
    kill -9 -- "-$h"; wait "$h" 2>/dev/null
    sleep 300 & live=$!
    [ ! -f "$R/.git/wt-merge.lock/pid" ] || echo "$live" > "$R/.git/wt-merge.lock/pid"
    n0=$(cnt); CS_SLEEP=0 start next; n=$BG
    { waitall 10 "$n" && [ "$(cnt)" -gt "${n0:-0}" ]; } || bad=$((bad+1))
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  done
  report T3 "$bad" "(reps where a live unrelated pid in the lock blocked the next merge >10 s)"
fi

if want T4; then
  for sig in TERM INT HUP; do
    bad=0
    for _ in $(seq "$REPS"); do
      reset
      CS_SLEEP=2 start holder; h=$BG; wait_for in_cs 5
      kill -s "$sig" "$h"   # merge.sh only, as a host does when it stops the command
      n0=$(cnt); CS_SLEEP=0 start next; n=$BG
      { waitall 10 "$n" && [ "$(cnt)" -gt "${n0:-0}" ]; } || bad=$((bad+1)); waitall 5 "$h"
    done
    report "T4-$sig" "$bad" "(reps where the next merge waited >10 s after SIG$sig to the holder)"
  done
fi

if want T6; then
  bad=0
  for _ in $(seq "$REPS"); do
    reset
    export STUB_DAEMON=1; CS_SLEEP=0 start holder; h=$BG; waitall 10 "$h"; unset STUB_DAEMON
    [ "$(cnt)" -ge 1 ] || { bad=$((bad+1)); continue; }   # the holder must have merged
    n0=$(cnt); CS_SLEEP=0 start next; n=$BG
    { waitall 5 "$n" && [ "$(cnt)" -gt "${n0:-0}" ]; } || bad=$((bad+1))
    kill $(cat "$LAB/daemons" 2>/dev/null) 2>/dev/null; rm -f "$LAB/daemons"
  done
  report T6 "$bad" "(reps where a daemon left by the previous merge kept the lock >5 s)"
fi

if want T5; then
  lat=()
  for _ in $(seq "$REPS"); do
    reset
    CS_SLEEP=30 start holder; h=$BG; wait_for in_cs 5
    CS_SLEEP=0 start next; n=$BG; sleep 0.3
    t0=$(now); kill -9 -- "-$h"; wait "$h" 2>/dev/null
    waitall 10 "$n"
    t1=$(awk -v p="$t0" '$2>p{print $2; exit}' "$LAB/entered" 2>/dev/null)
    [ -n "$t1" ] && lat+=("$(perl -e "printf '%.2f', $t1-$t0")")
  done
  printf '%s\n' "${lat[@]}" | sort -n | awk '{a[NR]=$1} END{printf "INFO T5 takeover after SIGKILL: n=%d p50=%ss p95=%ss max=%ss\n", NR, a[int(NR*0.5+0.5)], a[int(NR*0.95+0.5)], a[NR]}'
fi
exit $status
