#!/usr/bin/env bash
# Build the release assets of this checkout: polyship.tar.gz (bin/, lab/recover.sh, VERSION, README.md, LICENSE)
# and checksums.txt with its sha256. Contract: .archcore/architecture/polyship-release.spec.md.
#
#   .github/scripts/package.sh vX.Y.Z <out dir>
set -euo pipefail
tag=${1:?usage: package.sh vX.Y.Z <out dir>}; out=${2:?usage: package.sh vX.Y.Z <out dir>}
printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || { echo "package: $tag is not vMAJOR.MINOR.PATCH" >&2; exit 1; }
here=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/lab" "$out"
cp "$here"/bin/polyship "$here"/bin/merge.sh "$here"/bin/ship.sh "$here"/bin/lib.sh "$stage/bin/"
cp "$here/lab/recover.sh" "$stage/lab/"; cp "$here/README.md" "$here/LICENSE" "$stage/"
echo "${tag#v}" > "$stage/VERSION"
tar -czf "$out/polyship.tar.gz" -C "$stage" .
( cd "$out" && if command -v sha256sum >/dev/null; then sha256sum polyship.tar.gz; else shasum -a 256 polyship.tar.gz; fi ) > "$out/checksums.txt"
echo "package: $out/polyship.tar.gz ($tag)"
