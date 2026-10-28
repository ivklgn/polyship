#!/bin/sh
# Install polyship into the git repository you are in: copies merge.sh, ship.sh, lib.sh and lab/recover.sh into
# scripts/ (or the directory you name). Run it again to update; review the diff and commit it.
#
#   curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh -s -- tools/polyship
set -eu
dir=${1:-scripts}
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "polyship: run this inside a git repository" >&2; exit 1; }
command -v bash >/dev/null || { echo "polyship: bash is required" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "${POLYSHIP_REPO:-https://github.com/ivklgn/polyship}" "$tmp/polyship"   # POLYSHIP_REPO: a fork or a local checkout
mkdir -p "$root/$dir"
"$tmp/polyship/bin/vendor.sh" "$root/$dir" recover

command -v perl >/dev/null || echo "polyship: perl is missing; the merge lock needs it" >&2
command -v wt >/dev/null || echo "polyship: Worktrunk is missing: brew install worktrunk && wt config shell install" >&2
cat <<EOF

Next:
  1. Put your install and test commands in .config/wt.toml:
       [post-start]
       deps = "npm ci"
       [pre-merge]
       test = "npm test"
  2. wt config approvals add --yes
  3. Commit .config/wt.toml and $dir/
  4. In a worktree with a committed task: $dir/ship.sh
EOF
