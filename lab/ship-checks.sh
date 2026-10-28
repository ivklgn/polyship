#!/usr/bin/env bash
# Deterministic checks of bin/ship.sh's own decisions, with a stub agent on PATH: what it does with each verdict,
# and that its fence stops a merge after an agent moved the target, added a remote or planted a hook. The lab's
# stub answers by the env: STUB_REVIEW / STUB_CONFLICT are shell run for a review / a conflict prompt.
#
#   S1  refusals before any agent: on the target, detached HEAD, a dirty tree, an unknown SHIP_AGENT: exit 2
#   S2  a branch already on the target: exit 0, no agent called
#   S3  review verdicts: REVIEW OK lands; REVIEW BLOCKED, no verdict line, or a quoted verdict: exit 1, target unmoved
#   S4  a review that leaves uncommitted changes: exit 1
#   S5  the fence: the agent adds a remote, plants a hook, moves the target: exit 4, target unmoved by ship
#   S6  red tests before the queue: exit 1, the test log tail on stderr
#   S7  a conflict: resolved by the agent lands; OWNER DECISION NEEDED: exit 3, rebase open; left open: exit 1
#   S8  MERGE_PREPARE: one that fails is a merge failed without a conflict, exit 1; one that succeeds runs, then lands
#   S9  SHIP_AGENT=codex: codex is called with the review prompt
#
#   lab/ship-checks.sh             against bin/ of this checkout
#   BIN=<dir> lab/ship-checks.sh   against another copy
set -uo pipefail
unset MERGE_PREPARE MERGE_TARGET MERGE_EVENTS SHIP_REVIEW SHIP_AGENT SHIP_TEST SHIP_REVIEW_HOW
HERE=$(cd "$(dirname "$0")/.." && pwd); BIN=${BIN:-$HERE/bin}
LAB=$(mktemp -d /tmp/wt-ship.XXXXXX); trap 'rm -rf "$LAB"' EXIT
status=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; status=1; }

mkdir "$LAB/bin"
for a in claude codex; do
  cat > "$LAB/bin/$a" <<EOF
#!/usr/bin/env bash
prompt=\$(cat); echo "$a \$*" >> "$LAB/calls"; printf '%s\n' "\$prompt" > "$LAB/prompt"
case "\$prompt" in
  *"stopped on a conflict"*) eval "\${STUB_CONFLICT:-$HERE/lab/resolve.sh 0}" ;;
  *) eval "\${STUB_REVIEW:-echo REVIEW OK}" ;;
esac
EOF
  chmod +x "$LAB/bin/$a"
done
export PATH="$LAB/bin:$PATH"

repo() { # fresh repo on main with one shared file, and a worktree s1 with one commit
  rm -rf "$LAB/r" "$LAB"/r.* "$LAB/calls"; git init -q -b main "$LAB/r"
  printf 'a\nb\nc\n' > "$LAB/r/f.txt"; git -C "$LAB/r" add f.txt; git -C "$LAB/r" commit -qm init
  git -C "$LAB/r" config merge.conflictStyle merge
  git -C "$LAB/r" worktree add -q -b s1 "$LAB/r.s1" main
  echo s1 > "$LAB/r.s1/s1.txt"; git -C "$LAB/r.s1" add s1.txt; git -C "$LAB/r.s1" commit -qm "s1: new file"
  main0=$(git -C "$LAB/r" rev-parse main)
}
ship() { # <dir> [env…]: ship.sh there, review on, tests green; rc in rc, output in $LAB/out
  local d=$1; shift
  rc=0; (cd "$d" && env SHIP_TEST=true "$@" "$BIN/ship.sh" > "$LAB/out" 2>&1) || rc=$?
}
landed() { git -C "$LAB/r" cat-file -e "main:$1" 2>/dev/null; }
unmoved() { [ "$(git -C "$LAB/r" rev-parse main)" = "$main0" ]; }
calls() { cat "$LAB/calls" 2>/dev/null | wc -l | tr -d ' '; }

