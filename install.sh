#!/bin/sh
# Install polyship once per machine: the newest v* tag into ${XDG_DATA_HOME:-~/.local/share}/polyship/<tag>/ and
# the command ~/.local/bin/polyship. Nothing is written into a repository. Update later with: polyship self-update
#
#   curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh
#   POLYSHIP_REPO=<fork or local checkout> sh install.sh
set -eu
for c in git bash perl; do command -v $c >/dev/null || { echo "polyship: $c is required" >&2; exit 1; }; done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "${POLYSHIP_REPO:-https://github.com/ivklgn/polyship}" "$tmp/polyship"
"$tmp/polyship/bin/polyship" self-update

command -v wt >/dev/null || echo "polyship: Worktrunk is missing: brew install worktrunk && wt config shell install" >&2
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "polyship: add ~/.local/bin to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2 ;; esac
cat <<'EOF'

Next, in each repository (INSTALL.md):
  1. .config/wt.toml: the [post-start] install and [pre-merge] test commands; wt config approvals add --yes
  2. .config/polyship.conf, if the defaults do not fit:  [polyship] push = origin
  3. CLAUDE.md or AGENTS.md: a task ends with `polyship ship`
EOF
