#!/usr/bin/env bash
# Checks of the release flow and bin/polyship (.archcore/architecture/polyship-release.spec.md,
# .archcore/architecture/polyship-cli.spec.md) in a throwaway HOME. The releases are built by .github/scripts/package.sh
# from a copy of this checkout whose ship.sh and merge.sh are stubs that print their directory, env and arguments.
#
#   P1  package.sh: a bad tag refused; polyship.tar.gz with bin/, lab/recover.sh, VERSION; checksums.txt matches
#   P2  install.sh from a local release: the command in ~/.local/bin, the version directory, the PATH hint
#   P3  install.sh refuses a checksum mismatch and leaves the installed command as it was
#   P4  a second release switches the command; the old version directory stays; the run uses the real directory
#   P5  settings: -o reaches the scripts; a variable left in the caller's shell does not
#   P6  refusals, exit 2: unknown key, no '=', bad on/off, bad number, unknown command, extra argument, no worktree
#   P7  config: every key with value and source; on/off shown as given
#   P8  merge forwards wt flags; -C runs in that directory; check runs lab/recover.sh with BIN of the version
#
#   lab/polyship-checks.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(cd "$(mktemp -d /tmp/wt-polyship.XXXXXX)" && pwd -P); trap 'rm -rf "$LAB"' EXIT
status=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; status=1; }
export HOME="$LAB/home" GIT_CONFIG_NOSYSTEM=1; unset XDG_DATA_HOME POLYSHIP_VERSION POLYSHIP_INSTALL_DIR; mkdir -p "$HOME"
git config --global user.email lab@example.com; git config --global user.name lab
data="$HOME/.local/share/polyship"; P="$HOME/.local/bin/polyship"

# a source tree: the real launcher and packaging, stub scripts
S="$LAB/src"; mkdir -p "$S/bin" "$S/lab" "$S/.github/scripts"
cp "$HERE/bin/polyship" "$HERE/bin/lib.sh" "$S/bin/"; cp "$HERE/.github/scripts/package.sh" "$S/.github/scripts/"
cp "$HERE/README.md" "$HERE/LICENSE" "$S/"
for s in ship merge; do
  printf '#!/usr/bin/env bash\necho "dir=$(cd "$(dirname "$0")" && pwd)"\necho "pwd=$PWD"\nenv | grep -E "^(MERGE|SHIP)_" | sort\necho "args=$*"\n' > "$S/bin/$s.sh"
  chmod +x "$S/bin/$s.sh"
done
printf '#!/usr/bin/env bash\necho "PASS stub BIN=$BIN"\n' > "$S/lab/recover.sh"; chmod +x "$S/lab/recover.sh"
pkg() { "$S/.github/scripts/package.sh" "$1" "$LAB/rel/$1" > /dev/null 2>&1; }
inst() { (cd "$LAB" && PATH="/usr/bin:/bin:$(dirname "$(command -v git)")" POLYSHIP_BASE_URL="file://$LAB/rel/$1" sh "$HERE/install.sh") > "$LAB/inst.log" 2>&1; }

# --- P1 ----------------------------------------------------------------------------------------------
rc=0; pkg 0.2 || rc=$?; [ $rc != 0 ] && [ ! -e "$LAB/rel/0.2/polyship.tar.gz" ] && ok "P1 a bad tag is refused" || bad "P1 bad tag: exit $rc"
rc=0; pkg v0.2.0 || rc=$?
list=$(tar -tzf "$LAB/rel/v0.2.0/polyship.tar.gz" 2>/dev/null | sed 's#^\./##' | grep -v -e '/$' -e '^$' | LC_ALL=C sort | tr '\n' ' ')
sum=$(cd "$LAB/rel/v0.2.0" && shasum -a 256 -c checksums.txt 2>&1)
[ $rc = 0 ] && [ "$list" = "LICENSE README.md VERSION bin/lib.sh bin/merge.sh bin/polyship bin/ship.sh lab/recover.sh " ] && [ "$sum" = "polyship.tar.gz: OK" ] &&
  ok "P1 v0.2.0: the archive holds bin/, lab/recover.sh, VERSION; checksums.txt matches" || bad "P1 package: exit $rc, files: $list, sum: $sum"

# --- P2 ----------------------------------------------------------------------------------------------
rc=0; inst v0.2.0 || rc=$?
[ $rc = 0 ] && [ -L "$P" ] && [ "$("$P" --version)" = "polyship 0.2.0" ] && [ -f "$data/0.2.0/lab/recover.sh" ] &&
  ok "P2 install.sh: polyship 0.2.0 in ~/.local/bin, $data/0.2.0" || bad "P2 install: exit $rc ($(tail -2 "$LAB/inst.log" | tr '\n' ' '))"
grep -q 'Add .*/.local/bin to PATH' "$LAB/inst.log" && ok "P2 install.sh names the PATH line" || bad "P2 no PATH hint"

