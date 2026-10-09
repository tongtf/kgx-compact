"""Verify that a CSS file's selectors match real GTK4 nodes.

Parsing cleanly proves nothing: a selector can be syntactically perfect and still match
nothing because the node name or style class it targets does not exist. GTK4 also
removed GtkStyleContext.lookup(), so "did this rule apply" cannot be asked that way any
more. Instead this walks the real widget tree that kgx-window.ui builds and resolves
each selector against it, reporting which widget it lands on.

The tree mirrors the overlay: window.terminal-window > box.compact-tab-bar >
AdwTabBar > revealer > box.box > scrolledwindow > AdwTabBox.

Usage: verify-css-match.py <css-file>
"""
import os
import re
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw  # noqa: E402

Gtk.init_check()
Adw.init()

CSS = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.config/gtk-4.0/gtk.css")

# ---------------------------------------------------------------- parse the file
raw = open(CSS).read()
rules = []
for block in re.finditer(r"([^{}]+)\{([^{}]*)\}", re.sub(r"/\*.*?\*/", "", raw, flags=re.S)):
    sel_text, body = block.group(1).strip(), block.group(2).strip()
    if sel_text.startswith("@"):
        continue
    props = [(k.strip(), v.strip())
             for k, v in (d.split(":", 1) for d in body.split(";") if ":" in d)
             if k.strip() and v.strip()]
    for one in sel_text.split(","):
        one = " ".join(one.split())
        if one and props:
            rules.append((one, props))

print("rules parsed: %d" % len(rules))
for sel, props in rules:
    print("  %-62s %s" % (sel, ", ".join("%s: %s" % p for p in props)))

# GTK4 exposes no API for a widget's CSS *node name* (GtkStyleContext.lookup() was
# removed, and there is no replacement getter). So node names are taken from the names
# the widget types use in GTK/libadwaita's own stylesheets, which were verified by
# reading the installed libadwaita stylesheet. Anything not listed falls back to the
# GType name, and the widget-tree dump below shows what each rule actually resolved to.
# NOTE: pygobject's type(w).__name__ has no namespace prefix ("TabBar", not
# "AdwTabBar"), so these keys are the bare GType names.
NODE_NAME = {
    "TabBar": "tabbar",
    "AdwTabBox": "tabbox",
    "TabButton": "tabbutton",
    "Box": "box",
    "Button": "button",
    "MenuButton": "menubutton",
    "Revealer": "revealer",
    "ScrolledWindow": "scrolledwindow",
    "ApplicationWindow": "window",
}

# ------------------------------------- build the tree kgx-window.ui actually builds
window = Adw.ApplicationWindow(application=None)
window.add_css_class("terminal-window")

strip = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,
                hexpand=True, valign=Gtk.Align.CENTER)
strip.add_css_class("compact-tab-bar")

tabbar = Adw.TabBar()
strip.append(tabbar)
strip.append(Adw.TabButton(view=None))
strip.append(Gtk.Button(icon_name="tab-new-symbolic"))
strip.append(Gtk.MenuButton(icon_name="open-menu-symbolic"))
strip.append(Gtk.Button(icon_name="window-close-symbolic"))
window.set_content(strip)

PARENT = {}
ORDER = []


def walk(widget):
    try:
        classes = tuple(sorted(widget.get_css_classes()))
    except Exception:
        classes = ()
    ORDER.append(widget)
    child = widget.get_first_child()
    while child:
        PARENT[child] = widget
        walk(child)
        child = child.get_next_sibling()


walk(window)
NODE = {w: (NODE_NAME.get(type(w).__name__, type(w).__name__),
           frozenset(w.get_css_classes())) for w in ORDER}

SIMPLE = re.compile(r"([a-zA-Z][\w-]*)|\.([\w-]+)")


def parse_simple(token):
    """`window.terminal-window` is ONE widget matched by two conditions.

    A type selector and a class selector may be combined without whitespace, and both
    must hold for the same widget - that is exactly what the real selector means.
    """
    node = None
    classes = set()
    for m in SIMPLE.finditer(token):
        if m.group(1):
            node = m.group(1)
        elif m.group(2):
            classes.add(m.group(2))
    return node, frozenset(classes)


def matches(widget, want):
    node, want_classes = want
    name, classes = NODE[widget]
    if node and name != node:
        return False
    if want_classes and not want_classes <= classes:
        return False
    return bool(node or want_classes)


print("\nwidget tree:")
for w in ORDER:
    name, classes = NODE[w]
    print("  %-24s %s" % (name, sorted(classes)))


def children(widget):
    out = []
    child = widget.get_first_child()
    while child:
        out.append(child)
        child = child.get_next_sibling()
    return out


def descendants(widget, include_self=False):
    """Depth-first list of the subtree rooted at widget, in document order."""
    out = []
    stack = list(reversed(children(widget)))
    while stack:
        w = stack.pop()
        out.append(w)
        stack.extend(reversed(children(w)))
    if include_self:
        out.insert(0, widget)
    return out


def descendants_matching(widget, want):
    return next((w for w in descendants(widget) if matches(w, want)), None)


def resolve(steps):
    """steps: [(want, is_child)] outermost -> innermost. Returns the final match."""
    want0, _ = steps[0]
    for cand in ORDER:
        if not matches(cand, want0):
            continue
        prev = cand
        ok = True
        for want, is_child in steps[1:]:
            if is_child:
                nxt = next((c for c in children(prev) if matches(c, want)), None)
            else:
                nxt = descendants_matching(prev, want)
            if nxt is None:
                ok = False
                break
            prev = nxt
        if ok:
            return prev
    return None


print("\nselector resolution:")
bad = 0
for sel, props in rules:
    steps = []
    child = False
    for token in sel.split():
        if token == ">":
            child = True
            continue
        steps.append((parse_simple(token), child))
        child = False

    hit = resolve(steps)
    if hit is None:
        bad += 1
        print("  NO MATCH  %s" % sel)
    else:
        name, classes = NODE[hit]
        print("  matched   %-62s -> %s %s" % (sel, name, sorted(classes)))

print("\nmatched %d/%d" % (len(rules) - bad, len(rules)))

# An empty stylesheet trivially "passes" above; that is a silent no-op, not a success.
if not rules:
    print("RESULT: FAIL (no rules found - the stylesheet is empty or all commented out)")
    sys.exit(1)

print("RESULT:", "FAIL" if bad else "PASS")
sys.exit(1 if bad else 0)