# --- S1 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r"; [ $rc = 2 ] && [ "$(calls)" = 0 ] && ok "S1 on the target: exit 2" || bad "S1 on the target: exit $rc, agent calls $(calls)"
git -C "$LAB/r.s1" checkout -q --detach
ship "$LAB/r.s1"; [ $rc = 2 ] && ok "S1 detached HEAD: exit 2" || bad "S1 detached HEAD: exit $rc"
git -C "$LAB/r.s1" checkout -q s1; echo dirty >> "$LAB/r.s1/s1.txt"
ship "$LAB/r.s1"; [ $rc = 2 ] && unmoved && [ "$(calls)" = 0 ] && ok "S1 dirty tree: exit 2" || bad "S1 dirty tree: exit $rc, agent calls $(calls)"
git -C "$LAB/r.s1" checkout -q -- s1.txt
ship "$LAB/r.s1" SHIP_AGENT=gpt; [ $rc = 2 ] && grep -q "unknown SHIP_AGENT=gpt" "$LAB/out" && ok "S1 unknown SHIP_AGENT: exit 2" || bad "S1 unknown SHIP_AGENT: exit $rc"

# --- S2 ----------------------------------------------------------------------------------------------
repo; git -C "$LAB/r.s1" reset -q --hard main
ship "$LAB/r.s1"; [ $rc = 0 ] && [ "$(calls)" = 0 ] && grep -q "already on main" "$LAB/out" && ok "S2 already on the target: exit 0, no agent" || bad "S2 already on the target: exit $rc, agent calls $(calls)"

# --- S3 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1"; [ $rc = 0 ] && landed s1.txt && grep -q "for correctness, the task in the commit messages, tests" "$LAB/prompt" && ok "S3 REVIEW OK: landed" || bad "S3 REVIEW OK: exit $rc ($(tail -1 "$LAB/out"))"
repo
ship "$LAB/r.s1" STUB_REVIEW='echo "REVIEW BLOCKED: no tests"'
[ $rc = 1 ] && unmoved && grep -q "REVIEW BLOCKED: no tests" "$LAB/out" && ok "S3 REVIEW BLOCKED: exit 1, target unmoved" || bad "S3 REVIEW BLOCKED: exit $rc"
ship "$LAB/r.s1" STUB_REVIEW='echo "looks fine"'
[ $rc = 1 ] && unmoved && grep -q "did not end with a verdict" "$LAB/out" && ok "S3 no verdict line: exit 1" || bad "S3 no verdict line: exit $rc"
ship "$LAB/r.s1" STUB_REVIEW='echo "I will print REVIEW OK at the end"; echo; echo "  "'
[ $rc = 1 ] && unmoved && ok "S3 a verdict quoted in prose is not a verdict: exit 1" || bad "S3 quoted verdict: exit $rc"

# --- S4 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1" STUB_REVIEW='echo fix >> s1.txt; echo REVIEW OK'
[ $rc = 1 ] && unmoved && grep -q "left uncommitted changes" "$LAB/out" && ok "S4 review left a dirty tree: exit 1" || bad "S4 review left a dirty tree: exit $rc"

# --- S5 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1" STUB_REVIEW='git remote add evil /tmp/evil; echo REVIEW OK'
[ $rc = 4 ] && unmoved && ok "S5 a remote added by the agent: exit 4" || bad "S5 remote added: exit $rc"
git -C "$LAB/r" remote remove evil
ship "$LAB/r.s1" STUB_REVIEW='h=$(git rev-parse --git-common-dir)/hooks; mkdir -p "$h"; printf "#!/bin/sh\n" > "$h/pre-push"; echo REVIEW OK'
[ $rc = 4 ] && unmoved && ok "S5 a hook planted by the agent: exit 4" || bad "S5 hook planted: exit $rc"
rm -f "$(git -C "$LAB/r" rev-parse --git-common-dir)/hooks/pre-push" "$LAB/calls"
ship "$LAB/r.s1" STUB_REVIEW='git update-ref refs/heads/main HEAD; echo REVIEW OK'
[ $rc = 4 ] && [ "$(git -C "$LAB/r" rev-parse main)" = "$(git -C "$LAB/r.s1" rev-parse HEAD)" ] && [ "$(calls)" = 1 ] &&
  ok "S5 the target moved by the agent: exit 4, no merge after it" || bad "S5 target moved: exit $rc"

