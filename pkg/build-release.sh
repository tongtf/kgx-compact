#!/bin/sh
# Build a release tarball and the Arch package from a clean checkout.
#
#   pkg/build-release.sh [output-dir]
#
# Produces kgx-compact-<version>.tar.gz and builds the PKGBUILD against it. The version
# is read from the PKGBUILD so the two can never disagree - which matters, because
# makepkg resolves the source directory as $srcdir/$pkgname-$pkgver.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
OUT=${1:-/tmp/kgx-compact-release}

[ -d "$ROOT/.git" ] || { echo "build-release.sh must run inside the git checkout" >&2; exit 1; }

version=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD" | head -n 1)
[ -n "$version" ] || { echo "could not read pkgver from $HERE/PKGBUILD" >&2; exit 1; }

prefix="kgx-compact-$version"

rm -rf "$OUT"
mkdir -p "$OUT"

# -prefix makes the tarball unpack straight into the directory PKGBUILD expects.
git -C "$ROOT" archive --format=tar.gz --prefix="$prefix/" \
    -o "$OUT/$prefix.tar.gz" HEAD
cp "$HERE/PKGBUILD" "$OUT/PKGBUILD"

echo "built $OUT/$prefix.tar.gz (version $version)"
echo
echo "Now:"
echo "  cd $OUT && makepkg -si"
echo
echo "The package installs nothing and enables nothing on its own. Run kgx-compact-install"
echo "as your own user afterwards, then follow the gsettings command it prints."

if [ "${1:-}" = "" ]; then
    # Convenience: build it here too, unless the tools are missing.
    if command -v makepkg >/dev/null 2>&1; then
        ( cd "$OUT" && makepkg -f --noconfirm --skippgpcheck "$@" )
    else
        echo
        echo "(makepkg not found; skipped building the package)"
    fi
fi