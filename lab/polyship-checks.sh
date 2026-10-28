#!/usr/bin/env bash
# Checks of bin/polyship and install.sh (.archcore/architecture/polyship-cli.spec.md) in a throwaway HOME, against a
# local release repository whose ship.sh and merge.sh are stubs that print their directory and the settings env.
#
#   P1  install.sh: the newest tag by number (v0.10.0 over v0.2.0), the command in ~/.local/bin, nothing else needed
#   P2  the run uses the real version directory, not the current link
#   P3  layers: .config/polyship.conf, then git config over it, then env over both, an empty env value included
#   P4  the committed file cannot set a command: prepare/test ignored with a warning; git config can set them
#   P5  review = false becomes SHIP_REVIEW=0
#   P6  minVersion: above the tag exit 2 with the hint; not MAJOR.MINOR.PATCH exit 2; a dev checkout skips it
#   P7  refusals: unknown subcommand, outside a git worktree: exit 2
#   P8  self-update <tag> switches; an unknown tag exits 1 and keeps current; a leftover .tmp.* is no version
#
#   lab/polyship-checks.sh
set -uo pipefail
unset MERGE_TARGET MERGE_PUSH MERGE_PREPARE MERGE_STALE_INDEX_LOCK SHIP_REVIEW SHIP_REVIEW_HOW SHIP_ROUNDS SHIP_AGENT SHIP_TEST XDG_DATA_HOME
HERE=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(cd "$(mktemp -d /tmp/wt-polyship.XXXXXX)" && pwd -P); trap 'rm -rf "$LAB"' EXIT
status=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; status=1; }
export HOME="$LAB/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
git config --global user.email lab@example.com; git config --global user.name lab
data="$HOME/.local/share/polyship"

# release repository: the real launcher, stub scripts, three tags
R="$LAB/release"; git init -q -b main "$R"; mkdir -p "$R/bin" "$R/lab"
cp "$HERE/bin/polyship" "$R/bin/"
for s in ship merge; do
  printf '#!/usr/bin/env bash\necho "dir=$(cd "$(dirname "$0")" && pwd)"\nenv | grep -E "^(MERGE|SHIP)_" | sort\necho "args=$*"\n' > "$R/bin/$s.sh"
  chmod +x "$R/bin/$s.sh"
done
printf '#!/usr/bin/env bash\necho "PASS stub BIN=$BIN"\n' > "$R/lab/recover.sh"; chmod +x "$R/lab/recover.sh"
git -C "$R" add -A; git -C "$R" commit -qm r
for t in v0.2.0 v0.10.0; do git -C "$R" tag "$t"; done
git -C "$R" commit -q --allow-empty -m later; git -C "$R" tag v0.3.0
export POLYSHIP_REPO="$R"
P="$HOME/.local/bin/polyship"

# --- P1 ----------------------------------------------------------------------------------------------
rc=0; (cd "$LAB" && PATH="/usr/bin:/bin:$(dirname "$(command -v git)")" sh "$HERE/install.sh") > "$LAB/p1.log" 2>&1 || rc=$?
[ $rc = 0 ] && [ -L "$P" ] && [ "$("$P" version)" = v0.10.0 ] && [ -f "$data/v0.10.0/lab/recover.sh" ] &&
  ok "P1 install.sh: v0.10.0 current, polyship in ~/.local/bin" || bad "P1 install.sh: exit $rc, version $("$P" version 2>&1) ($(tail -2 "$LAB/p1.log" | tr '\n' ' '))"
grep -q 'add ~/.local/bin to PATH' "$LAB/p1.log" && ok "P1 install.sh names the PATH line" || bad "P1 no PATH hint"

# adopter repository
A="$LAB/adopter"; git init -q -b main "$A"; mkdir "$A/.config" "$A/sub"
run() { (cd "$A/sub" && "$P" "$@") 2>"$LAB/err"; }

# --- P2 ----------------------------------------------------------------------------------------------
out=$(run ship)
printf '%s\n' "$out" | grep -qx "dir=$data/v0.10.0/bin" && ok "P2 ship.sh runs from $data/v0.10.0/bin" || bad "P2 ship.sh dir: $(printf '%s' "$out" | head -1)"
out=$(run merge --no-squash); printf '%s\n' "$out" | grep -qx 'args=--no-squash' && ok "P2 merge flags reach merge.sh" || bad "P2 merge args: $out"

# --- P3 ----------------------------------------------------------------------------------------------
printf '[polyship]\n\tpush = origin\n\treviewHow = from-file\n\trounds = 4\n' > "$A/.config/polyship.conf"
out=$(run ship)
printf '%s\n' "$out" | grep -qx MERGE_PUSH=origin && printf '%s\n' "$out" | grep -qx SHIP_REVIEW_HOW=from-file && printf '%s\n' "$out" | grep -qx SHIP_ROUNDS=4 &&
  ok "P3 the committed file sets push, reviewHow, rounds" || bad "P3 file layer: $out"
