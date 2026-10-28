#!/usr/bin/env bash
# Model of the alternative to the serial queue: a Bors-style optimistic batch. Not used in the
# project today; this stand measures what it would buy when the pre-merge suite is long.
#
# N branches in disjoint files, one of them breaks the suite without a textual conflict. Serial
# merging (bin/merge.sh) costs N suite runs. The batch merges all N into a temporary branch,
# runs the suite once; on red it bisects the batch (Bors / Zuul / GitHub merge queue shape), lands
# the green part and kicks the culprit out. Prints suite runs and wall time for both.
#
#   N=8 SUITE_SLEEP=2 lab/merge-batch.sh
set -euo pipefail
N=${N:-8}; SUITE_SLEEP=${SUITE_SLEEP:-2}; BAD=${BAD:-3}
LAB=$(mktemp -d /tmp/merge-batch.XXXXXX); R="$LAB/repo"; trap 'rm -rf "$LAB"' EXIT
git init -q -b main "$R"; cd "$R"
echo 'greet() { echo "hello $1"; }' > lib.sh; printf '. ./lib.sh\ngreet world\n' > app.sh
printf '#!/usr/bin/env bash\nset -e\nsleep %s\nfor f in app.sh extra*.sh; do [ -f "$f" ] && { bash "$f" | grep -q hello; }; done; true\n' "$SUITE_SLEEP" > suite.sh
chmod +x suite.sh; git add -A; git commit -qm init
for i in $(seq 1 "$N"); do
  git checkout -q -b "b$i" main
  if [ "$i" = "$BAD" ]; then printf '. ./lib.sh\nsalute world\n' > "extra$i.sh"; else echo "b$i" > "f$i.txt"; fi
  git add -A; git commit -qm "b$i"; git checkout -q main
done
runs=0
suite() { runs=$((runs+1)); git checkout -q "$1" && bash suite.sh >/dev/null 2>&1; }

# --- serial: each branch rebased and tested alone (what bin/merge.sh does) -------------------
t0=$(date +%s); refused=()
for i in $(seq 1 "$N"); do
  git rebase -q main "b$i" >/dev/null 2>&1
  if suite "b$i"; then git branch -f main "b$i"; else refused+=("b$i"); fi
done
git checkout -q main
echo "serial:  $runs suite runs, $(( $(date +%s) - t0 ))s, refused: ${refused[*]:-none}"

# --- batch: merge all, test once, bisect on red --------------------------------------------------
git reset -q --hard "$(git rev-list --max-parents=0 main)"; for i in $(seq 1 "$N"); do git branch -f "b$i" "b$i"; done
runs=0; t0=$(date +%s); culprits=()
try_batch() { # <branches...>: build a batch commit on main; 0 if green
  git checkout -q -B batch main
  for b in "$@"; do git merge -q --no-edit "$b" >/dev/null 2>&1 || { git merge --abort; return 2; }; done
  suite batch
}
land() { # bisect: land the green half, recurse into the red half
  [ $# = 0 ] && return 0
  if try_batch "$@"; then git branch -f main batch; return 0; fi
  if [ $# = 1 ]; then culprits+=("$1"); return 0; fi
  local half=$(( $# / 2 )); land "${@:1:half}"; land "${@:half+1}"
}
land $(seq -f 'b%g' 1 "$N")
git checkout -q main
echo "batch:   $runs suite runs, $(( $(date +%s) - t0 ))s, refused: ${culprits[*]:-none}"
for i in $(seq 1 "$N"); do [ "$i" = "$BAD" ] && continue; git show main:f$i.txt >/dev/null 2>&1 || { echo "ASSERT FAILED: b$i missing from main"; exit 1; }; done
git show main:extra$BAD.sh >/dev/null 2>&1 && { echo "ASSERT FAILED: culprit landed"; exit 1; }
bash suite.sh >/dev/null && echo "main green; same result both ways"
