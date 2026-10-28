#!/usr/bin/env bash
# Randomized measurement of many sessions merging at once. One run = one throwaway repository,
# N sessions started over a window, each with one branch that edits random lines of a few shared
# files. A session is a scripted agent: it drives the merge and, on a conflict, resolves it by
# keeping both sides after a random "thinking" delay. Faults are drawn per session from SEED:
# a flaky suite, a semantic conflict (two branches fine alone, red together), a SIGKILL of the
# session's merge at a random moment. Every step appends a JSON line to $OUT; lab/summary.py reads it.
#
#   MODE=ship  lab/race.sh   sessions run bin/ship.sh (review off, agent = a stub `claude` on PATH)
#   MODE=lock  lab/race.sh   sessions loop over bin/merge.sh and resolve conflicts themselves
#   MODE=bare  lab/race.sh   the same loop over a bare `wt merge` — the baseline without the lock
#   RUNS=20 SEED=1 N=8 OUT=/tmp/race.jsonl lab/race.sh
#   BIN=<dir> lab/race.sh    run another copy of merge.sh / ship.sh (default: bin/ of this checkout)
#   PUSH=1 lab/race.sh       main is also on a bare remote, and every merge goes through MERGE_PUSH=origin
#
# The seed fixes the plan (who edits what, who flakes, who is killed and when), not the interleaving:
# the OS scheduler still decides who wins the lock, so a failed seed may pass on a rerun. This stand is a smoke and
# a measurement: it finds new failure shapes and sizes the queue. The regression guards for the failures it found
# are deterministic: lab/recover.sh (R1-R5) and lab/lock.sh. Each run id is <mode>-<seed>-<pid>, unique per invocation.
# Invariants checked after every run (a violation is a JSON line ev=violation and exit 1 at the end):
#   lost      an edit of a landed branch is missing on main
#   red       a first-parent commit of main fails the suite (deterministic part)
#   refused   a branch is not on main and has no valid reason (semantic conflict with main, owner-stop)
#   shape     MODE=lock|ship: a first-parent commit of main after the setup is not a merge commit (merge.sh lands
#             every branch with --no-ff); MODE=bare: main has a merge commit
#   pushed    PUSH=1: the remote's main is not main at the end
#   lock      the lock is left behind after every session ended
#   overlap   two pre-merge suites ran at once in MODE=lock|ship (the lock did not serialize them); a suite left
#             running by a SIGKILLed wt is counted apart as overlap-orphan, not a violation
#   timeout   a session did not finish within DEADLINE seconds
# Dependent work (off by default, so old seeds replay the same plans):
#   P_DEP=20   % of sessions that need another session's change (D1): the suite is red while the provider is not in the tree.
#              DEP_POLICY=retry: the stub reruns as it is; DEP_POLICY=rebase: it rebases onto main first (default).
#              Valid stop: dep-missing while the provider is not on main. Waits are DEP_WAIT tries of ~1.5 s, apart from TRIES.
#   P_DUP=20   % of sessions that make exactly the edits of an earlier session (D2). A token on main twice is counted as
#              dup-twice (the stub's keep-both resolution can do it); it is a measurement, not a violation.
# ponytail: a 3-line file per conflict hot spot and a sleep for a suite; swap SUITE for real tests to size it.
set -uo pipefail; set +m
unset MERGE_PREPARE MERGE_TARGET MERGE_EVENTS  # the stand builds its own repos; the caller's merge config (pnpm ship exports MERGE_PREPARE) must not reach them
MODE=${MODE:-ship}; RUNS=${RUNS:-1}; SEED=${SEED:-$$}; N=${N:-6}
FILES=${FILES:-4}       # shared files; fewer = more conflicts
EDITS=${EDITS:-2}       # lines each branch edits, each in a random shared file
LINES=${LINES:-6}       # lines per shared file
SUITE=${SUITE:-0.5}     # seconds of one suite run (pre-merge and pre-queue)
WINDOW=${WINDOW:-3}     # sessions start at random within this many seconds
THINK=${THINK:-2}       # max seconds a stub agent takes to resolve a conflict
P_FLAKY=${P_FLAKY:-10}  # % of sessions whose suite fails once
P_SEM=${P_SEM:-15}      # % of sessions that take part in a semantic conflict
P_KILL=${P_KILL:-15}    # % of sessions whose merge is SIGKILLed once at a random moment
TRIES=${TRIES:-12}      # merge attempts a session makes before it gives up
P_DEP=${P_DEP:-0}       # % of sessions that need another session's change
P_DUP=${P_DUP:-0}       # % of sessions that duplicate an earlier session's edits
DEP_POLICY=${DEP_POLICY:-rebase}; DEP_WAIT=${DEP_WAIT:-60}
DEADLINE=${DEADLINE:-300}
OUT=${OUT:-/tmp/race.$MODE.jsonl}
HERE=$(cd "$(dirname "$0")/.." && pwd); BIN=${BIN:-$HERE/bin}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
log() { printf '{"t":%s,"run":"%s","mode":"%s","ev":"%s"%s}\n' "$(now)" "$RUN" "$MODE" "$1" "${2:+,$2}" >> "$OUT"; }
violation() { log violation "\"kind\":\"$1\",\"detail\":\"$2\""; echo "  VIOLATION $1: $2" >&2; VIOL=$((VIOL+1)); }
# sets RND, no command substitution: a subshell would not advance RANDOM in the parent, so on bash 3.2 the seed did not fix the plan
rnd() { RND=$((RANDOM % $1)); }

