import sys
import xml.etree.ElementTree as ET

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GObject

# force the Gtk/Adw typelibs + shared libs to load so GTypes are registered
for _ in (Gtk.Widget, Gtk.Box, Gtk.Button, Gtk.Stack, Gtk.Label, Gtk.PopoverMenu,
          Gtk.MenuButton, Adw.Breakpoint, Adw.TabBar, Adw.TabButton, Adw.TabOverview,
          Adw.HeaderBar, Adw.WindowTitle, Adw.ApplicationWindow, GObject.BindingGroup):
    pass

path = sys.argv[1]
root = ET.parse(path).getroot()
CUSTOM = "Kgx"


def klass_of(name):
    gtype = GObject.type_from_name(name)
    return GObject.type_class_ref(gtype)


errors = []
notes = []
classes = set()
for obj in root.iter("object"):
    cls = obj.get("class")
    if not cls:
        continue
    classes.add(cls)
    if cls.startswith(CUSTOM):
        continue
    try:
        klass = klass_of(cls)
    except Exception as e:
        notes.append("class %s not introspectable (%s) - taken from upstream" % (cls, e))
        continue
    for prop in obj.findall("property"):
        pname = prop.get("name")
        if not pname or "bind-source" in prop.attrib:
            continue
        try:
            ok = GObject.Object.find_property(klass, pname) is not None
        except Exception:
            ok = True
        if not ok:
            errors.append("%s: no property '%s'" % (cls, pname))
    for sig in obj.findall("signal"):
        sname = sig.get("name")
        if not sname or ":" in sname:
            continue
        if GObject.signal_lookup(sname, GObject.type_from_name(cls)) < 0:
            errors.append("%s: no signal '%s'" % (cls, sname))

ids = {o.get("id") for o in root.iter("object") if o.get("id")}
template_class = root.find("template").get("class")
for setter in root.iter("setter"):
    if setter.get("object") not in ids:
        errors.append("breakpoint setter references unknown object '%s'" % setter.get("object"))
for b in list(root.iter("binding")) + [p for p in root.iter("property") if "bind-source" in p.attrib]:
    tgt = b.get("bind-source")
    if tgt and tgt not in ids and tgt != template_class:
        errors.append("binding references unknown object '%s'" % tgt)
for look in root.iter("lookup"):
    tgt = look.text.strip() if look.text else None
    if tgt and tgt not in ids and tgt != template_class:
        errors.append("expression lookup references unknown object '%s'" % tgt)

print("XML well-formed: OK  (%s)" % path)
print("classes:", ", ".join(sorted(classes)))
print("kgx-internal classes (checked against the kgx binary instead):",
      ", ".join(sorted(c for c in classes if c.startswith(CUSTOM))))
for n in notes:
    print("NOTE:", n)
for e in errors:
    print("ERROR:", e)
print("RESULT:", "FAIL" if errors else "PASS")
sys.exit(1 if errors else 0)