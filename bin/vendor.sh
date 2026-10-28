#!/usr/bin/env bash
# Copy merge.sh, ship.sh and lib.sh into another repository, each with a header naming this repository and
# commit, so the copy says where to change it. Run again to update a copy; review the diff there and commit it
# with the intent of the update.
#
#   bin/vendor.sh <dir>            e.g. bin/vendor.sh ../myapp/scripts
#   bin/vendor.sh <dir> recover    also lab/recover.sh into <dir>/lab/, pointed at <dir> (BIN defaults to it)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?usage: bin/vendor.sh <dir> [recover]}
[ -d "$dest" ] || { echo "vendor: no directory $dest" >&2; exit 2; }
dest=$(cd "$dest" && pwd)
[ -z "$(git -C "$here" status --porcelain bin lab)" ] || { echo "vendor: uncommitted changes in bin/ or lab/ here; commit them first, the header names a commit" >&2; exit 2; }
sha=$(git -C "$here" rev-parse --short HEAD)
# the public URL; a clone without a remote names its main checkout, not a worktree
repo=$(git -C "$here" remote get-url origin 2>/dev/null) || repo=$(cd "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
for f in merge ship lib; do
  src="$here/bin/$f.sh"
  { head -1 "$src" | grep '^#!' || true
    echo "# Vendored from polyship ($repo, $sha, bin/$f.sh); change it there and copy back. Measurements: its measurements/REPORT.md."
    if head -1 "$src" | grep -q '^#!'; then tail -n +2 "$src"; else cat "$src"; fi
  } > "$dest/$f.sh"
done
chmod +x "$dest/merge.sh" "$dest/ship.sh"
if [ "${2:-}" = recover ]; then
  mkdir -p "$dest/lab"
  # BIN: the directory above this lab/, wherever the repository is checked out
  sed -e 's#^HERE=$(cd "$(dirname "$0")/.." \&\& pwd); BIN=${BIN:-$HERE/bin}#HERE=$(cd "$(dirname "$0")/.." \&\& pwd); BIN=${BIN:-$HERE}#' \
      -e "s#run against bin/ of a checkout#run against the scripts one directory up (vendored from polyship $sha lab/recover.sh)#" \
      -e "s#against bin/ of this checkout#against the scripts one directory up#" \
      "$here/lab/recover.sh" > "$dest/lab/recover.sh"
  grep -q 'BIN=${BIN:-$HERE}$' "$dest/lab/recover.sh" || { echo "vendor: lab/recover.sh changed its BIN line; update bin/vendor.sh" >&2; exit 1; }
  chmod +x "$dest/lab/recover.sh"
fi
echo "vendor: polyship $sha → $dest"