# --- P3 ----------------------------------------------------------------------------------------------
pkg v0.3.0; cp -R "$LAB/rel/v0.3.0" "$LAB/rel/broken"; echo junk >> "$LAB/rel/broken/polyship.tar.gz"
rc=0; inst broken || rc=$?
[ $rc = 1 ] && grep -q 'checksum mismatch' "$LAB/inst.log" && [ "$("$P" --version)" = "polyship 0.2.0" ] && [ ! -d "$data/0.3.0" ] &&
  ok "P3 a checksum mismatch: exit 1, polyship 0.2.0 kept" || bad "P3 mismatch: exit $rc, $("$P" --version)"

# --- P4 ----------------------------------------------------------------------------------------------
rc=0; inst v0.3.0 || rc=$?
[ $rc = 0 ] && [ "$("$P" --version)" = "polyship 0.3.0" ] && [ -d "$data/0.2.0" ] && ok "P4 v0.3.0 installed, 0.2.0 kept" || bad "P4 update: exit $rc, $("$P" --version)"
A="$LAB/adopter"; git init -q -b main "$A"; mkdir "$A/sub"
out=$(cd "$A/sub" && "$P" ship 2>&1)
printf '%s\n' "$out" | grep -qx "dir=$data/0.3.0/bin" && ok "P4 ship.sh runs from $data/0.3.0/bin" || bad "P4 run dir: $(printf '%s' "$out" | head -1)"
rc=0; inst v0.2.0 || rc=$?; [ $rc = 0 ] && [ "$("$P" --version)" = "polyship 0.2.0" ] && ok "P4 installing v0.2.0 again goes back to it" || bad "P4 back: exit $rc"
inst v0.3.0

# --- P5 ----------------------------------------------------------------------------------------------
out=$(cd "$A" && MERGE_PUSH=evil SHIP_REVIEW=0 "$P" ship -o push=origin -o review_how='with /x y' -o rounds=4 2>&1)
printf '%s\n' "$out" | grep -qx MERGE_PUSH=origin && printf '%s\n' "$out" | grep -qx 'SHIP_REVIEW_HOW=with /x y' && printf '%s\n' "$out" | grep -qx SHIP_ROUNDS=4 &&
  ok "P5 -o push, review_how, rounds reach ship.sh" || bad "P5 flags: $out"
out=$(cd "$A" && MERGE_PUSH=evil SHIP_REVIEW=0 MERGE_PREPARE='touch x' "$P" ship 2>&1)
! printf '%s\n' "$out" | grep -q '^MERGE_PUSH=\|^SHIP_REVIEW=\|^MERGE_PREPARE=' && ok "P5 the caller's MERGE_PUSH, SHIP_REVIEW, MERGE_PREPARE do not reach ship.sh" || bad "P5 env leak: $out"
out=$(cd "$A" && "$P" ship -o review=off 2>&1); printf '%s\n' "$out" | grep -qx SHIP_REVIEW=0 && ok "P5 review=off: SHIP_REVIEW=0" || bad "P5 review: $out"

# --- P6 ----------------------------------------------------------------------------------------------
p6=ok
for a in "ship -o bogus=1" "ship -o push" "ship -o review=maybe" "ship -o rounds=0" "ship -o agent=gpt" "frobnicate" "ship extra" "ship -C $LAB/missing"; do
  rc=0; (cd "$A" && "$P" $a) >/dev/null 2>&1 || rc=$?; [ $rc = 2 ] || p6="$a: exit $rc"
done
mkdir "$LAB/plain"; rc=0; (cd "$LAB/plain" && "$P" ship) >/dev/null 2>&1 || rc=$?; [ $rc = 2 ] || p6="outside a worktree: exit $rc"
[ "$p6" = ok ] && ok "P6 refusals exit 2: unknown key, no '=', bad on/off, number, agent, command, argument, -C, no worktree" || bad "P6 $p6"

# --- P7 ----------------------------------------------------------------------------------------------
out=$("$P" config -o review=off -o push=origin)
[ "$(printf '%s\n' "$out" | grep -c '^CONFIG')" = 9 ] && printf '%s\n' "$out" | grep -qxF "$(printf 'CONFIG\treview\toff\tflag')" &&
  printf '%s\n' "$out" | grep -qxF "$(printf 'CONFIG\tpush\torigin\tflag')" && printf '%s\n' "$out" | grep -qxF "$(printf 'CONFIG\trounds\t\tdefault')" &&
  ok "P7 config: 9 keys, flag and default sources, review shown as off" || bad "P7 config: $out"

# --- P8 ----------------------------------------------------------------------------------------------
out=$(cd "$A" && "$P" merge -o push=origin --no-squash 2>&1)
printf '%s\n' "$out" | grep -qx 'args=--no-squash' && printf '%s\n' "$out" | grep -qx MERGE_PUSH=origin && ok "P8 merge: -o read, --no-squash forwarded" || bad "P8 merge: $out"
out=$("$P" ship -C "$A/sub" 2>&1); printf '%s\n' "$out" | grep -qx "pwd=$A/sub" && ok "P8 -C runs in that directory" || bad "P8 -C: $out"
out=$("$P" check 2>&1); [ "$out" = "PASS stub BIN=$data/0.3.0/bin" ] && ok "P8 check: recover.sh with BIN of the version" || bad "P8 check: $out"

exit $status