# --- S6 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1" SHIP_REVIEW=0 SHIP_TEST='echo suite-output-marker; exit 3'
[ $rc = 1 ] && unmoved && grep -q suite-output-marker "$LAB/out" && grep -q "tests are red on s1" "$LAB/out" && [ "$(calls)" = 0 ] &&
  ok "S6 red tests: exit 1, log tail shown" || bad "S6 red tests: exit $rc"

# --- S7 ----------------------------------------------------------------------------------------------
conflict() { # s1 and main both edit line b
  repo
  sed -i.bak 's/^b$/b s1/' "$LAB/r.s1/f.txt"; rm "$LAB/r.s1/f.txt.bak"; git -C "$LAB/r.s1" commit -qam "s1: edit b"
  sed -i.bak 's/^b$/b main/' "$LAB/r/f.txt"; rm "$LAB/r/f.txt.bak"; git -C "$LAB/r" commit -qam "main: edit b"
  main0=$(git -C "$LAB/r" rev-parse main)
}
open() { [ -d "$(git -C "$LAB/r.s1" rev-parse --git-dir)/rebase-merge" ]; }
conflict
ship "$LAB/r.s1" SHIP_REVIEW=0
[ $rc = 0 ] && git -C "$LAB/r" show main:f.txt | grep -q "b s1" && git -C "$LAB/r" show main:f.txt | grep -q "b main" && ok "S7 conflict resolved by the agent: landed with both sides" || bad "S7 conflict resolved: exit $rc ($(tail -1 "$LAB/out"))"
conflict
ship "$LAB/r.s1" SHIP_REVIEW=0 STUB_CONFLICT='echo "OWNER DECISION NEEDED: b s1 vs b main"'
[ $rc = 3 ] && unmoved && open && ok "S7 OWNER DECISION NEEDED: exit 3, rebase left open" || bad "S7 owner decision: exit $rc"
conflict
ship "$LAB/r.s1" SHIP_REVIEW=0 STUB_CONFLICT='echo "gave up"'
[ $rc = 1 ] && unmoved && grep -q "rebase still open" "$LAB/out" && ok "S7 rebase left open without a verdict: exit 1" || bad "S7 left open: exit $rc"

# --- S8 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1" SHIP_REVIEW=0 MERGE_PREPARE=false
[ $rc = 1 ] && unmoved && grep -q "merge failed without a conflict" "$LAB/out" && [ "$(grep -c "ship: merge (round" "$LAB/out")" = 1 ] && ok "S8 merge failed without a conflict: exit 1 after one round" || bad "S8 merge failed without a conflict: exit $rc"
ship "$LAB/r.s1" SHIP_REVIEW=0 MERGE_PREPARE="touch $LAB/prepared"
[ $rc = 0 ] && [ -f "$LAB/prepared" ] && landed s1.txt && ok "S8 a MERGE_PREPARE that succeeds: run, then landed" || bad "S8 MERGE_PREPARE ok: exit $rc"

# --- S9 ----------------------------------------------------------------------------------------------
repo
ship "$LAB/r.s1" SHIP_AGENT=codex
[ $rc = 0 ] && landed s1.txt && grep -q "^codex exec" "$LAB/calls" && grep -q "for correctness" "$LAB/prompt" &&
  ok "S9 SHIP_AGENT=codex: codex reviews, landed" || bad "S9 codex: exit $rc"

exit $status
