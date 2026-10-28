#!/usr/bin/env bash
# Real agents, dependent tasks, at once. One run = a throwaway JS repository with bin/ship.sh vendored in, N real
# `claude -p` sessions (no MCP servers), each in its own worktree with one task of lab/swarm/tasks.tsv; the tasks
# depend on each other in the forms D1-D5 of measurements/2026-10-22/PLAN.md. Every session ends its task with
# scripts/ship.sh and acts on its exit code as the repository's CLAUDE.md says (the adopter instructions of the
# guide). The oracle is lab/swarm/acceptance.test.js, which no session sees: run on every first-parent commit of main.
#
#   lab/swarm.sh                      one run, all tasks, sessions start within START_WINDOW seconds
#   SUITE=12 START_WINDOW=60 TASKS="t01 t02" OUT=/tmp/swarm lab/swarm.sh
#   SHIP_AGENT_MODEL=sonnet           the --model of every claude call (default: the CLI's default)
#   SHIP_AGENT_EFFORT=medium          the --effort of every claude call (default: the CLI's default)
#   SWARM_AGENT=codex                the sessions and ship.sh's agent are `codex exec` (no sandbox: in workspace-write a
#                                     worktree's git dir is read-only, R22); SHIP_AGENT_MODEL and SHIP_AGENT_EFFORT: model, effort
#   SWARM_PUSH=1                     main is also on a bare remote; every merge goes through MERGE_PUSH=origin
#   SWARM_REVIEW=1                    ship.sh runs its review step (SHIP_REVIEW_HOW: plain words, no plugin); default 0
#   CLUSTERS=2                        a second copy of the fixture in src2/, locales/en2.json, test2/ with tasks t11-t20
#                                     (the same forms; no task depends on the other cluster): 20 sessions
# Writes $OUT/<run>/: sessions/<task>.json (claude's result), events.jsonl (ship/merge events), host.jsonl
# (claude RSS and CPU, load, every 2 s), timeline.jsonl (acceptance per main commit), result.json.
# ponytail: one fixture; real tasks of an adopter would need their own acceptance tests.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SUITE=${SUITE:-12}; START_WINDOW=${START_WINDOW:-60}; CAP=${CAP:-1800}
OUT=${OUT:-/tmp/swarm}; RUN=${RUN:-$(date +%Y%m%d-%H%M%S)}; D="$OUT/$RUN"; mkdir -p "$D/sessions"
CLUSTERS=${CLUSTERS:-1}
TASKFILE="$D/tasks.tsv"; cp "$HERE/lab/swarm/tasks.tsv" "$TASKFILE"
[ "$CLUSTERS" = 2 ] && perl -pe 's/^t0(\d)/t1$1/; s/^t10/t20/; s{src/}{src2/}g; s{test/}{test2/}g; s{locales/en\.json}{locales/en2.json}g' "$HERE/lab/swarm/tasks.tsv" >> "$TASKFILE"
TASKS=${TASKS:-$(cut -f1 "$TASKFILE" | tr '\n' ' ')}
unset MERGE_PREPARE MERGE_TARGET
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

LAB=$(mktemp -d /tmp/swarm-lab.XXXXXX); R="$LAB/repo"; echo "$LAB" > "$D/lab-path"
git init -q -b main "$R"; cd "$R" || exit 1
git config commit.gpgsign false; git config rerere.enabled false
mkdir -p src test locales scripts .config
cat > package.json <<'J'
{ "name": "swarm-fixture", "private": true, "type": "module", "scripts": { "test": "node --test" } }
J
cat > src/text.js <<'J'
export function titleCase(s) {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}
J
cat > src/users.js <<'J'
export function createUser(db, { name, email }) {
  const user = { id: db.users.length + 1, name, email };
  db.users.push(user);
  return user;
}

export function getUser(db, id) {
  return db.users.find((u) => u.id === id) ?? null;
}
J
cat > src/posts.js <<'J'
export function postPath(post) {
  return `/posts/${post.id}`;
}
J
cat > src/format.js <<'J'
export function formatPrice(cents) {
  return '$' + (cents / 100).toFixed(2);
}
J
cat > src/config.js <<'J'
export const defaults = { currency: 'USD', pageSize: 20 };
J
cat > src/report.js <<'J'
import { getUser } from './users.js';
import { formatPrice } from './format.js';