git -C "$A" config polyship.push upstream
out=$(run ship); printf '%s\n' "$out" | grep -qx MERGE_PUSH=upstream && ok "P3 git config wins over the file" || bad "P3 git config layer: $out"
out=$(cd "$A" && MERGE_PUSH= "$P" ship 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'MERGE_PUSH=' && ok "P3 MERGE_PUSH= (empty) wins over both" || bad "P3 empty env: $out"
git -C "$A" config --unset polyship.push

# --- P4 ----------------------------------------------------------------------------------------------
printf '\tprepare = touch %s/pwned\n\ttest = false\n' "$LAB" >> "$A/.config/polyship.conf"
out=$(run ship)
! printf '%s\n' "$out" | grep -q '^MERGE_PREPARE=\|^SHIP_TEST=' && grep -q 'polyship.prepare is a command' "$LAB/err" && grep -q 'polyship.test is a command' "$LAB/err" &&
  ok "P4 prepare and test in the committed file: ignored, warned" || bad "P4 command keys: $out / $(cat "$LAB/err")"
git -C "$A" config polyship.prepare 'true'
out=$(run ship); printf '%s\n' "$out" | grep -qx MERGE_PREPARE=true && ok "P4 git config sets prepare" || bad "P4 git config prepare: $out"
git -C "$A" config --unset polyship.prepare

# --- P5 ----------------------------------------------------------------------------------------------
printf '\treview = false\n' >> "$A/.config/polyship.conf"
out=$(run ship); printf '%s\n' "$out" | grep -qx SHIP_REVIEW=0 && ok "P5 review = false: SHIP_REVIEW=0" || bad "P5 review: $out"

# --- P6 ----------------------------------------------------------------------------------------------
printf '\tminVersion = 0.10.0\n' >> "$A/.config/polyship.conf"
rc=0; run ship >/dev/null || rc=$?; [ $rc = 0 ] && ok "P6 minVersion 0.10.0 on v0.10.0 runs" || bad "P6 equal minVersion: exit $rc"
git -C "$A" config polyship.minVersion v1.0.0
rc=0; run ship >/dev/null || rc=$?
[ $rc = 2 ] && grep -q 'polyship v1.0.0 is required, v0.10.0 is installed; run polyship self-update' "$LAB/err" &&
  ok "P6 minVersion above the tag: exit 2 with the hint" || bad "P6 minVersion: exit $rc ($(cat "$LAB/err"))"
git -C "$A" config polyship.minVersion banana
rc=0; run ship >/dev/null || rc=$?; [ $rc = 2 ] && grep -q "'banana'" "$LAB/err" && ok "P6 minVersion banana: exit 2" || bad "P6 bad minVersion: exit $rc"
git -C "$A" config polyship.minVersion 9.0.0
rc=0; (cd "$A" && "$R/bin/polyship" ship) >/dev/null 2>&1 || rc=$?; [ $rc = 0 ] && ok "P6 a dev checkout skips minVersion" || bad "P6 dev: exit $rc"
git -C "$A" config --unset polyship.minVersion

# --- P7 ----------------------------------------------------------------------------------------------
rc=0; "$P" frobnicate >/dev/null 2>&1 || rc=$?; [ $rc = 2 ] && ok "P7 unknown subcommand: exit 2" || bad "P7 unknown: exit $rc"
mkdir "$LAB/plain"; rc=0; (cd "$LAB/plain" && "$P" ship) >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && ok "P7 outside a git worktree: exit 2" || bad "P7 outside: exit $rc"

# --- P8 ----------------------------------------------------------------------------------------------
mkdir "$data/.tmp.left"
rc=0; "$P" self-update v0.2.0 >/dev/null 2>&1 || rc=$?
[ $rc = 0 ] && [ "$("$P" version)" = v0.2.0 ] && [ "$(readlink "$data/current")" = v0.2.0 ] && ok "P8 self-update v0.2.0 switches current" || bad "P8 switch: exit $rc, $("$P" version)"
rc=0; "$P" self-update v9.9.9 >/dev/null 2>&1 || rc=$?
[ $rc = 1 ] && [ "$(readlink "$data/current")" = v0.2.0 ] && ok "P8 unknown tag: exit 1, current kept" || bad "P8 unknown tag: exit $rc"
rc=0; "$P" self-update >/dev/null 2>&1 || rc=$?
[ $rc = 0 ] && [ "$("$P" version)" = v0.10.0 ] && [ -d "$data/v0.2.0" ] && ok "P8 self-update: back to v0.10.0, v0.2.0 kept" || bad "P8 newest: exit $rc, $("$P" version)"
out=$("$P" check 2>&1); [ "$out" = "PASS stub BIN=$data/v0.10.0/bin" ] && ok "P8 check: recover.sh with BIN of the version" || bad "P8 check: $out"

exit $status
