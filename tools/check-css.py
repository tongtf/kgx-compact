"""Validate a CSS file against the real GTK4 parser.

GTK reports unknown properties / bad syntax through the `parsing-error` signal on
Gtk.CssProvider, and logs them as GTK_CSS warnings at runtime. Neither is fatal, so
a typo in the user stylesheet fails silently apart from the terminal log - check it.

Usage: check-css.py [file ...]   (defaults to the GTK4 user stylesheet)
"""
import os
import re
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402  (needs the namespace pinned first)

Gtk.init_check()

DEFAULT = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "gtk-4.0", "gtk.css",
)

problems = []
checked = 0

for path in (sys.argv[1:] or [DEFAULT]):
    if not os.path.exists(path):
        print("SKIP  %s (does not exist)" % path)
        continue
    checked += 1
    provider = Gtk.CssProvider()

    def watch(prov, section, error, _path=path):
        # GTK puts the file:line inside the message ("gtk.css:12:5-20: ..."). This GTK
        # build's CssSection exposes no line accessor, so take it from the message.
        m = re.search(r":(\d+):\d+", error.message)
        problems.append((_path, int(m.group(1)) if m else "?", error.message))

    provider.connect("parsing-error", watch)
    with open(path, "rb") as fh:
        provider.load_from_data(fh.read())
    print("OK    %s (%d bytes)" % (path, os.path.getsize(path)))

for path, line, message in problems:
    where = "%s:%s" % (path, line) if line != "?" else path
    print("ERROR %s: %s" % (where, message))

if not problems and not checked:
    print("RESULT: FAIL (no stylesheet found)")
    sys.exit(1)

print("RESULT:", "FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)