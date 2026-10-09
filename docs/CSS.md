# Managing the GTK4 user stylesheet

`~/.config/gtk-4.0/gtk.css` is **global to every GTK4 application on the system**. It is
not a per-application file, and it is very likely to already contain rules of your own.

kgx-compact therefore never overwrites it. It writes a delimited block:

```css
/* >>> kgx-compact (managed block, do not edit inside) >>> */
   ...our rules...
/* <<< kgx-compact <<< */
```

and the installer, on every run:

1. removes any existing block (including one you hand-edited),
2. writes the current `src/gtk.css` as a fresh block,
3. leaves every other byte of the file untouched.

So the managed block is regenerated, not merged — treat it as read-only. Put your own
GTK4 tweaks outside the markers and they will survive every install and uninstall.

## Why the strip is not a system-wide concern

`@window_bg_color`, `@accent-color` and friends are GTK4 named colours that Adwaita
defines. Using them keeps the strip correct in both light and dark mode. The only value
CSS cannot reach is the terminal background, because that is a VTE palette colour chosen
by Console's theme setting rather than something the style engine knows about. To pin
it explicitly, replace `background: none` with a literal:

```css
window.terminal-window .compact-tab-bar { background: #1e1e1e; }
```

## Editing the styles safely

Two failure modes matter, and both are silent in a running terminal:

- **A typo'd property or value** is dropped by the parser with only a log message.
- **A selector that matches nothing** parses perfectly and does nothing at all.

Hence the two checkers:

```sh
tools/check-css.py        src/gtk.css   # real GTK4 parser: bad property/value
tools/verify-css-match.py src/gtk.css   # real widgets: selector actually matches
```

`verify-css-match.py` builds the same widget tree that `kgx-window.ui` builds and
resolves each selector against it. It catches the mistakes that look like working CSS.

Two traps worth knowing, both found the hard way:

- Inside `AdwTabBar`, use the **descendant** combinator. The `.box` and the tab box are
  wrapped in a `GtkRevealer`, so `tabbar > .box` never matches; it must be
  `tabbar .box`.
- GTK4 has no `display` property (`display: none` is a parse error) and no
  `max-height`. `opacity`, `min-height`, `padding` and `box-shadow` do work — but none of
  them can collapse `AdwHeaderBar`, whose height stays pinned at 47px. That is why
  removing the title bar needs the `.ui` overlay and cannot be done from CSS.

## If you would rather not use a stylesheet at all

The structural work (no title bar, compact strip) lives entirely in the overlay. The
stylesheet is cosmetic. Delete the managed block and the terminal still runs borderless;
the strip just keeps Adwaita's default header-bar background and bottom hairline.