export function invoiceLine(db, userId, cents) {
  const user = getUser(db, userId);
  return `${user.name}: ${formatPrice(cents)}`;
}
J
cat > src/registry.js <<'J'
export const commands = [
  'list',
  'show',
];
J
cat > locales/en.json <<'J'
{
  "cmd.list": "List",
  "cmd.show": "Show"
}
J
cat > test/basic.test.js <<'J'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { titleCase } from '../src/text.js';
import { createUser, getUser } from '../src/users.js';
import { postPath } from '../src/posts.js';
import { formatPrice } from '../src/format.js';
import { invoiceLine } from '../src/report.js';
import { commands } from '../src/registry.js';

test('titleCase', () => assert.equal(titleCase('a b'), 'A B'));
test('users', () => { const db = { users: [] }; const u = createUser(db, { name: 'Ann', email: 'a@x.io' }); assert.equal(getUser(db, u.id).name, 'Ann'); });
test('postPath', () => assert.equal(postPath({ id: 3 }), '/posts/3'));
test('formatPrice', () => assert.equal(formatPrice(1234), '$12.34'));
test('invoiceLine', () => { const db = { users: [{ id: 1, name: 'Ann' }] }; assert.equal(invoiceLine(db, 1, 500), 'Ann: $5.00'); });
test('commands', () => assert.deepEqual(commands, ['list', 'show']));
J
cat > scripts/suite.sh <<J
#!/bin/sh
# the pre-merge suite: the tests, then a wait that makes it last about as long as hotpot2's (lab/suite-time.sh)
node --test && sleep $SUITE
J
chmod +x scripts/suite.sh
printf '[pre-merge]\ntest = "scripts/suite.sh"\n' > .config/wt.toml
BIN=${BIN:-$HERE/bin}; cp "$BIN/merge.sh" "$BIN/ship.sh" "$BIN/lib.sh" scripts/   # BIN=<dir>: another copy, for before/after
cat > CLAUDE.md <<'J'
# How work lands here

You work in your own git worktree, on your own branch, while other sessions change the same repository at the same
time. Nobody can answer questions: decide, or stop as described below.

- Do the task with a test (`node --test`). Change only what the task needs.
- Commit with the intent in the message (what and why).
- `scripts/ship.sh` runs for minutes. Run it in the foreground and wait for its exit code; do not end your turn while it
  runs, and never report SHIPPED without exit code 0.
- A task ends with `scripts/ship.sh`: it runs the tests, merges your branch into main under a lock, and calls an
  agent when the rebase stops on a conflict. Act on its exit code:
  - 0: the branch is on main. Done.
  - 1: red tests or no progress. Read the output, fix your branch, commit, run `scripts/ship.sh` again.
  - 2: not ready (for example uncommitted changes). Fix that, run it again.
  - 3: two incompatible product behaviors: the rebase is left open. Stop and report both options; do not choose.
  - 4: main moved while its agent ran (another session merged). Run `scripts/ship.sh` again.
  - 5: commits lost. Run the `git reset --hard` it names, then `scripts/ship.sh` again.
- Never push, never commit on main, never change main directly.
- Finish with one line: SHIPPED, STOPPED: <reason>, or GAVE UP: <reason>.
J
SWARM_AGENT=${SWARM_AGENT:-claude}; [ "$SWARM_AGENT" = codex ] && cp CLAUDE.md AGENTS.md   # Codex reads AGENTS.md
if [ "$CLUSTERS" = 2 ]; then
  cp -R src src2; cp locales/en.json locales/en2.json; mkdir -p test2; perl -pe 's{\.\./src/}{../src2/}g' test/basic.test.js > test2/basic.test.js
fi
git add -A && git commit -qm "init: fixture for lab/swarm.sh" && base=$(git rev-parse HEAD)
if [ "${SWARM_PUSH:-0}" = 1 ]; then git init -q --bare "$LAB/origin.git"; git remote add origin "$LAB/origin.git"; git push -q origin main; export MERGE_PUSH=origin; fi
wt config approvals add --yes >/dev/null 2>&1 || true

