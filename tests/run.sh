#!/bin/sh
# End-to-end tests for kgx-compact.
#
#   tests/run.sh
#
# Everything runs against a throwaway $HOME, so the real installation is never touched.
# Checks that need a real Console binary or a display skip cleanly when there is none,
# which keeps `check()` usable inside a build chroot.
set -u

SRC=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SANDBOX=$(mktemp -d)
PASS=0
FAIL=0
SKIP=0

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip(){ SKIP=$((SKIP+1)); printf '  skip  %s\n' "$1"; }

# assert <description> <command...>
#
# Deliberately not written as `[ cond ] && ok .. || bad ..`: that idiom runs `bad` as
# well whenever `ok` returns non-zero, which for a test harness is a false failure.
assert() {
    _desc=$1
    shift
    if "$@"; then
        ok "$_desc"
    else
        bad "$_desc"
    fi
}

# Same, for the negations that would read worse with assert.
refute() {
    _desc=$1
    shift
    if "$@"; then
        bad "$_desc"
    else
        ok "$_desc"
    fi
}

fresh_home() {
    # ${SANDBOX:?} so an unset mktemp result can never turn into `rm -rf /home`.
    rm -rf "${SANDBOX:?}/home"
    mkdir -p "$SANDBOX/home/.config/gtk-4.0"
    printf '/* user rules */\nwindow.mine { color: red; }\n' > "$SANDBOX/home/.config/gtk-4.0/gtk.css"
}

have_display() { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }
have_kgx()     { [ -x "${KGX_BIN:-/usr/bin/kgx}" ]; }
have_py()      { python3 -c 'import gi' 2>/dev/null; }

echo "kgx-compact test suite"
echo

# ---------------------------------------------------------------- fragment is valid
echo "overlay fragment"
if python3 -c "
import xml.etree.ElementTree as ET
r = ET.parse('$SRC/overlay/compact-tab-bar.ui.xml').getroot()
assert r.tag == 'object', 'fragment must be a bare <object>'
ids = {o.get('id') for o in r.iter('object') if o.get('id')}
need = {'tab_bar', 'tab_button', 'new_tab_button', 'primary_menu_popover', 'theme_switcher'}
missing = need - ids
assert not missing, 'missing ids: %s' % sorted(missing)
" 2>"$SANDBOX/frag.err"; then
    ok "compact-tab-bar.ui.xml is one <object> and defines every id upstream references"
else
    bad "compact-tab-bar.ui.xml" "$(cat "$SANDBOX/frag.err")"
fi
echo

if have_kgx; then

# --------------------------------------------------------------------- generator
echo "overlay generator"
rm -rf "$SANDBOX/gen"; mkdir -p "$SANDBOX/gen/upstream" "$SANDBOX/gen/overlay"
if python3 "$SRC/tools/kgx-patch.py" --upstream-dir "$SANDBOX/gen/upstream" \
        --overlay-dir "$SANDBOX/gen/overlay" dump --out-dir "$SANDBOX/gen/upstream" >/dev/null 2>&1; then
    ok "dump extracts the pristine templates"
else
    bad "dump"
fi

if python3 "$SRC/tools/kgx-patch.py" --upstream-dir "$SANDBOX/gen/upstream" \
        --overlay-dir "$SANDBOX/gen/overlay" build >/dev/null 2>&1; then
    ok "build applies every edit"
else
    bad "build"
fi

if python3 - "$SANDBOX/gen/overlay/kgx-window.ui" <<'PY' 2>"$SANDBOX/gen.err"
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
tpl = root.find("template")
assert tpl is not None and tpl.get("class") == "KgxWindow"
assert tpl.find('property[@name="decorated"]').text == "False", "decorated not False"
assert not root.findall(".//object[@class='AdwHeaderBar']"), "headerbar survived"
strip = [o for o in root.iter("object") if o.get("id") == "compact_tab_bar"]
assert len(strip) == 1, "compact_tab_bar missing"
ov = [o for o in root.iter("object") if o.get("id") == "tab_overview"][0]
for n in ("show-start-title-buttons", "show-end-title-buttons"):
    p = [x for x in ov.findall("property") if x.get("name") == n]
    assert p and p[0].text == "False" and "bind-source" not in p[0].attrib, n
bp = [o for o in root.iter("object") if o.get("class") == "AdwBreakpoint"][0]
s = [x for x in bp.findall("setter") if x.get("object") == "new_tab_button"][0]
assert s.text == "True", "breakpoint not patched"
PY
then
    ok "generated overlay has all four edits applied"
else
    bad "generated overlay contents" "$(cat "$SANDBOX/gen.err")"
