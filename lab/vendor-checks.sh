#!/usr/bin/env bash
# Checks of bin/vendor.sh on a committed copy of this checkout's bin/ and lab/ (the script refuses a dirty tree).
#
#   V1  refusals: no destination directory, uncommitted changes in bin/ or lab/: exit 2, nothing written
#   V2  the copy: merge.sh, ship.sh, lib.sh with the shebang first, then a header naming the source commit, then the
#       source unchanged; merge.sh and ship.sh executable
#   V3  `recover`: lab/recover.sh copied with BIN pointed one directory up, and it passes against the copy
#   V4  install.sh in a fresh repository, from a local clone (POLYSHIP_REPO): the scripts land in the directory it names
#
#   lab/vendor-checks.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(mktemp -d /tmp/wt-vendor.XXXXXX); trap 'rm -rf "$LAB"' EXIT
status=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; status=1; }

S="$LAB/src"; git init -q -b main "$S"; cp -R "$HERE/bin" "$HERE/lab" "$S/"
git -C "$S" add -A; git -C "$S" commit -qm src; sha=$(git -C "$S" rev-parse --short HEAD)
D="$LAB/dest"; mkdir "$D"

# --- V1 ----------------------------------------------------------------------------------------------
rc=0; "$S/bin/vendor.sh" "$LAB/missing" >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && ok "V1 no destination: exit 2" || bad "V1 no destination: exit $rc"
echo "# dirty" >> "$S/bin/merge.sh"
rc=0; "$S/bin/vendor.sh" "$D" >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && [ -z "$(ls -A "$D")" ] && ok "V1 dirty bin/: exit 2, nothing written" || bad "V1 dirty bin/: exit $rc, written: $(ls "$D")"
git -C "$S" checkout -q -- bin/merge.sh

# --- V2 ----------------------------------------------------------------------------------------------
rc=0; "$S/bin/vendor.sh" "$D" >/dev/null 2>&1 || rc=$?
v2=ok
for f in merge ship lib; do
  src="$S/bin/$f.sh"; out="$D/$f.sh"
  if head -1 "$src" | grep -q '^#!'; then
    [ "$(head -1 "$out")" = "$(head -1 "$src")" ] && sed -n 2p "$out" | grep -qF "$sha, bin/$f.sh" &&
      diff -q <(tail -n +3 "$out") <(tail -n +2 "$src") >/dev/null || v2="$f.sh"
  else
    head -1 "$out" | grep -qF "$sha, bin/$f.sh" && diff -q <(tail -n +2 "$out") "$src" >/dev/null || v2="$f.sh"
  fi
done
[ $rc = 0 ] && [ $v2 = ok ] && [ -x "$D/merge.sh" ] && [ -x "$D/ship.sh" ] && ok "V2 three files: shebang, header with $sha, source unchanged" || bad "V2 copy: exit $rc, wrong: $v2"

# --- V3 ----------------------------------------------------------------------------------------------
rc=0; "$S/bin/vendor.sh" "$D" recover >/dev/null 2>&1 || rc=$?
[ $rc = 0 ] && grep -q 'BIN=${BIN:-$HERE}$' "$D/lab/recover.sh" && [ -x "$D/lab/recover.sh" ] && ok "V3 recover.sh copied, BIN one directory up" || bad "V3 recover copy: exit $rc"
rc=0; "$D/lab/recover.sh" > "$LAB/v3.log" 2>&1 || rc=$?
[ $rc = 0 ] && ok "V3 the vendored recover.sh passes against the vendored scripts" || bad "V3 vendored recover.sh: exit $rc ($(grep -m1 FAIL "$LAB/v3.log"))"

# --- V4 ----------------------------------------------------------------------------------------------
A="$LAB/adopter"; git init -q -b main "$A"
rc=0; (cd "$A" && POLYSHIP_REPO="$S" sh "$HERE/install.sh" tools/ps) > "$LAB/v4.log" 2>&1 || rc=$?
[ $rc = 0 ] && [ -x "$A/tools/ps/ship.sh" ] && [ -x "$A/tools/ps/lab/recover.sh" ] && sed -n 2p "$A/tools/ps/ship.sh" | grep -qF "$sha, bin/ship.sh" &&
  ok "V4 install.sh: the scripts in the named directory, header with $sha" || bad "V4 install.sh: exit $rc ($(tail -1 "$LAB/v4.log"))"

exit $status