mkdir -p "$LAB/bin"
if [ "$SWARM_AGENT" = codex ]; then real=$(command -v codex)
  cat > "$LAB/bin/codex" <<J
#!/usr/bin/env bash
exec "$real" ${SHIP_AGENT_MODEL:+-c model=\"$SHIP_AGENT_MODEL\"} ${SHIP_AGENT_EFFORT:+-c model_reasoning_effort=\"$SHIP_AGENT_EFFORT\"} "\$@"
J
else real=$(command -v claude)
  cat > "$LAB/bin/claude" <<J
#!/usr/bin/env bash
exec "$real" --strict-mcp-config --mcp-config '{"mcpServers":{}}' ${SHIP_AGENT_MODEL:+--model $SHIP_AGENT_MODEL} ${SHIP_AGENT_EFFORT:+--effort $SHIP_AGENT_EFFORT} "\$@"
J
fi
chmod +x "$LAB/bin/$SWARM_AGENT"
export PATH="$LAB/bin:$PATH" MERGE_EVENTS="$D/events.jsonl" SHIP_REVIEW=${SWARM_REVIEW:-0} SHIP_AGENT=$SWARM_AGENT
export SHIP_REVIEW_HOW="for correctness, the task in the commit messages, and tests that guard it"

# host sampler: every claude process (sessions and the agents ship.sh calls), and the load
( while :; do
    ps -axo rss=,%cpu=,comm= | awk -v t="$(now)" -v la="$(sysctl -n vm.loadavg | awk '{print $2}')" \
      '$3 ~ /(claude|codex)$/ {n++; r+=$1; c+=$2} END {printf "{\"t\":%s,\"claude\":%d,\"rss_mb\":%.0f,\"cpu\":%.0f,\"load1\":%s}\n", t, n, r/1024, c, la}' >> "$D/host.jsonl"
    sleep 2
  done ) >/dev/null 2>&1 & sampler=$!

t0=$(now); pids=()
for t in $TASKS; do
  wt -C "$R" switch --create "$t" --yes --no-cd >/dev/null 2>&1
  p=$(git -C "$R" worktree list --porcelain | awk -v b="refs/heads/$t" '/^worktree /{w=$2} $0=="branch "b{print w}')
  task=$(awk -F'\t' -v t="$t" '$1==t{print $3}' "$TASKFILE")
  delay=$(perl -e "printf '%.1f', rand($START_WINDOW)")
  ( sleep "$delay"; s=$(now)
    printf '{"t":%s,"task":"%s","ev":"session-start"}\n' "$s" "$t" >> "$D/events.jsonl"
    if [ "$SWARM_AGENT" = codex ]; then
      (cd "$p" && printf '%s\n' "$task" | codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -o "$D/sessions/$t.txt" -) > "$D/sessions/$t.log" 2> "$D/sessions/$t.err"; cr=$?
      python3 -c 'import json,sys; print(json.dumps({"result": open(sys.argv[1]).read() if __import__("os").path.exists(sys.argv[1]) else ""}))' "$D/sessions/$t.txt" > "$D/sessions/$t.json"; (exit $cr)
    else
      (cd "$p" && printf '%s\n' "$task" | claude -p --permission-mode bypassPermissions --output-format json) > "$D/sessions/$t.json" 2> "$D/sessions/$t.err"
    fi
    printf '{"t":%s,"task":"%s","ev":"session-end","rc":%s,"secs":%s}\n' "$(now)" "$t" "$?" "$(perl -e "printf '%.1f', $(now)-$s")" >> "$D/events.jsonl"
  ) & pids+=($!)
done
( sleep "$CAP"; for x in "${pids[@]}"; do kill -0 "$x" 2>/dev/null && { echo "$x" >> "$D/capped"; pkill -9 -P "$x"; }; done ) >/dev/null 2>&1 & guard=$!
wait "${pids[@]}" 2>/dev/null; pkill -P "$guard" 2>/dev/null; pkill -P "$sampler" 2>/dev/null; kill "$guard" "$sampler" 2>/dev/null; wall=$(perl -e "printf '%.0f', $(now)-$t0")

# the oracle: the hidden acceptance tests and the visible suite on every first-parent commit of main
CLUSTERS=$CLUSTERS "$HERE/lab/swarm/eval.sh" "$D" "$wall"