fi

# Determinism: same input, same bytes out.
mkdir -p "$SANDBOX/gen/overlay2"
python3 "$SRC/tools/kgx-patch.py" --upstream-dir "$SANDBOX/gen/upstream" \
    --overlay-dir "$SANDBOX/gen/overlay2" build >/dev/null 2>&1
if cmp -s "$SANDBOX/gen/overlay/kgx-window.ui" "$SANDBOX/gen/overlay2/kgx-window.ui"; then
    ok "generator is deterministic"
else
    bad "generator determinism"
fi
echo

# ------------------------------------------------------- generator refuses to guess
echo "generator refuses to guess"
# Strip the AdwHeaderBar from the dumped upstream: build must refuse, not guess.
python3 - "$SANDBOX/gen/upstream/kgx-window.ui" "$SANDBOX/mut" <<'PY'
import os, sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1]); root = tree.getroot()
for fs in root.iter("object"):
    if fs.get("class") == "KgxFullscreenBox":
        for c in list(fs.findall("child")):
            ob = c.find("object")
            if ob is not None and ob.get("class") == "AdwHeaderBar":
                fs.remove(c)
os.makedirs(sys.argv[2], exist_ok=True)
tree.write(os.path.join(sys.argv[2], "kgx-window.ui"))
open(os.path.join(sys.argv[2], "VERSION"), "w").write("51\n")
PY
mkdir -p "$SANDBOX/mut-overlay"
if python3 "$SRC/tools/kgx-patch.py" --upstream-dir "$SANDBOX/mut" \
        --overlay-dir "$SANDBOX/mut-overlay" build >"$SANDBOX/mut.out" 2>&1; then
    bad "should have refused to patch a changed upstream template"
else
    ok "refuses a changed upstream template"
    if grep -q "AdwHeaderBar" "$SANDBOX/mut.out"; then
        ok "refusal names the element that moved"
    else
        bad "refusal message does not name the missing element"
    fi
    if [ -f "$SANDBOX/mut-overlay/kgx-window.ui" ]; then
        bad "overlay was written despite the failure"
    else
        ok "no overlay written when an edit fails"
    fi
fi

# A stale dump must be rejected rather than silently reused.
echo "99" > "$SANDBOX/gen/overlay/.supported-major"
if python3 "$SRC/tools/kgx-patch.py" --upstream-dir "$SANDBOX/gen/upstream" \
        --overlay-dir "$SANDBOX/gen/overlay" check >/dev/null 2>&1; then
    bad "check should fail on a version mismatch"
else
    ok "check detects a version mismatch"
fi
echo

# ------------------------------------------------------------ installer behaviour
echo "installer"
fresh_home
HOME="$SANDBOX/home" "$SRC/install.sh" >/dev/null 2>&1
assert "wrapper installed and executable" test -x "$SANDBOX/home/.local/bin/kgx-compact"
assert "overlay generated" test -f "$SANDBOX/home/.local/share/kgx-overlay/kgx-window.ui"
assert "version stamp written" \
    test "$(cat "$SANDBOX/home/.local/share/kgx-overlay/.supported-major" 2>/dev/null)" = "51"

CSS="$SANDBOX/home/.config/gtk-4.0/gtk.css"
assert "user's own CSS rules preserved" grep -qF 'window.mine' "$CSS"
assert "exactly one managed block" \
    test "$(grep -cF 'kgx-compact (managed block' "$CSS")" = "1"
assert "stylesheet content installed" grep -qF 'compact-tab-bar' "$CSS"

# A pre-existing hand-written (unmarked) copy must be flagged, not silently doubled.
# Uses its own HOME so it cannot disturb the state the tests below rely on.
rm -rf "$SANDBOX/home2"; mkdir -p "$SANDBOX/home2/.config/gtk-4.0"
cp "$SRC/src/gtk.css" "$SANDBOX/home2/.config/gtk-4.0/gtk.css"
HOME="$SANDBOX/home2" "$SRC/install.sh" >"$SANDBOX/home2.log" 2>&1
assert "warns about unmarked kgx rules already in the stylesheet" \
    grep -q WARNING "$SANDBOX/home2.log"

cp "$CSS" "$SANDBOX/css1"
HOME="$SANDBOX/home" "$SRC/install.sh" >/dev/null 2>&1
assert "reinstall is idempotent" cmp -s "$CSS" "$SANDBOX/css1"

