#!/usr/bin/env bash
# The stand campaigns of 2026-10-22, as run. Each writes measurements/2026-10-22/race/<name>.jsonl (gzipped afterwards).
# H: dependent work at N = 10 (P_DEP=20 P_DUP=20), 100 runs per mode, default faults; H.retry: DEP_POLICY=retry.
# Q: the queue alone (no conflicts, no faults) at three loads, to check the lock against Pollaczek-Khinchine.
# X: conflicts on, faults off, N swept: exit-4 share and waits against lab/queue.py's open-window model.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; O=$(pwd)/measurements/2026-10-22/race  # absolute: race.sh cds into its lab
case ${1:-} in
  H)       for m in ship lock; do RUNS=100 SEED=4000 N=10 P_DEP=20 P_DUP=20 MODE=$m OUT=$O/H.$m.jsonl lab/race.sh > $O/H.$m.log 2>&1 & done; wait ;;
  H.retry) RUNS=30 SEED=4000 N=10 P_DEP=20 P_DUP=20 DEP_POLICY=retry DEP_WAIT=20 MODE=ship OUT=$O/H.retry.ship.jsonl lab/race.sh > $O/H.retry.ship.log 2>&1 ;;
  Q)       for w in 300 150 106; do RUNS=8 SEED=5000 N=30 SUITE=2 WINDOW=$w DEADLINE=$((w + 300)) FILES=300 EDITS=1 P_FLAKY=0 P_SEM=0 P_KILL=0 MODE=ship OUT=$O/Q.w$w.jsonl lab/race.sh > $O/Q.w$w.log 2>&1; done ;;
  X)       for n in 4 8 12 16 20; do RUNS=20 SEED=6000 N=$n WINDOW=30 FILES=8 P_FLAKY=0 P_SEM=0 P_KILL=0 MODE=ship OUT=$O/X.n$n.jsonl lab/race.sh > $O/X.n$n.log 2>&1; done ;;
  *) echo "usage: $0 H|H.retry|Q|X" >&2; exit 2 ;;
esac