setup() {
  LAB=$(mktemp -d /tmp/wt-race.XXXXXX); R="$LAB/repo"; export LAB
  git init -q -b main "$R"; cd "$R"
  git config merge.conflictStyle merge; git config rerere.enabled false; git config commit.gpgsign false
  mkdir -p .config scripts
  for f in $(seq 1 "$FILES"); do for l in $(seq 1 "$LINES"); do echo "f$f line $l"; done > "f$f.txt"; done
  # The suite: sleeps like a real run; fails once per branch when the branch is marked flaky; fails for good when
  # an api removal and a caller of that api meet (the semantic conflict). `merge` mode also marks a critical section.
  cat > scripts/suite.sh <<'EOF'
#!/usr/bin/env bash
b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$1" = merge ]; then
  # a section left by a SIGKILLed suite is not an overlap: only a live pid counts. A live suite whose wt was
  # SIGKILLed (wt runs hooks in their own process group, so they outlive it) is an orphan: counted apart.
  for d in "$LAB"/cs.*; do [ -d "$d" ] && kill -0 "${d##*.}" 2>/dev/null || continue
    k=overlap; [ "$(ps -o ppid= -p "$(ps -o pgid= -p "${d##*.}" | tr -d ' ')" 2>/dev/null | tr -d ' ')" = 1 ] && k=overlap-orphan
    in=${d#"$LAB"/cs.}; in=${in%.*}
    echo "{\"t\":0,\"run\":\"$RUN\",\"mode\":\"$MODE\",\"ev\":\"$k\",\"branch\":\"$b\",\"inner\":\"$in\"}" >> "$OUT"; done
  mkdir "$LAB/cs.$b.$$"
  trap 'rmdir "$LAB/cs.$b.$$"' EXIT
fi
echo "{\"t\":$(perl -MTime::HiRes=time -e 'printf "%.3f", time'),\"run\":\"$RUN\",\"mode\":\"$MODE\",\"ev\":\"suite\",\"kind\":\"$1\",\"branch\":\"$b\"}" >> "$OUT"
[ "${SUITE_FAST:-}" = 1 ] || sleep "$SUITE"
if [ -f "$LAB/flaky.$b" ] && [ "${SUITE_FAST:-}" != 1 ]; then rm "$LAB/flaky.$b"; echo "suite: flaky failure"; exit 1; fi
for n in needs-*-by-*; do [ -e "$n" ] || continue; d=${n#needs-}; d=${d%%-by-*}; [ -f "provides-$d" ] || { echo "suite: missing dependency $d"; exit 1; }; done
if [ -f removes-api ] && ls uses-api-* >/dev/null 2>&1; then echo "suite: a caller of the removed api"; exit 1; fi
exit 0
EOF
  chmod +x scripts/suite.sh
  printf '[pre-merge]\nsuite = "scripts/suite.sh merge"\n' > .config/wt.toml
  git add -A && git commit -qm init
  wt config approvals add --yes >/dev/null 2>&1 || true
  # The stub agent for ship.sh: answers a review with REVIEW OK, a conflict with a resolution that keeps both sides.
  mkdir -p "$LAB/bin"
  cat > "$LAB/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=\$(cat)
case "\$prompt" in
  *"stopped on a conflict"*) "$HERE/lab/resolve.sh" "\$(perl -e "printf '%.2f', rand($THINK)")" ;;
  *) echo "REVIEW OK" ;;
esac
EOF
  chmod +x "$LAB/bin/claude"
}

