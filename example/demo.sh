#!/usr/bin/env bash
# Three sessions finish their tasks at the same moment; polyship lands them one at a time, each tested on top of
# the one before. The sessions are scripted and the review step is off, so no agent and no API key is needed.
# Everything happens in a new directory under /tmp. Needs wt (Worktrunk), git and perl.
#
#   example/demo.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
demo=$(mktemp -d /tmp/polyship-demo.XXXXXX)
git init -q -b main "$demo/app"; cd "$demo/app"

# The project: its test command is the merge gate. Here a 2-second "suite" that fails on a TODO.
mkdir -p .config scripts
cat > .config/wt.toml <<'EOF'
[pre-merge]
test = "sleep 2 && ! grep -rq TODO --include='*.txt' ."
EOF
echo "# app" > README.md
"$here/bin/vendor.sh" "$PWD/scripts" >/dev/null
git add -A; git commit -qm "chore: the app, with polyship in scripts/"

# Three sessions, each in its own worktree, each with one committed task.
for task in greet bye help; do
  wt switch --create "$task" --no-cd >/dev/null 2>&1
  wt_dir=$(git worktree list --porcelain | awk -v b="branch refs/heads/$task" '/^worktree /{w=substr($0,10)} $0==b{print w}')
  echo "$task" > "$wt_dir/$task.txt"
  git -C "$wt_dir" add -A; git -C "$wt_dir" commit -qm "feat: $task command"
done

# All three ship at once; the lock lets one merge in at a time.
echo "== three sessions run scripts/ship.sh at the same time"
for task in greet bye help; do
  wt_dir=$(git worktree list --porcelain | awk -v b="branch refs/heads/$task" '/^worktree /{w=substr($0,10)} $0==b{print w}')
  (cd "$wt_dir" && SHIP_REVIEW=0 scripts/ship.sh 2>&1 | grep '^ship:' | sed "s/^/[$task] /"; echo "[$task] exit ${PIPESTATUS[0]}") &
done
wait

echo; echo "== main: one merge commit per task, each one a tested tree"
git log --graph --format='%s' main
echo; echo "(the demo repository: $demo/app)"
