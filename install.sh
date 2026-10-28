#!/bin/sh
# Install polyship on macOS or Linux:
#   curl -fsSL https://raw.githubusercontent.com/ivklgn/polyship/main/install.sh | sh
# Run it again to update. POLYSHIP_VERSION=vX.Y.Z picks a release (default: latest), also to go back.
# POLYSHIP_INSTALL_DIR picks the directory of the command (default: ~/.local/bin).
# POLYSHIP_BASE_URL replaces the release download URL, for a fork or a local build (file:///path/to/dir).
# The release goes to ${XDG_DATA_HOME:-~/.local/share}/polyship/<version>/; nothing is written into a repository.
set -eu

# The whole script is one function, so a download cut in the middle runs nothing.
main() {
	repo=ivklgn/polyship
	dir=${POLYSHIP_INSTALL_DIR:-$HOME/.local/bin}
	data=${XDG_DATA_HOME:-$HOME/.local/share}/polyship
	version=${POLYSHIP_VERSION:-latest}
	for c in bash perl git curl tar; do command -v $c >/dev/null 2>&1 || fail "$c is required"; done

	if [ -n "${POLYSHIP_BASE_URL:-}" ]; then
		base=$POLYSHIP_BASE_URL
	elif [ "$version" = latest ]; then
		base=https://github.com/$repo/releases/latest/download
	else
		base=https://github.com/$repo/releases/download/$version
	fi
	file=polyship.tar.gz

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	echo "Downloading $base/$file"
	curl -fsSL -o "$tmp/$file" "$base/$file" || fail "download failed; is there a release at https://github.com/$repo/releases?"
	curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" || fail "cannot download checksums.txt"

	want=$(awk -v f="$file" '$2 == f { print $1 }' "$tmp/checksums.txt")
	if command -v sha256sum >/dev/null 2>&1; then
		got=$(sha256sum "$tmp/$file" | cut -d' ' -f1)
	else
		got=$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)
	fi
	[ -n "$want" ] && [ "$want" = "$got" ] || fail "checksum mismatch for $file"

	mkdir "$tmp/release"
	tar -xzf "$tmp/$file" -C "$tmp/release"
	v=$(cat "$tmp/release/VERSION" 2>/dev/null) || fail "$file has no VERSION"
	echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "$file has a bad VERSION '$v'"

	# A version directory never changes once it is there: a running polyship ship may still use it.
	mkdir -p "$data"
	if [ ! -d "$data/$v" ]; then
		rm -rf "$data/.$v.tmp"
		cp -R "$tmp/release" "$data/.$v.tmp"
		mv "$data/.$v.tmp" "$data/$v"
	fi
	mkdir -p "$dir"
	ln -s "$data/$v/bin/polyship" "$dir/.polyship.tmp.$$"
	mv -f "$dir/.polyship.tmp.$$" "$dir/polyship"
	echo "Installed $("$dir/polyship" --version) to $dir/polyship"

	case ":$PATH:" in
	*":$dir:"*) ;;
	*) echo "Add $dir to PATH, for example: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.profile" ;;
	esac
	command -v wt >/dev/null 2>&1 || echo "polyship needs Worktrunk: brew install worktrunk && wt config shell install"
}

fail() {
	echo "polyship install: $1" >&2
	exit 1
}

main "$@"