# One session: create a branch with its edits, wait for its start, merge until it lands or gives up.
plan_session() { # <i>: draw the plan from RANDOM in the parent so the seed fixes it
  local i=$1 e f l j
  rnd 1000; S_START[$i]=$(perl -e "printf '%.2f', $RND/1000*$WINDOW")
  S_EDITS[$i]=""; for e in $(seq 1 "$EDITS"); do rnd "$FILES"; f=$((RND + 1)); rnd "$LINES"; l=$((RND + 1)); S_EDITS[$i]="${S_EDITS[$i]} $f:$l"; done
  S_FLAKY[$i]=0; rnd 100; [ "$RND" -lt "$P_FLAKY" ] && S_FLAKY[$i]=1
  S_SEM[$i]=none; rnd 100; if [ "$RND" -lt "$P_SEM" ]; then rnd 2; if [ "$RND" = 0 ]; then S_SEM[$i]=remove; else S_SEM[$i]=use; fi; fi
  S_KILL[$i]=none; rnd 100; if [ "$RND" -lt "$P_KILL" ]; then rnd 1000; S_KILL[$i]=$(perl -e "printf '%.2f', $RND/1000*($SUITE*3+1)"); fi
  S_LABEL[$i]=s$i; S_NEED[$i]=none
  if [ "$P_DUP" -gt 0 ] && [ "$i" -gt 1 ] && { rnd 100; [ "$RND" -lt "$P_DUP" ]; }; then
    rnd $((i - 1)); j=$((RND + 1)); S_EDITS[$i]=${S_EDITS[$j]}; S_LABEL[$i]=${S_LABEL[$j]}; S_SEM[$i]=none
  elif [ "$P_DEP" -gt 0 ] && [ "$i" -gt 1 ] && { rnd 100; [ "$RND" -lt "$P_DEP" ]; }; then
    rnd $((i - 1)); j=$((RND + 1)); S_NEED[$i]=s$j   # an earlier session: the graph has no cycle
  fi
}

make_branch() { # <i>
  local i=$1 b="s$1" p e f l
  wt -C "$R" switch --create "$b" --yes --no-cd >/dev/null 2>&1 || wt -C "$R" switch --create "$b" --yes >/dev/null 2>&1
  p=$(git -C "$R" worktree list --porcelain | awk -v b="refs/heads/$b" '/^worktree /{w=$2} $0=="branch "b{print w}')
  echo "$p" > "$LAB/path.$b"
  for e in ${S_EDITS[$i]}; do f=${e%%:*}; l=${e##*:}
    # replace line l of file f with this branch's edit; an edit already there (same line twice) stays
    perl -i -pe "s/^.*\$/\$& | ${S_LABEL[$i]}\@$f:$l/ if \$. == $l" "$p/f$f.txt"
  done
  [ "${S_NEED[$i]}" = none ] || touch "$p/needs-${S_NEED[$i]}-by-$b"
  for e in $(seq 1 "$N"); do [ "${S_NEED[$e]}" = "$b" ] && { touch "$p/provides-$b"; break; }; done
  case ${S_SEM[$i]} in remove) touch "$p/removes-api" ;; use) touch "$p/uses-api-$b" ;; esac
  [ "${S_FLAKY[$i]}" = 1 ] && touch "$LAB/flaky.$b"
  git -C "$p" add -A && git -C "$p" commit -qm "$b: edits${S_EDITS[$i]} sem=${S_SEM[$i]} need=${S_NEED[$i]} label=${S_LABEL[$i]} (intent: keep every edit)"
}

attempt() { # <worktree> <cmd…>: one merge attempt in its own process group, SIGKILLed once if planned; rc in ARC
  local p=$1; shift
  (cd "$p" && exec perl -e 'setpgrp(0,0); exec @ARGV' "$@") >>"$LAB/$(basename "$p").log" 2>&1 </dev/null &
  local pid=$! k=""
  if [ "$KILL_AT" != none ]; then
    ( sleep "$KILL_AT"; kill -0 "$pid" 2>/dev/null && kill -9 -- "-$pid" 2>/dev/null && echo killed > "$LAB/killed.$pid" ) & k=$!
    KILL_AT=none
  fi
  wait "$pid"; ARC=$?
  [ -z "$k" ] || { kill "$k" 2>/dev/null; wait "$k" 2>/dev/null; }
  [ -f "$LAB/killed.$pid" ] && { ARC=137; return; }
}

