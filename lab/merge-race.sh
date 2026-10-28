#!/usr/bin/env bash
# Stand for the merge flow of parallel sessions (README.md).
# Builds a throwaway repository, drives bin/merge.sh (copied in as scripts/merge.sh) from several worktrees at once, injects
# the failures a real day produces, and ends with asserts. It never touches this repository.
#
#   lab/merge-race.sh                    one run
#   RUNS=10 lab/merge-race.sh            ten runs in a row; any failed assert stops with exit 1
#   KEEP=1                               keep the lab directory for inspection
#
# Scenarios, each on the same lab `main`:
#   A  N branches edit the same line and merge at once; a scripted "agent" resolves each open rebase
#      and retries until every branch lands.
#   B  the session holding the merge lock is killed with SIGKILL in the middle of the pre-merge
#      suite; the next session must take the stale lock, the killed branch must land on a retry.
#   C  the pre-merge suite fails once (flaky) for one branch: main stays, a retry lands.
#   D  a semantic conflict: two branches with no textual overlap whose union fails the suite;
#      the second must be refused and main must stay green.
#   E  a detached-HEAD worktree (what Codex --worktree creates): the merge must either land the
#      change or refuse cleanly with main untouched.
#   F  N branches in disjoint files merge at once: all land, the wall time is printed (queue cost).
#
# ponytail: a shell stand with a 1 s fake suite; swap SUITE_SLEEP for the real e2e time to size the queue.
set -euo pipefail
unset MERGE_PREPARE MERGE_TARGET MERGE_EVENTS  # the stand builds its own repos; the caller's merge config (pnpm ship exports MERGE_PREPARE) must not reach them
N=${N:-5}
RUNS=${RUNS:-1}
SUITE_SLEEP=${SUITE_SLEEP:-1}
HERE=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "ASSERT FAILED: $*" >&2; exit 1; }

# --- lab repository -------------------------------------------------------------------------------
setup() {
  LAB=$(mktemp -d /tmp/merge-race.XXXXXX); R="$LAB/repo"
  git init -q -b main "$R"; cd "$R"
  mkdir -p .config scripts
  cp "$HERE/bin/merge.sh" "$HERE/bin/lib.sh" scripts/
  printf 'line1\nline2\nline3\n' > shared.txt
  cat > lib.sh <<'EOF'
greet() { echo "hello $1"; }
EOF
  cat > app.sh <<'EOF'
. ./lib.sh
greet world
EOF
  # The "suite": sleeps like a real run, runs the app, and fails once per branch when FLAKY_FOR names it.
  cat > scripts/suite.sh <<EOF
#!/usr/bin/env bash
set -e
sleep "\$(cat "$LAB/suite-sleep" 2>/dev/null || echo $SUITE_SLEEP)"
b=\$(git rev-parse --abbrev-ref HEAD)
if [ "\${FLAKY_FOR:-}" = "\$b" ] && [ ! -f "$LAB/flaked.\$b" ]; then touch "$LAB/flaked.\$b"; echo "suite: flaky failure on \$b"; exit 1; fi
bash app.sh | grep -q hello
EOF
  chmod +x scripts/suite.sh
  printf '[pre-merge]\nsuite = "scripts/suite.sh"\n' > .config/wt.toml
  git add -A && git commit -qm "init"
  wt config approvals add --yes >/dev/null 2>&1 || true
}

# Paths are remembered at creation: during an open rebase `git worktree list` shows "(detached HEAD)"
# instead of the branch, so looking a branch up later finds nothing.
wtpath() { cat "$LAB/path.$1"; }
branch() {
  wt -C "$R" switch --create "$1" --yes >/dev/null 2>&1
  git -C "$R" worktree list | awk -v b="[$1]" '$3==b{print $1}' > "$LAB/path.$1"; wtpath "$1"
}
merge_bg() { # start merge.sh in its own process group; the job pid lands in BG_PID (a $(...) child could not be waited for)
  (cd "$1" && exec perl -e 'setpgrp(0,0); exec @ARGV' ./scripts/merge.sh) >"$LAB/$2.log" 2>&1 </dev/null &
  BG_PID=$!
}
landed() { git -C "$R" merge-base --is-ancestor "$1" main 2>/dev/null; }
in_rebase() { [ -d "$(git -C "$1" rev-parse --git-dir)/rebase-merge" ]; }

