#!/usr/bin/env bash
# Resume the final before/after campaigns, paused on 2026-10-23: each one continues from its first seed not run,
# appending to its JSON lines. The frozen copies of bin/ are rebuilt from git and checked against bin-final.sha.
#   measurements/2026-10-23/final/resume.sh        then wait for "PASS|FAIL" at the end of every *.log
set -euo pipefail
O=$(cd "$(dirname "$0")" && pwd); cd "$O/../../.."
for p in final:df4badf before:08e7423; do d=/tmp/bin-${p%%:*}; mkdir -p "$d"
  for f in merge ship lib; do git show "${p#*:}:bin/$f.sh" > "$d/$f.sh"; done; chmod +x "$d"/*.sh; done
(cd /tmp/bin-final && shasum *.sh) | diff - <(head -3 "$O/bin-final.sha") || { echo "resume: /tmp/bin-final differs from bin-final.sha" >&2; exit 1; }
next() { python3 -c "import json,sys; s=[int(json.loads(l)['run'].split('-')[1]) for l in open(sys.argv[1]) if '\"run-end\"' in l]; print(max(s)+1 if s else int(sys.argv[2]))" "$O/$1.jsonl" "$2"; }
run() { # <campaign> <first seed> <runs> <bin> <env…>
  local c=$1 s0=$2 n=$3 b=$4; shift 4; local s; s=$(next "$c" "$s0"); local left=$((s0 + n - s))
  [ "$left" -gt 0 ] || { echo "$c: done"; return; }
  echo "$c: SEED=$s RUNS=$left"
  nohup env "$@" RUNS=$left SEED=$s P_DEP=20 P_DUP=20 DEP_POLICY=retry BIN="$b" OUT="$O/$c.jsonl" lab/race.sh >> "$O/$c.log" 2>&1 &
}
run C10.ship.after 7000 100 /tmp/bin-final N=10 MODE=ship
run C10.lock.after 7000 100 /tmp/bin-final N=10 MODE=lock
run C20.ship.after 7100 100 /tmp/bin-final N=20 FILES=8 WINDOW=30 MODE=ship
run C30.ship.after 7200 100 /tmp/bin-final N=30 FILES=12 WINDOW=45 DEADLINE=400 MODE=ship
run C30.ship.before.part2 7250 50 /tmp/bin-before N=30 FILES=12 WINDOW=45 DEADLINE=400 MODE=ship