in_rebase() { [ -d "$(git -C "$1" rev-parse --git-dir)/rebase-merge" ] || [ -d "$(git -C "$1" rev-parse --git-dir)/rebase-apply" ]; }
landed() { git -C "$R" merge-base --is-ancestor "$1" main 2>/dev/null; }

session() { # <i>
  local i=$1 b="s$1" p try=0 t0 outcome=gave-up dw=0 sz=0
  p=$(cat "$LAB/path.$b"); KILL_AT=${S_KILL[$i]}
  sleep "${S_START[$i]}"; t0=$(now); log start "\"branch\":\"$b\",\"flaky\":${S_FLAKY[$i]},\"sem\":\"${S_SEM[$i]}\",\"kill\":\"${S_KILL[$i]}\",\"need\":\"${S_NEED[$i]}\",\"label\":\"${S_LABEL[$i]}\""
  while [ "$try" -lt "$TRIES" ]; do try=$((try + 1))
    # Recovery a real agent does first: a rebase stopped by a kill (no conflicts) is continued; one with conflicts is resolved.
    if in_rebase "$p"; then
      log recover "\"branch\":\"$b\""
      (cd "$p" && "$HERE/lab/resolve.sh" "$(perl -e "printf '%.2f', rand($THINK)")") >>"$LAB/$b.log" 2>&1
      # a kill after git staged a pick and before its commit: --continue refuses ("you have staged changes"); ship.sh's
      # message offers git rebase --abort for that, as a real agent would do (seed 261042, PUSH=1)
      in_rebase "$p" && git -C "$p" rebase --abort >>"$LAB/$b.log" 2>&1 && log recover-abort "\"branch\":\"$b\""
    fi
    sz=0; [ ! -f "$LAB/$(basename "$p").log" ] || sz=$(wc -c < "$LAB/$(basename "$p").log")  # this attempt's output starts here
    case $MODE in
      ship) attempt "$p" env SHIP_REVIEW=0 SHIP_AGENT=claude SHIP_TEST="scripts/suite.sh pre" "$BIN/ship.sh" ;;
      lock) attempt "$p" "$BIN/merge.sh" ;;
      bare) attempt "$p" wt merge --yes --no-remove --no-squash ;;
    esac
    log attempt "\"branch\":\"$b\",\"try\":$try,\"rc\":$ARC,\"rebase\":$(in_rebase "$p" && echo true || echo false)"
    # exit 5 (merge.sh, ship.sh): on main but commits lost; do what the message says
    if [ "$ARC" = 5 ]; then
      o=$(cat "$(git -C "$p" rev-parse --git-dir)/merge-orig"); git -C "$p" reset -q --hard "$o"; log restore "\"branch\":\"$b\""; continue
    fi
    # the baseline reports success by exit code alone; merge.sh and ship.sh vouch for the commits, so trust only their 0
    if { [ "$MODE" = bare ] || [ "$ARC" = 0 ]; } && landed "$b"; then outcome=landed; break; fi
    # D1: red only for a missing dependency. The stub waits ~1.5 s (an agent reading the failure), rebases onto main
    # when DEP_POLICY=rebase, and tries again; these waits do not count as attempts. Where: lock = red under the lock.
    if [ "$ARC" != 0 ] && [ "$ARC" != 137 ] && ! in_rebase "$p" && [ "${S_NEED[$i]}" != none ] && tail -c +$((sz + 1)) "$LAB/$(basename "$p").log" | grep -q "missing dependency"; then
      dw=$((dw + 1)); w=pre; tail -c +$((sz + 1)) "$LAB/$(basename "$p").log" | grep -q "tests are red on" || w=lock
      log dep-wait "\"branch\":\"$b\",\"need\":\"${S_NEED[$i]}\",\"where\":\"$w\",\"n\":$dw"
      [ "$dw" -ge "$DEP_WAIT" ] && { outcome=dep-missing; break; }
      sleep 1.5; try=$((try - 1)); echo "--- dep-wait $dw" >> "$LAB/$(basename "$p").log"
      [ "$DEP_POLICY" = rebase ] && (cd "$p" && git rebase -q main >/dev/null 2>&1 || "$HERE/lab/resolve.sh" 0 >/dev/null 2>&1)
      continue
    fi
    # ship exit 3 = the agent asked the owner; a session stops there
    [ "$MODE" = ship ] && [ "$ARC" = 3 ] && { outcome=owner; break; }
    # a red suite twice in a row with no rebase in between and no flake left: the branch is refused
    if [ "$ARC" != 137 ] && ! in_rebase "$p" && [ ! -f "$LAB/flaky.$b" ] && grep -q "a caller of the removed api" "$LAB/$b.log" 2>/dev/null; then
      outcome=refused; break
    fi
  done
  log end "\"branch\":\"$b\",\"outcome\":\"$outcome\",\"tries\":$try,\"secs\":$(perl -e "printf '%.2f', $(now)-$t0")"
}

