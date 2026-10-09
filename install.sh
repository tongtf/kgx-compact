#!/bin/sh
# Install kgx-compact for the current user. No root, nothing outside $HOME.
#
#   ./install.sh              install / refresh
#   ./install.sh --uninstall  remove everything this installed
#   ./install.sh --print-plan show what would be written, write nothing
#
# Deliberately does NOT touch $HOME/.config/gtk-4.0/gtk.css: that file is global to
# every GTK4 application and may already contain the user's own rules. Instead this
# installs the stylesheet as a managed block delimited by the markers below, which is
# replaced idempotently and removed exactly on uninstall. See docs/CSS.md.
set -eu

: "${HOME:?install.sh: HOME is not set; run this as a normal user, not via sudo}"

PREFIX="$HOME"
BIN_DIR="$PREFIX/.local/bin"
OVERLAY_DIR="$PREFIX/.local/share/kgx-overlay"
STATE_DIR="$PREFIX/.local/share/kgx-compact"
UPSTREAM_DIR="$STATE_DIR/upstream"
CSS_FILE="${XDG_CONFIG_HOME:-$PREFIX/.config}/gtk-4.0/gtk.css"

BEGIN_MARK="/* >>> kgx-compact (managed block, do not edit inside) >>> */"
END_MARK="/* <<< kgx-compact <<< */"

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=install

for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE=uninstall ;;
        --print-plan) MODE=plan ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
act() {
    if [ "$MODE" = plan ]; then
        say "  would: $*"
    else
        say "  $*"
        "$@"
    fi
}

if [ "$MODE" = uninstall ]; then
    say "Removing kgx-compact"
    act rm -f "$BIN_DIR/kgx-compact"
    act rm -f "$OVERLAY_DIR/kgx-window.ui" "$OVERLAY_DIR/.supported-major"
    if [ -f "$CSS_FILE" ] && grep -qF "$BEGIN_MARK" "$CSS_FILE"; then
        if [ "$MODE" = plan ]; then
            say "  would: strip the managed block from $CSS_FILE"
        else
            tmp="$CSS_FILE.kgx-compact.tmp"
            awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
                $0 == b { inside = 1; next }
                $0 == e { inside = 0; next }
                !inside  { print }
            ' "$CSS_FILE" > "$tmp"
            # do not leave a file with nothing but blank lines behind.
            # (plain `grep -q`, not -S: that flag does not exist on every grep and
            #  fails in a way that would silently delete a stylesheet with real rules)
            if grep -q "[^[:space:]]" "$tmp"; then
                mv "$tmp" "$CSS_FILE"
            else
                rm -f "$tmp" "$CSS_FILE"
            fi
            say "  stripped the managed block from $CSS_FILE"
        fi
    fi
    if [ -d "$OVERLAY_DIR" ]; then rmdir "$OVERLAY_DIR" 2>/dev/null || true; fi
    say "Left in place (your own data, not ours): $STATE_DIR/upstream, $STATE_DIR/backup"
    say "Uninstall complete."
    exit 0
fi

say "Installing kgx-compact into $PREFIX"
act mkdir -p "$BIN_DIR" "$OVERLAY_DIR" "$UPSTREAM_DIR"
act cp "$SRC/src/kgx-compact" "$BIN_DIR/kgx-compact"
act chmod 0755 "$BIN_DIR/kgx-compact"
act cp "$SRC/src/gtk.css" "$STATE_DIR/gtk.css"
act cp "$SRC/overlay/compact-tab-bar.ui.xml" "$STATE_DIR/compact-tab-bar.ui.xml"

say ""
say "Generating the overlay for the installed Console"
if [ "$MODE" = plan ]; then
    say "  would: kgx-patch.py dump && kgx-patch.py build"
else
    python3 "$SRC/tools/kgx-patch.py" \
        --overlay-dir "$OVERLAY_DIR" --upstream-dir "$UPSTREAM_DIR" \
        dump --out-dir "$UPSTREAM_DIR"
    python3 "$SRC/tools/kgx-patch.py" \
        --overlay-dir "$OVERLAY_DIR" --upstream-dir "$UPSTREAM_DIR" build
fi

say ""
say "Merging the stylesheet into $CSS_FILE"

# A pre-existing hand-written copy of these rules (from before this installer existed,
# or from editing gtk.css by hand) sits outside the markers and would survive, leaving
# two copies of every rule. Duplicate CSS is not a parser error, so it would just apply
# the same thing twice with no warning from anywhere.
if [ -f "$CSS_FILE" ] && awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { inside = 1 }
        $0 == e { inside = 0 }
        !inside  { print }
    ' "$CSS_FILE" | grep -qE 'compact-tab-bar|terminal-window'; then
    say "  WARNING: $CSS_FILE already contains kgx-compact rules OUTSIDE the managed"
    say "           block (an older hand-written copy?). They stay, so those rules will"
    say "           now be applied twice. Delete the unmarked copy to clean that up."
fi

if [ "$MODE" = plan ]; then
    if [ ! -f "$CSS_FILE" ]; then
        say "  would: create $CSS_FILE from src/gtk.css"
    elif grep -qF "$BEGIN_MARK" "$CSS_FILE"; then
        say "  would: replace the existing managed block in $CSS_FILE"
    else
        say "  would: append a managed block to $CSS_FILE (keeping your own rules)"
    fi
else
    mkdir -p "$(dirname "$CSS_FILE")"
    rest="$CSS_FILE.kgx-compact.rest"
    tmp="$CSS_FILE.kgx-compact.tmp"
    if [ -f "$CSS_FILE" ]; then
        # Everything outside the markers is the user's own, and is preserved verbatim.
        # Trailing blank lines are dropped so repeated installs converge instead of
        # growing a new blank line each run.
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
            $0 == b { inside = 1; next }
            $0 == e { inside = 0; next }
            !inside  { print }
        ' "$CSS_FILE" |
        awk '{ line[NR] = $0 }
             END { n = NR; while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--;
                   for (i = 1; i <= n; i++) print line[i] }' > "$rest"
    else
        : > "$rest"
    fi
    {
        cat "$rest"
        printf '\n%s\n' "$BEGIN_MARK"
        cat "$SRC/src/gtk.css"
        # src/gtk.css may not end in a newline; make sure the marker starts its own line.
        printf '\n%s\n' "$END_MARK"
    } > "$tmp"
    mv "$tmp" "$CSS_FILE"
    rm -f "$rest"
    say "  managed block written (your own rules preserved)"
fi

say ""
say "Point your default terminal at the wrapper:"
say "  gsettings set org.gnome.desktop.applications/terminal exec '$BIN_DIR/kgx-compact'"
say ""
say "Then run: $SRC/tools/kgx-verify.py all"