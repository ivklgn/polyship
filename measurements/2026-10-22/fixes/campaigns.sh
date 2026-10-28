#!/usr/bin/env bash
# Before/after on the same seeds. before = bin/ at 08e7423 (copied to /tmp/bin-before), after = bin/ of this checkout.
#   C10: N = 10, 100 runs, ship and lock, P_DEP=20 P_DUP=20 DEP_POLICY=retry, default faults (15 % killed)
#   C20: N = 20, 100 runs, ship, FILES=8 WINDOW=30, the same dependent work and faults
#   C30: N = 30, 50 runs, ship, FILES=12 WINDOW=45, the same
cd "$(dirname "$0")/../../.." || exit 1; O=$(pwd)/measurements/2026-10-22/fixes
run() { # <name> <bin> <env…>
  local n=$1 b=$2; shift 2
  env "$@" BIN="$b" OUT="$O/$n.jsonl" lab/race.sh > "$O/$n.log" 2>&1
}
A=$(pwd)/bin; B=/tmp/bin-before
common="P_DEP=20 P_DUP=20 DEP_POLICY=retry"
# in batches: 8 stands at once saturated the machine (58 % sys, a run in minutes), which distorts timings and deadlines
for v in before after; do b=$A; [ $v = before ] && b=$B
  run C10.ship.$v $b RUNS=100 SEED=7000 N=10 $common MODE=ship &
  run C10.lock.$v $b RUNS=100 SEED=7000 N=10 $common MODE=lock &
done; wait
for v in before after; do b=$A; [ $v = before ] && b=$B
  run C20.ship.$v $b RUNS=100 SEED=7100 N=20 FILES=8 WINDOW=30 $common MODE=ship &
done; wait
for v in before after; do b=$A; [ $v = before ] && b=$B
  run C30.ship.$v $b RUNS=50 SEED=7200 N=30 FILES=12 WINDOW=45 DEADLINE=400 $common MODE=ship &   # 50, not 100: time
done
wait; echo all done > "$O/DONE"