# free = no mkdir-style lock dir, and a flock-style lock file can be taken right now
lock_free() { [ ! -d "$1" ] && { [ ! -e "$1" ] || perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$1"; }; }
check() {
  local i b e f l tok c
  lock_free "$R/.git/wt-merge.lock" || violation lock "left behind: $(cat "$R/.git/wt-merge.lock"/pid "$R/.git/wt-merge.lock" 2>/dev/null)"
  if [ "$MODE" = bare ]; then [ -z "$(git -C "$R" rev-list --merges main)" ] || violation shape "merge commit on main"
  else for c in $(git -C "$R" rev-list --first-parent --no-merges "$BASE..main"); do violation shape "not a merge commit: $(git -C "$R" log -1 --format='%h %s' "$c")"; done; fi
  [ "${PUSH:-0}" = 0 ] || [ "$(git -C "$R" rev-parse main)" = "$(git --git-dir="$LAB/origin.git" rev-parse main)" ] || violation pushed "origin/main $(git --git-dir="$LAB/origin.git" rev-parse --short main), main $(git -C "$R" rev-parse --short main)"
  for c in $(git -C "$R" rev-list --first-parent main); do
    git -C "$R" worktree add -q --detach "$LAB/chk" "$c" 2>/dev/null
    (cd "$LAB/chk" && SUITE_FAST=1 OUT=/dev/null bash scripts/suite.sh check >/dev/null) || violation red "$(git -C "$R" log -1 --format='%h %s' "$c")"
    git -C "$R" worktree remove --force "$LAB/chk"
  done
  for i in $(seq 1 "$N"); do b="s$i"
    if landed "$b"; then
      for e in ${S_EDITS[$i]}; do f=${e%%:*}; l=${e##*:}; tok="${S_LABEL[$i]}@$f:$l"
        git -C "$R" show "main:f$f.txt" | grep -q " $tok" || violation lost "$tok"
        [ "${S_LABEL[$i]}" = "$b" ] || [ "$(git -C "$R" show "main:f$f.txt" | grep -o " $tok\b" | wc -l)" -le 1 ] || log dup-twice "\"branch\":\"$b\",\"token\":\"$tok\""
      done
    else
      # valid refusals: a semantic conflict with what main holds, or an owner stop
      case ${S_SEM[$i]} in
        remove) git -C "$R" ls-tree --name-only main | grep -q '^uses-api-' && continue ;;
        use) git -C "$R" cat-file -e main:removes-api 2>/dev/null && continue ;;
      esac
      grep "\"run\":\"$RUN\"" "$OUT" | grep -q "\"branch\":\"$b\",\"outcome\":\"owner\"" && continue
      [ "${S_NEED[$i]}" != none ] && ! landed "${S_NEED[$i]}" && continue  # D1: its provider never reached main
      violation refused "$b not on main ($(grep "\"run\":\"$RUN\"" "$OUT" | grep "\"branch\":\"$b\",\"outcome\"" | tail -1 | sed 's/.*outcome":"\([^"]*\)".*/\1/'))"
    fi
  done
  # an overlap entered by the suite of a session whose merge was SIGKILLed in this run is that killed merge's
  # orphan (wt keeps hooks in their own process group); the lock itself is checked directly by lab/lock.sh.
  # ponytail: keyed on the entering branch, so a later real overlap of a once-killed branch is excused too; lock.sh guards that
  local ov=0 ob
  # the inner suite's branch counts too: a killed merge's wt hook can start its suite after the kill freed the lock, while
  # its reparenting is not visible yet (lock seed 261069: s3 killed at .679, its suite started at .772 inside s4's)
  for ob in $(grep "\"run\":\"$RUN\",\"mode\":\"$MODE\",\"ev\":\"overlap\"" "$OUT" | sed 's/.*"branch":"\([^"]*\)","inner":"\([^"]*\)".*/\1,\2/'); do
    for x in ${ob%,*} ${ob#*,}; do
      grep -q "\"run\":\"$RUN\",\"mode\":\"$MODE\",\"ev\":\"attempt\",\"branch\":\"$x\",\"try\":[0-9]*,\"rc\":137" "$OUT" &&
        { log overlap-orphan "\"branch\":\"$x\",\"relabeled\":true"; continue 2; }
    done
    ov=$((ov+1))
  done
  [ "$ov" = 0 ] || [ "$MODE" = bare ] || violation overlap "$ov suite(s) inside another"
}