# The scripted agent: keep both sides of the only conflict the stand creates (shared.txt line2).
resolve() { # <worktree> <branch>
  local cur; cur=$(git -C "$R" show main:shared.txt)
  printf "%s\nline2 from %s\n" "$cur" "$2" > "$1/shared.txt"
  git -C "$1" add shared.txt && GIT_EDITOR=true git -C "$1" rebase --continue >/dev/null 2>&1
}

# --- scenarios ------------------------------------------------------------------------------------
scenario_A() {
  echo "A: $N branches on one line, merged at once"
  local i p pids=()
  for i in $(seq 1 "$N"); do
    p=$(branch "a$i"); printf "line1\nline2 from a$i\nline3\n" > "$p/shared.txt"
    git -C "$p" commit -qam "a$i: own line2 (intent: a$i wants its line)"
  done
  for i in $(seq 1 "$N"); do merge_bg "$(wtpath a$i)" A$i; pids+=("$BG_PID"); done
  wait "${pids[@]}" 2>/dev/null || true
  local rounds=0 won
  while :; do
    rounds=$((rounds+1)); [ $rounds -le $((N+2)) ] || fail "A: did not converge in $rounds rounds"
    won=0
    for i in $(seq 1 "$N"); do
      landed a$i && continue
      p=$(wtpath a$i); in_rebase "$p" && resolve "$p" a$i
      (cd "$p" && ./scripts/merge.sh >"$LAB/A$i.r$rounds.log" 2>&1) || true
      landed a$i && won=$((won+1))
    done
    local pending=0; for i in $(seq 1 "$N"); do landed a$i || pending=1; done
    [ $pending = 0 ] && break
  done
  echo "   landed all $N in $rounds rounds"
  for i in $(seq 1 "$N"); do grep -q "line2 from a$i" <(git -C "$R" show main:shared.txt) || fail "A: a$i content missing on main"; done
}

scenario_B() {
  echo "B: SIGKILL of the lock holder during the suite"
  local p1 p2 pid1 pid2
  p1=$(branch b1); echo b1 > "$p1/b1.txt"; git -C "$p1" add -A; git -C "$p1" commit -qm "b1: file"
  p2=$(branch b2); echo b2 > "$p2/b2.txt"; git -C "$p2" add -A; git -C "$p2" commit -qm "b2: file"
  echo 8 > "$LAB/suite-sleep"; merge_bg "$p1" B1; pid1=$BG_PID
  local w=0; until grep -q "Running pre-merge" "$LAB/B1.log" 2>/dev/null; do sleep 0.2; w=$((w+1)); [ $w -lt 100 ] || fail "B: b1 never reached the suite"; done
  sleep 3  # inside the 8 s suite now
  merge_bg "$p2" B2; pid2=$BG_PID; sleep 1; rm "$LAB/suite-sleep"
  # merge.sh is its own process-group leader (setpgrp): kill the whole tree — merge.sh, wt, the suite
  kill -9 -- "-$pid1"
  wait "$pid2" 2>/dev/null || true
  landed b2 || fail "B: b2 did not land after the holder was killed (stale lock not taken)"
  landed b1 && fail "B: b1 landed although its merge was killed"
  in_rebase "$p1" && fail "B: b1 left with an open rebase"
  (cd "$p1" && ./scripts/merge.sh >"$LAB/B1.retry.log" 2>&1) || fail "B: b1 retry failed"
  landed b1 || fail "B: b1 not on main after retry"
  echo "   stale lock taken, killed branch landed on retry"
}

scenario_C() {
  echo "C: flaky suite fails once"
  local p before; p=$(branch c1); echo c1 > "$p/c1.txt"; git -C "$p" add -A; git -C "$p" commit -qm "c1: file"
  before=$(git -C "$R" rev-parse main)
  (cd "$p" && FLAKY_FOR=c1 ./scripts/merge.sh >"$LAB/C1.log" 2>&1) && fail "C: merge passed on a failing suite"
  [ "$(git -C "$R" rev-parse main)" = "$before" ] || fail "C: main moved on a failed suite"
  (cd "$p" && ./scripts/merge.sh >"$LAB/C1.retry.log" 2>&1) || fail "C: retry failed"
  landed c1 || fail "C: c1 not on main"
  echo "   refused once, landed on retry, main never moved on red"
}

