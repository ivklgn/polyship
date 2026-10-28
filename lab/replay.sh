#!/usr/bin/env bash
# Replay a real, human-resolved conflict through bin/ship.sh with a real agent, and compare the agent's
# result with the human's. The source is a back-merge commit BM (parents: branch tip P1, mainline P2)
# whose two parents conflict. The lab is a local clone with no remote: main = P2, branch = P1; ship.sh
# rebases the branch onto main, calls the agent on every conflict, fast-forwards. The oracle is the
# human's tree: `git diff BM main` after the run. Read-only for the source repository.
#
#   lab/replay.sh <repo> <bm-sha> [<out-dir>]
#   SHIP_AGENT=codex lab/replay.sh …      the agent ship.sh calls (default claude)
#
# Prints one JSON line: case, commits replayed, conflicted files, ship exit code, agent rounds, seconds,
# and the diff against the human resolution — on the conflicted files and on the whole tree.
# The claude wrapper runs with no MCP servers, so the agent cannot reach a tracker or a review system.
set -uo pipefail
SRC=$1; BM=$(git -C "$1" rev-parse "$2"); OUTD=${3:-/tmp/wt-replay}
HERE=$(cd "$(dirname "$0")/.." && pwd)
P1=$(git -C "$SRC" rev-parse "$BM^1"); P2=$(git -C "$SRC" rev-parse "$BM^2")
L="$OUTD/${BM:0:10}"; rm -rf "$L"; mkdir -p "$L/bin"
git clone -q --shared --no-checkout "$SRC" "$L/repo"; cd "$L/repo" || exit 1
git remote remove origin
git config merge.conflictStyle merge; git config rerere.enabled false; git config commit.gpgsign false
git checkout -q -B main "$P2"
git worktree add -q -b mr "$L/mr" "$P1"
files=$(git merge-tree --write-tree --name-only "$P1" "$P2" | sed -n '2,/^$/p' | grep -v '^$')
commits=$(git rev-list --count "$(git merge-base "$P1" "$P2")..$P1")
real=$(command -v claude)
cat > "$L/bin/claude" <<EOF
#!/usr/bin/env bash
exec "$real" --strict-mcp-config --mcp-config '{"mcpServers":{}}' "\$@"
EOF
chmod +x "$L/bin/claude"
t0=$(date +%s)
(cd "$L/mr" && PATH="$L/bin:$PATH" SHIP_REVIEW=0 SHIP_TEST=true MERGE_EVENTS="$L/events.jsonl" "$HERE/bin/ship.sh") > "$L/ship.log" 2>&1
rc=$?
secs=$(( $(date +%s) - t0 ))
rounds=$(grep -c '"ev":"ship-conflict"' "$L/events.jsonl" 2>/dev/null || echo 0)
landed=false; git merge-base --is-ancestor mr main && landed=true
# the human's tree vs the agent's: conflicted files, then the whole tree
diff_files=$(git diff --numstat "$BM" main -- $files | awk '{a+=$1; d+=$2} END{print a+0 "+" d+0 "-"}')
diff_all=$(git diff --shortstat "$BM" main | sed 's/^ //')
same=$(git diff --quiet "$BM" main -- $files && echo true || echo false)
printf '{"case":"%s","commits":%s,"conflicted":%s,"files":"%s","ship_rc":%s,"landed":%s,"agent_rounds":%s,"secs":%s,"same_as_human_on_conflicted":%s,"diff_conflicted":"%s","diff_tree":"%s"}\n' \
  "${BM:0:10}" "$commits" "$(echo "$files" | grep -c .)" "$(echo $files)" "$rc" "$landed" "$rounds" "$secs" "$same" "$diff_files" "$diff_all"
