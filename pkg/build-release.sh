#!/bin/sh
# Build a release tarball and the native package for this distribution.
#
#   pkg/build-release.sh [output-dir] [arch|debian]
#
# Defaults to autodetecting from the packaging tools present. Produces:
#
#   Arch      makepkg -si        -> /usr/bin/kgx-compact-install
#   Debian    dpkg-buildpackage  -> kgx-compact_*.deb
#
# The version is read from pkg/PKGBUILD and cross-checked against debian/changelog, so
# the two cannot disagree. makepkg resolves its source directory as
# $srcdir/$pkgname-$pkgver, so a mismatch there is a hard build failure anyway.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
OUT=${1:-/tmp/kgx-compact-release}
FAMILY=${2:-auto}

[ -d "$ROOT/.git" ] || { echo "build-release.sh must run inside the git checkout" >&2; exit 1; }

if [ "$FAMILY" = auto ]; then
    if command -v makepkg >/dev/null 2>&1; then
        FAMILY=arch
    elif command -v dpkg-buildpackage >/dev/null 2>&1; then
        FAMILY=debian
    else
        echo "neither makepkg nor dpkg-buildpackage found; guessing debian" >&2
        FAMILY=debian
    fi
fi

version=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD" | head -n 1)
[ -n "$version" ] || { echo "could not read pkgver from $HERE/PKGBUILD" >&2; exit 1; }

# debian/changelog's first line is "pkgname (version) dist; urgency=".
deb_version=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$HERE/../debian/changelog")
if [ -n "$deb_version" ] && [ "$deb_version" != "$version" ]; then
    echo "version mismatch: PKGBUILD says $version, debian/changelog says $deb_version" >&2
    echo "fix one of them so the two packages do not disagree" >&2
    exit 1
fi

prefix="kgx-compact-$version"
rm -rf "$OUT"
mkdir -p "$OUT"

# -prefix makes the tarball unpack straight into the directory PKGBUILD expects.
git -C "$ROOT" archive --format=tar.gz --prefix="$prefix/" \
    -o "$OUT/$prefix.tar.gz" HEAD

echo "built $OUT/$prefix.tar.gz (version $version)"
echo

case "$FAMILY" in
arch)
    cp "$HERE/PKGBUILD" "$OUT/PKGBUILD"
    echo "Now:"
    echo "  cd $OUT && makepkg -si"
    echo
    echo "The package installs nothing and enables nothing on its own. Run"
    echo "kgx-compact-install as your own user afterwards, then follow the gsettings"
    echo "command it prints."
    echo
    if [ "${1:-}" = "" ] && command -v makepkg >/dev/null 2>&1; then
        ( cd "$OUT" && makepkg -f --noconfirm --skippgpcheck )
    fi
    ;;
debian)
    # Native package, so it builds straight from an unpacked tarball with no .orig.
    tar -xzf "$OUT/$prefix.tar.gz" -C "$OUT"
    echo "Now:"
    echo "  cd $OUT/$prefix && dpkg-buildpackage -b -us -uc"
    echo "  sudo dpkg -i $OUT/kgx-compact_*.deb"
    echo
    echo "The package installs nothing and enables nothing on its own. Run"
    echo "kgx-compact-install as your own user afterwards, then follow the gsettings"
    echo "command it prints."
    echo
    if [ "${1:-}" = "" ] && command -v dpkg-buildpackage >/dev/null 2>&1; then
        ( cd "$OUT/$prefix" && dpkg-buildpackage -b -us -uc )
    fi
    ;;
*)
    echo "unknown packaging family: $FAMILY (expected arch or debian)" >&2
    exit 2
    ;;
esac