# Editing inside the managed block must be undone by a refresh.
# Written via a temp file rather than `sed -i`, which is not portable (BSD sed and
# GNU sed disagree on the argument-less form).
sed 's/min-height: 0;/min-height: 999px;/' "$CSS" > "$SANDBOX/css.tampered"
mv "$SANDBOX/css.tampered" "$CSS"
HOME="$SANDBOX/home" "$SRC/install.sh" >/dev/null 2>&1
refute "refresh replaces the managed block" grep -qF "min-height: 999px;" "$CSS"

# --print-plan must write nothing.
cp "$CSS" "$SANDBOX/css2"
HOME="$SANDBOX/home" "$SRC/install.sh" --print-plan >/dev/null 2>&1
assert "--print-plan writes nothing" cmp -s "$CSS" "$SANDBOX/css2"

HOME="$SANDBOX/home" "$SRC/install.sh" --uninstall >/dev/null 2>&1
assert "uninstall removes the wrapper" test ! -f "$SANDBOX/home/.local/bin/kgx-compact"
assert "uninstall keeps the user's CSS" grep -qF 'window.mine' "$CSS"
refute "uninstall strips the managed block" grep -qF "kgx-compact (managed block" "$CSS"
echo

# --------------------------------------------------------- packaging consistency
echo "packaging"
pkgver=$(sed -n 's/^pkgver=//p' "$SRC/pkg/PKGBUILD" | head -n 1)
debver=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$SRC/debian/changelog")
assert "PKGBUILD and debian/changelog agree on the version" \
    test -n "$pkgver" -a "$pkgver" = "$debver"
assert "debian source format is native" \
    grep -qx '3.0 (native)' "$SRC/debian/source/format"
# Both packaging recipes must install the same launcher under the same name.
assert "PKGBUILD installs the launcher as kgx-compact-install" \
    grep -q 'usr/bin/kgx-compact-install' "$SRC/pkg/PKGBUILD"
assert "debian installs the launcher as kgx-compact-install" \
    grep -q 'usr/bin/kgx-compact-install' "$SRC/debian/kgx-compact.install"
# Every tool the README tells users to run must be packaged on both.
for t in kgx-patch.py kgx-verify.py check-overlay.py check-css.py verify-css-match.py; do
    assert "PKGBUILD ships $t" grep -q "tools/$t" "$SRC/pkg/PKGBUILD"
    assert "debian ships $t" grep -q "tools/$t" "$SRC/debian/kgx-compact.install"
done
echo

# ---------------------------------------------------------------------- overlay ui
echo "overlay type-check"
if have_py; then
    if python3 "$SRC/tools/check-overlay.py" "$SANDBOX/gen/overlay/kgx-window.ui" >/dev/null 2>&1; then
        ok "generated overlay type-checks against GTK4/libadwaita"
    else
        bad "overlay type-check"
    fi
else
    skip "overlay type-check (no PyGObject)"
fi
echo

else
    echo "skip  generator / installer / overlay checks (no kgx binary at ${KGX_BIN:-/usr/bin/kgx})"
    echo
fi

# --------------------------------------------------------------------- CSS checks
echo "stylesheet"
if have_display && have_py; then
    if python3 "$SRC/tools/check-css.py" "$SRC/src/gtk.css" >/dev/null 2>&1; then
        ok "stylesheet parses with the real GTK4 parser"
    else
        bad "stylesheet parse"
    fi
    if python3 "$SRC/tools/verify-css-match.py" "$SRC/src/gtk.css" >/dev/null 2>&1; then
        ok "every selector matches a real widget"
    else
        bad "selector matching"
    fi
    # Negative control: a typo'd node name must be rejected, not silently pass.
    sed 's/ tabbar \.box/ tabbarXYZ .box/' "$SRC/src/gtk.css" > "$SANDBOX/bad.css"
    if python3 "$SRC/tools/verify-css-match.py" "$SANDBOX/bad.css" >/dev/null 2>&1; then
        bad "verifier accepted a selector that matches nothing"
    else
        ok "verifier rejects a selector that matches nothing"
    fi
    # And an empty stylesheet must not count as a pass either.
    printf '/* nothing */\n' > "$SANDBOX/empty.css"
    if python3 "$SRC/tools/verify-css-match.py" "$SANDBOX/empty.css" >/dev/null 2>&1; then
        bad "verifier accepted an empty stylesheet"
    else
        ok "verifier rejects an empty stylesheet"
    fi
else
    skip "css widget checks (need DISPLAY/WAYLAND_DISPLAY and PyGObject)"
fi
echo

# -------------------------------------------------------------------------- result
echo "----------------------------------------"
printf 'passed %d, failed %d' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ', skipped %d' "$SKIP"
printf '\n'
[ "$FAIL" -eq 0 ] || exit 1