scenario_D() {
  echo "D: semantic conflict without textual overlap"
  local p1 p2 before
  p1=$(branch d1); sed -i.bak 's/greet()/hello()/' "$p1/lib.sh"; sed -i.bak 's/^greet /hello /' "$p1/app.sh"; rm "$p1"/*.bak
  git -C "$p1" commit -qam "d1: rename greet to hello"
  p2=$(branch d2); printf '. ./lib.sh\ngreet again\n' > "$p2/extra.sh"; printf 'bash extra.sh | grep -q hello\n' >> "$p2/scripts/suite.sh"
  git -C "$p2" commit -qam "d2: extra caller of greet"
  (cd "$p1" && ./scripts/merge.sh >"$LAB/D1.log" 2>&1) || fail "D: d1 failed"
  before=$(git -C "$R" rev-parse main)
  (cd "$p2" && ./scripts/merge.sh >"$LAB/D2.log" 2>&1) && fail "D: d2 landed although the union is broken"
  in_rebase "$p2" && fail "D: d2 stopped at rebase; expected a clean rebase and a red suite"
  [ "$(git -C "$R" rev-parse main)" = "$before" ] || fail "D: main moved"
  (cd "$R" && git stash -q 2>/dev/null; bash scripts/suite.sh >/dev/null) || fail "D: main is red"
  echo "   clean rebase, red suite, refused; main green"
}

scenario_E() {
  echo "E: detached-HEAD worktree (Codex --worktree shape)"
  local p="$LAB/detached" before rc
  git -C "$R" worktree add -q --detach "$p" main
  echo e > "$p/e.txt"; git -C "$p" add -A; git -C "$p" commit -qm "e: detached change"
  before=$(git -C "$R" rev-parse main)
  (cd "$p" && ./scripts/merge.sh >"$LAB/E.log" 2>&1) && rc=0 || rc=$?
  if [ $rc = 0 ]; then
    git -C "$R" show main:e.txt >/dev/null 2>&1 || fail "E: exit 0 but change not on main"; echo "   landed"
  else
    [ "$(git -C "$R" rev-parse main)" = "$before" ] || fail "E: failed and main moved"
    echo "   refused cleanly (exit $rc): $(grep -m1 -E '✗|error' "$LAB/E.log" || true)"
  fi
  E_RESULT=$rc
}

scenario_F() {
  echo "F: $N disjoint branches at once (queue cost)"
  local i p pids=() t0
  for i in $(seq 1 "$N"); do p=$(branch "f$i"); echo "f$i" > "$p/f$i.txt"; git -C "$p" add -A; git -C "$p" commit -qm "f$i: file"; done
  t0=$(date +%s)
  for i in $(seq 1 "$N"); do merge_bg "$(wtpath f$i)" F$i; pids+=("$BG_PID"); done
  wait "${pids[@]}" 2>/dev/null || true
  for i in $(seq 1 "$N"); do landed f$i || fail "F: f$i did not land (log: $LAB/F$i.log)"; done
  echo "   all $N landed in $(( $(date +%s) - t0 ))s with a ${SUITE_SLEEP}s suite"
}

# free = no mkdir-style lock dir, and a flock-style lock file can be taken right now
lock_free() { [ ! -d "$1" ] && { [ ! -e "$1" ] || perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$1"; }; }
# --- invariants -----------------------------------------------------------------------------------
invariants() {
  lock_free "$R/.git/wt-merge.lock" || fail "lock left behind"
  [ -z "$(git -C "$R" rev-list --merges main)" ] || fail "main is not linear"
  git -C "$R" fsck --no-progress >/dev/null 2>&1 || fail "git fsck"
  (cd "$R" && bash scripts/suite.sh >/dev/null) || fail "suite red on final main"
  # every branch is on main, in an open rebase, or refused for a known reason (d2, detached)
  local b; for b in $(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$'); do
    landed "$b" && continue
    [ "$b" = d2 ] && continue
    fail "branch $b is neither on main nor expected to be refused"
  done
  echo "invariants: lock free, main linear, fsck clean, suite green, no lost branch"
}

run() {
  setup
  scenario_A; scenario_B; scenario_C; scenario_D; scenario_E; scenario_F
  invariants
  cd /; [ "${KEEP:-}" = 1 ] && echo "lab kept at $LAB" || rm -rf "$LAB"
}

for r in $(seq 1 "$RUNS"); do echo "=== run $r/$RUNS"; run; done
echo "PASS: $RUNS run(s)"
