#!/bin/sh
# Run a command with a virtual X display available, then clean up.
#
#   tests/with-display.sh ./tests/run.sh
#
# Exists because starting Xvfb with a bare `&` in one CI step and using $DISPLAY in the
# next is unreliable - the server may not be up yet, or may not survive the step. This
# starts it, waits for the socket to actually appear, runs the command, and kills it
# whatever happens.
#
# If a real display is already reachable, the command runs directly and nothing is
# started: on a desktop session this script is a no-op.
set -eu

DISPLAY_NUM=${KGX_TEST_DISPLAY:-99}
SCREEN=${KGX_TEST_SCREEN:-1280x1024x24}
TIMEOUT_S=${KGX_TEST_WAIT:-20}

display_works() {
    # GTK is the authority here: it is what the checks actually need. Note that
    # Gtk.init_check() returns True even with no display, so ask for the Display.
    python3 - <<'PY' 2>/dev/null
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gtk, Gdk
Gtk.init_check()
sys.exit(0 if Gdk.Display.get_default() is not None else 1)
PY
}

if display_works; then
    exec "$@"
fi

if ! command -v Xvfb >/dev/null 2>&1; then
    echo "with-display.sh: Xvfb is not installed and no display is available." >&2
    echo "with-display.sh: the widget-level checks will be skipped." >&2
    exec "$@"
fi

Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" >/dev/null 2>&1 &
xvfb_pid=$!
# shellcheck disable=SC2064  # we want $! expanded now, not at trap time
trap "kill $xvfb_pid 2>/dev/null || true" EXIT INT TERM

waited=0
while [ "$waited" -lt "$TIMEOUT_S" ]; do
    if DISPLAY=":$DISPLAY_NUM" display_works; then
        break
    fi
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
        echo "with-display.sh: Xvfb died while starting" >&2
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done

if ! DISPLAY=":$DISPLAY_NUM" display_works; then
    echo "with-display.sh: no usable display on :$DISPLAY_NUM after ${TIMEOUT_S}s" >&2
    echo "with-display.sh: the widget-level checks will be skipped." >&2
fi

DISPLAY=":$DISPLAY_NUM" GDK_BACKEND=x11 "$@"