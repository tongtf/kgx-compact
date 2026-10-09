#!/usr/bin/env python3
"""Generate the kgx overlay from the pristine upstream template.

Why this exists
---------------
Console builds its window from a GtkBuilder template compiled into the binary as
/org/gnome/Console/kgx-window.ui. G_RESOURCE_OVERLAYS can replace that single resource,
so a borderless compact terminal does not require patching Console itself. But the
overlay has to be regenerated whenever Console is upgraded, and hand-editing the template
each time is how overlays quietly rot.

So the overlay is *derived* here, from the pristine upstream file plus a declarative list
of edits, instead of being maintained by hand.

Every edit asserts the shape it expects to find. If an upstream release moves things
around, this exits non-zero and says what did not match, rather than emitting an overlay
that parses but silently does the wrong thing.

Usage:
    kgx-patch.py dump                 # extract upstream templates from the installed kgx
    kgx-patch.py build                # regenerate the overlay from the dumped upstream
    kgx-patch.py check                # validate the built overlay
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

DEFAULT_KGX = os.environ.get("KGX_BIN", "/usr/bin/kgx")
DEFAULT_OVERLAY_DIR = os.path.expanduser("~/.local/share/kgx-overlay")
DEFAULT_UPSTREAM_DIR = os.path.expanduser("~/.local/share/kgx-compact/upstream")

# Resources we care about inside the kgx binary.
WINDOW_UI = "/org/gnome/Console/kgx-window.ui"
STYLE_CSS = "/org/gnome/Console/style.css"

# Node names to use when pretty-printing the dumped templates (pygobject strips the
# namespace prefix; this script does not).
TEMPLATE_CLASSES = {
    "KgxWindow": "kgx-window.ui",
    "KgxTerminal": "kgx-terminal.ui",
    "KgxPages": "kgx-pages.ui",
    "KgxEmpty": "kgx-empty.ui",
    "KgxSettings": "kgx-settings.ui",
    "KgxSimpleTab": "kgx-simple-tab.ui",
    "KgxSpad": "kgx-spad.ui",
    "KgxTab": "kgx-tab.ui",
    "KgxThemeSwitcher": "kgx-theme-switcher.ui",
    "KgxFullscreenBox": "kgx-fullscreen-box.ui",
    "KgxPreferencesWindow": "kgx-preferences-window.ui",
    "KgxFontPicker": "kgx-font-picker.ui",
    "AdwTabPage": "adw-tab-page.ui",
    "shortcuts-dialog": "shortcuts-dialog.ui",
}

HERE = os.path.dirname(os.path.abspath(__file__))
COMPACT_STRIP = os.path.join(HERE, os.pardir, "overlay", "compact-tab-bar.ui.xml")


class EditFailed(Exception):
    """An upstream assumption did not hold; the overlay must not be written."""


# --------------------------------------------------------------------------- helpers
def detect_major(kgx_bin):
    try:
        out = subprocess.run([kgx_bin, "--version"], capture_output=True, text=True,
                             timeout=20).stdout
    except Exception as exc:
        raise EditFailed("could not run %s --version: %s" % (kgx_bin, exc))
    m = re.search(r"# KGX (\d+)\.(\d+)", out)
    if not m:
        raise EditFailed("could not parse a Console version from %r" % out.strip()[:120])
    return m.group(1), "%s.%s" % (m.group(1), m.group(2))


def iter_templates(binary):
    """Yield (template_class, bytes) for every GtkBuilder XML in the kgx binary.

    The .ui files are zlib-compressed inside the binary's GResource blob, so scan for
    XML that decompresses out of it rather than parsing the GVDB table by hand.
    """
    data = open(binary, "rb").read()
    found = {}
    for off in range(len(data) - 8):
        if data[off] != 0x78:              # zlib header first byte
            continue
        for wbits in (15, 31, -15):
            try:
                out = zlib.decompressobj(wbits).decompress(data[off:], 8 * 1024 * 1024)
            except Exception:
                continue
            if not out.startswith(b"<?xml") or b"<interface" not in out:
                continue
            m = re.search(rb'<template\s+class="([A-Za-z0-9_]+)"', out)
            if m and m.group(1).decode() not in found:
                found[m.group(1).decode()] = out
            break
    return found


def pretty(raw):
    """Normalise XML formatting so the generated file is stable and diffable."""
    import xml.dom.minidom as minidom
    dom = minidom.parseString(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
    text = "\n".join(line for line in dom.toprettyxml(indent="  ").splitlines()
                     if line.strip())
    return text + "\n"


def find_by_id(parent, obj_id):
    """First descendant <object id="...">.

    Uses iter() rather than ElementTree path syntax: paths like ".//object[...]" are
    rejected or silently reinterpreted on a subtree, and these lookups are all
    "somewhere below here", so a plain scan is clearer and has no such edge cases.
    """
    for obj in parent.iter("object"):
        if obj.get("id") == obj_id:
            return obj
    return None


def find_by_class(parent, cls):
    """First descendant <object class="...">."""
    for obj in parent.iter("object"):
        if obj.get("class") == cls:
            return obj
    return None


def require(node, what):
    if node is None:
        raise EditFailed("upstream template no longer has %s" % what)
    return node


def set_prop(obj, name, value, replace_attrs=None, index=None):
    """Set (or replace) a <property name=...> on an <object>, dropping old attributes.

    `index` controls where a newly created property lands. GtkBuilder does not care
    about property order, but keeping it deterministic means the generated file stays
    diffable against a hand-written reference overlay.
    """
    for prop in obj.findall("property"):
        if prop.get("name") == name:
            for key, val in (replace_attrs or {}).items():
                prop.set(key, val)
            for key in list(prop.attrib):
                if key not in ("name",) and key not in (replace_attrs or {}):
                    del prop.attrib[key]
            prop.text = value
            return prop
    attrs = {"name": name}
    attrs.update(replace_attrs or {})
    prop = ET.Element("property", attrs)
    prop.text = value
    if index is None:
        obj.append(prop)
    else:
        obj.insert(index, prop)
    return prop


# ------------------------------------------------------------------------------ edits
def edit_decorated(template):
    """1. Ask the compositor for no window decorations -> no WM title bar."""
    if template.find('property[@name="decorated"]') is not None:
        raise EditFailed("upstream template already sets `decorated`; "
                         "re-check whether this edit is still needed")
    set_prop(template, "decorated", "False", index=0)
    return "decorated=False on KgxWindow"


def edit_title_buttons(template):
    """2. Never draw the window control buttons in the tab overview."""
    overview = require(find_by_id(template, "tab_overview"),
                       "the AdwTabOverview object (id=tab_overview)")
    changed = []
    for name in ("show-start-title-buttons", "show-end-title-buttons"):
        for prop in overview.findall("property"):
            if prop.get("name") == name:
                if "bind-source" not in prop.attrib:
                    raise EditFailed(
                        "%s is no longer bound to `fullscreened`; upstream changed, "
                        "re-check this edit" % name)
                set_prop(overview, name, "False")
                changed.append(name)
                break
        else:
            raise EditFailed("AdwTabOverview has no %s property" % name)
    return "%s = False on tab_overview" % ", ".join(changed)


def edit_compact_strip(template):
    """3. Replace AdwHeaderBar + AdwTabBar with one compact strip."""
    fullscreen = require(find_by_class(template, "KgxFullscreenBox"),
                         "the KgxFullscreenBox object")
    tops = [c for c in fullscreen.findall("child") if c.get("type") == "top"]

    headerbar_child = tabbar_child = None
    for child in tops:
        obj = child.find("object")
        if obj is None:
            continue
        cls = obj.get("class")
        if cls == "AdwHeaderBar" and headerbar_child is None:
            headerbar_child = child
        elif cls == "AdwTabBar" and tabbar_child is None:
            tabbar_child = child
    if headerbar_child is None:
        raise EditFailed("no AdwHeaderBar child of KgxFullscreenBox; upstream changed")
    if tabbar_child is None:
        raise EditFailed("no AdwTabBar child of KgxFullscreenBox; upstream changed")

    # Keep the ids the AdwBreakpoint setters and the tab_overview `inverted` binding
    # refer to. Upstream owns both of those, so silently dropping them would break the
    # overlay in a way that still parses.
    strip_src = ET.parse(COMPACT_STRIP).getroot()
    strip_ids = {o.get("id") for o in strip_src.iter("object") if o.get("id")}
    upstream_tabs = {o.get("id") for o in tabbar_child.iter("object") if o.get("id")}
    missing = upstream_tabs - strip_ids
    if missing:
        raise EditFailed(
            "upstream tab bar defines id(s) %s that the compact strip does not; "
            "add them to overlay/compact-tab-bar.ui.xml" % sorted(missing))

    new_child = ET.Element("child", {"type": "top"})
    new_child.append(strip_src)

    idx_top = list(fullscreen).index(headerbar_child)
    fullscreen.remove(headerbar_child)
    # Removing the headerbar shifts indices; re-find the tabbar before removing it.
    tabbar_child = next(c for c in fullscreen.findall("child")
                        if c.get("type") == "top"
                        and c.find("object") is not None
                        and c.find("object").get("class") == "AdwTabBar")
    fullscreen.remove(tabbar_child)
    idx_top = min(idx_top, len(list(fullscreen)))
    fullscreen.insert(idx_top, new_child)

    return "AdwHeaderBar + AdwTabBar -> compact_tab_bar"


def edit_breakpoint(template):
    """4. Show the new-tab button in the narrow layout too (no header bar holds it)."""
    bp = require(find_by_class(template, "AdwBreakpoint"),
                 "the AdwBreakpoint object")
    hit = False
    for setter in bp.findall("setter"):
        if setter.get("object") == "new_tab_button":
            if setter.get("property") != "visible":
                raise EditFailed("the new_tab_button breakpoint setter now targets "
                                 "%r; re-check this edit" % setter.get("property"))
            if setter.text == "True":
                raise EditFailed("upstream already shows new_tab_button when narrow; "
                                 "re-check whether this edit is still needed")
            setter.text = "True"
            hit = True
    if not hit:
        raise EditFailed("AdwBreakpoint has no setter for new_tab_button; upstream changed")
    return "new_tab_button visible when narrow"


EDITS = [
    edit_decorated,
    edit_title_buttons,
    edit_compact_strip,
    edit_breakpoint,
]


# -------------------------------------------------------------------------- commands
def cmd_dump(args):
    major, version = detect_major(args.kgx_bin)
    templates = iter_templates(args.kgx_bin)
    if "KgxWindow" not in templates:
        raise EditFailed("no kgx-window.ui template found in %s - is %s a Console binary?"
                         % (args.kgx_bin, args.kgx_bin))

    os.makedirs(args.out_dir, exist_ok=True)
    written = []
    for cls, raw in sorted(templates.items()):
        name = TEMPLATE_CLASSES.get(cls, cls + ".ui")
        path = os.path.join(args.out_dir, name)
        with open(path, "w") as fh:
            fh.write(pretty(raw))
        written.append(name)
    print("Console version: %s (major %s)" % (version, major))
    for name in written:
        print("  dumped %s" % os.path.join(args.out_dir, name))
    with open(os.path.join(args.out_dir, "VERSION"), "w") as fh:
        fh.write(major + "\n")
    print("\nNext: kgx-patch.py build")
    return 0


def cmd_build(args):
    major, version = detect_major(args.kgx_bin)
    upstream = os.path.join(args.upstream_dir, "kgx-window.ui")
    if not os.path.exists(upstream):
        raise EditFailed("no pristine template at %s - run `kgx-patch.py dump` first"
                         % upstream)
    dumped = os.path.join(args.upstream_dir, "VERSION")
    if os.path.exists(dumped) and open(dumped).read().strip() != major:
        raise EditFailed("dumped templates are for Console %s but %s is Console %s - "
                         "re-run `kgx-patch.py dump`"
                         % (open(dumped).read().strip(), args.kgx_bin, major))

    tree = ET.parse(upstream)
    root = tree.getroot()
    template = root.find("template")
    if template is None:
        raise EditFailed("upstream template has no <template> element")
    if template.get("class") != "KgxWindow":
        raise EditFailed("upstream <template> is %r, expected KgxWindow"
                         % template.get("class"))
    if template.find('property[@name="decorated"]') is not None:
        raise EditFailed("upstream template already has `decorated`; dump looks stale")

    print("applying edits to Console %s:" % version)
    for edit in EDITS:
        print("  - %s" % edit(template))

    out = pretty(ET.tostring(root, encoding="unicode"))
    os.makedirs(args.overlay_dir, exist_ok=True)
    target = os.path.join(args.overlay_dir, "kgx-window.ui")
    with open(target, "w") as fh:
        fh.write(out)
    with open(os.path.join(args.overlay_dir, ".supported-major"), "w") as fh:
        fh.write(major + "\n")

    print("\nwrote %s" % target)
    print("wrote %s (%s)" % (os.path.join(args.overlay_dir, ".supported-major"), major))
    print("\nNext: kgx-verify.py all")
    return 0


def cmd_check(args):
    path = os.path.join(args.overlay_dir, "kgx-window.ui")
    if not os.path.exists(path):
        raise EditFailed("no overlay at %s" % path)
    stamp = os.path.join(args.overlay_dir, ".supported-major")
    if not os.path.exists(stamp):
        raise EditFailed("no .supported-major stamp next to the overlay")
    try:
        major, version = detect_major(args.kgx_bin)
    except EditFailed as exc:
        print("WARNING: %s" % exc)
        return 0
    stamped = open(stamp).read().strip()
    if stamped != major:
        print("MISMATCH: overlay is built for Console %s, installed is %s"
              % (stamped, version))
        return 1
    print("overlay is built for the installed Console %s" % version)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kgx-bin", default=DEFAULT_KGX)
    parser.add_argument("--overlay-dir", default=DEFAULT_OVERLAY_DIR)
    parser.add_argument("--upstream-dir", default=DEFAULT_UPSTREAM_DIR)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("dump", help="extract pristine templates from the installed kgx")
    p.add_argument("--out-dir", default=DEFAULT_UPSTREAM_DIR)
    p.set_defaults(func=cmd_dump)

    p = sub.add_parser("build", help="regenerate the overlay from the dumped upstream")
    p.set_defaults(func=cmd_build)

    p = sub.add_parser("check", help="report whether the overlay matches this Console")
    p.set_defaults(func=cmd_check)

    args = parser.parse_args()
    try:
        return args.func(args)
    except EditFailed as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        print("\nThe overlay was NOT written. Console has probably changed its window "
              "template; port overlay/compact-tab-bar.ui.xml and the edits in "
              "tools/kgx-patch.py to the new structure.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())