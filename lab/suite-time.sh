#!/usr/bin/env bash
# Time an adopter's real suite alone and with k copies at once: the T of the queue model, and what parallel
# sessions do to it (ship.sh runs the suite before the queue in every session, outside the lock).
# Read-only for the source repository: k shared clones under /tmp, each prepared once.
#
#   lab/suite-time.sh <repo> "<prepare>" "<suite>" <k>…     e.g. lab/suite-time.sh ../hotpot2 "pnpm install --frozen-lockfile --prefer-offline" "pnpm test" 1 2 4 8
#   REPS=3                                                  rounds per k (default 3)
# Prints one JSON line per suite run: k, rep, clone, seconds, exit code; and load average at the start.
set -uo pipefail
SRC=$(cd "$1" && pwd); PREP=$2; SUITE=$3; shift 3; REPS=${REPS:-3}
max=0; for k in "$@"; do [ "$k" -gt "$max" ] && max=$k; done
L=${LAB:-/tmp/suite-time}; mkdir -p "$L"
for c in $(seq 1 "$max"); do
  [ -d "$L/c$c" ] || { git clone -q --shared "$SRC" "$L/c$c" && (cd "$L/c$c" && sh -c "$PREP") > "$L/prep.$c.log" 2>&1 || { echo "prepare failed in c$c (see $L/prep.$c.log)" >&2; exit 1; }; }
done
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
for k in "$@"; do for r in $(seq 1 "$REPS"); do
  la=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
  for c in $(seq 1 "$k"); do
    ( t0=$(now); (cd "$L/c$c" && sh -c "$SUITE") > "$L/run.$k.$r.$c.log" 2>&1; rc=$?
      printf '{"k":%s,"rep":%s,"clone":%s,"secs":%s,"rc":%s,"load1":%s}\n' "$k" "$r" "$c" "$(perl -e "printf '%.2f', $(now)-$t0")" "$rc" "${la:-0}" ) &
  done; wait
done; done
