#!/usr/bin/env python3
"""Run every check for a kgx-compact installation.

    kgx-verify.py all          # everything
    kgx-verify.py overlay        # overlay matches this Console, and type-checks
    kgx-verify css            # stylesheet parses with the real GTK4 parser
    kgx-verify match          # stylesheet selectors match real widgets (needs a display)

Each check exits non-zero on failure. This is the gate to run after `kgx-patch build`.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK_OVERLAY = os.path.join(HERE, "check-overlay.py")
CHECK_CSS = os.path.join(HERE, "check-css.py")
CHECK_MATCH = os.path.join(HERE, "verify-css-match.py")
PATCH = os.path.join(HERE, "kgx-patch.py")


def run(argv, label):
    print("=== %s ===" % label, flush=True)
    rc = subprocess.call(argv)
    print(flush=True)
    return rc


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("check", nargs="?", default="all",
                   choices=["all", "overlay", "css", "match"])
    p.add_argument("--overlay-dir", default=os.path.expanduser("~/.local/share/kgx-overlay"))
    p.add_argument("--css", default=os.path.expanduser("~/.config/gtk-4.0/gtk.css"))
    p.add_argument("--kgx-bin", default=os.environ.get("KGX_BIN", "/usr/bin/kgx"))
    args = p.parse_args()

    failures = []
    want = args.check
    do = (lambda k: want in ("all", k))

    if do("overlay"):
        rc = run([sys.executable, PATCH, "--kgx-bin", args.kgx_bin,
                  "--overlay-dir", args.overlay_dir, "check"], "overlay matches installed Console")
        failures += ["overlay: version mismatch"] if rc else []
        rc = run([sys.executable, CHECK_OVERLAY,
                  os.path.join(args.overlay_dir, "kgx-window.ui")],
                 "overlay type-check")
        failures += ["overlay: type-check"] if rc else []

    if do("css"):
        if os.path.exists(args.css):
            rc = run([sys.executable, CHECK_CSS, args.css], "stylesheet parses")
            failures += ["css: parse"] if rc else []
        else:
            print("=== stylesheet parses ===\nSKIP: %s does not exist\n" % args.css)

    if do("match"):
        if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
            if os.path.exists(args.css):
                rc = run([sys.executable, CHECK_MATCH, args.css],
                         "selectors match real widgets")
                failures += ["css: selectors"] if rc else []
        else:
            print("=== selectors match real widgets ===\n"
                  "SKIP: no DISPLAY/WAYLAND_DISPLAY\n")

    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("All requested checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())