TOTAL_VIOL=0; FAILED_SEEDS=""
export PATH # the stub claude goes first in ship mode
for r in $(seq 1 "$RUNS"); do
  s=$((SEED + r - 1)); RANDOM=$s; RUN="$MODE-$s-$$"; VIOL=0
  export RUN MODE OUT SUITE
  setup; [ "$MODE" = ship ] && export PATH="$LAB/bin:$PATH"
  S_START=(); S_EDITS=(); S_FLAKY=(); S_SEM=(); S_KILL=()
  S_LABEL=(); S_NEED=()
  for i in $(seq 1 "$N"); do plan_session "$i"; done   # every plan first: a branch provides what a later plan needs
  for i in $(seq 1 "$N"); do make_branch "$i"; done
  BASE=$(git -C "$R" rev-parse main)
  if [ "${PUSH:-0}" = 1 ]; then git init -q --bare "$LAB/origin.git"; git -C "$R" remote add origin "$LAB/origin.git"; git -C "$R" push -q origin main; export MERGE_PUSH=origin; fi
  log run "\"seed\":$s,\"n\":$N,\"files\":$FILES,\"edits\":$EDITS,\"lines\":$LINES,\"suite\":$SUITE,\"window\":$WINDOW,\"think\":$THINK"
  export MERGE_EVENTS="$LAB/merge-events.jsonl"
  # a killed attempt can leave index.lock behind; merge.sh removes one older than this many seconds (default 60)
  export MERGE_STALE_INDEX_LOCK=1
  t0=$(now); pids=()
  for i in $(seq 1 "$N"); do session "$i" & pids+=($!); done
  ( sleep "$DEADLINE"; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p" >> "$LAB/timeouts" && pkill -9 -P "$p"; kill -9 "$p" 2>/dev/null; done ) & guard=$!
  wait "${pids[@]}" 2>/dev/null; kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  [ ! -s "$LAB/timeouts" ] || violation timeout "$(wc -l < "$LAB/timeouts" | tr -d ' ') session(s) past ${DEADLINE}s"
  # merge.sh / ship.sh events carry no run id; tag them while copying
  [ ! -f "$MERGE_EVENTS" ] || sed "s/^{/{\"run\":\"$RUN\",\"mode\":\"$MODE\",/" "$MERGE_EVENTS" >> "$OUT"
  check
  log run-end "\"secs\":$(perl -e "printf '%.2f', $(now)-$t0"),\"violations\":$VIOL"
  echo "run $r/$RUNS seed=$s mode=$MODE: $(git -C "$R" rev-list --count main) commits on main, $VIOL violation(s), $(perl -e "printf '%.0f', $(now)-$t0")s"
  [ "$VIOL" = 0 ] || { FAILED_SEEDS="$FAILED_SEEDS $s"; [ "${KEEP_FAILED:-1}" = 1 ] && echo "  lab kept: $LAB"; }
  TOTAL_VIOL=$((TOTAL_VIOL+VIOL))
  pkill -9 -f "$LAB" 2>/dev/null; cd /
  { [ "$VIOL" != 0 ] && [ "${KEEP_FAILED:-1}" = 1 ]; } || [ "${KEEP:-}" = 1 ] || rm -rf "$LAB"
  [ "$MODE" = ship ] && export PATH="${PATH#"$LAB/bin:"}"
done
[ "$TOTAL_VIOL" = 0 ] && echo "PASS: $RUNS run(s), mode=$MODE" || { echo "FAIL: $TOTAL_VIOL violation(s); seeds:$FAILED_SEEDS"; exit 1; }
