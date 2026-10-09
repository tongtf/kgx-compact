# Upgrading Console

Console ships a GtkBuilder template compiled into the binary as
`/org/gnome/Console/kgx-window.ui`. `G_RESOURCE_OVERLAYS` can replace that one resource,
so no patching of Console itself is needed — but the replacement has to be regenerated
whenever Console is upgraded, because the template's internals are not a stable API.

That is what `tools/kgx-patch.py` is for: the overlay is **derived** from the pristine
upstream template plus a declarative list of edits, rather than maintained by hand.

## The normal path

```sh
pacman -Syu                 # Console gets upgraded
tools/kgx-patch.py dump     # extract the new pristine templates
tools/kgx-patch.py build    # regenerate the overlay from them
tools/kgx-verify.py all        # confirm
```

`dump` refuses nothing and always succeeds. `build` is where the version check lives: if
the templates you dumped do not match the Console that is installed, it stops and tells
you to re-dump, so a stale dump can never produce a stale overlay by accident.

## When Console changed its window template

`build` never guesses. Each edit asserts the structure it expects, and the first one
that does not match aborts the whole run without writing anything:

```
ERROR: upstream template no longer has the AdwHeaderBar child of KgxFullscreenBox;
       upstream changed
```

That means someone changed the layout. Work through it like this:

1. **Read the diff.** `diff` the newly dumped `upstream/kgx-window.ui` against the
   previous one (keep a copy, or rely on git).

2. **Check whether an edit is now unnecessary.** Several possible:
   - `decorated` already set upstream → drop `edit_decorated`.
   - the title buttons no longer bind to `fullscreened` → re-read what they bind to now.
   - upstream already shows `new_tab_button` when narrow → drop `edit_breakpoint`.

3. **Check whether the compact strip still fits.** If the header bar gained a control you
   still want, add it to `overlay/compact-tab-bar.ui.xml` as another `<child>`. Keep
   exactly one top-level `<object>` — that file is a fragment, not a builder file.

4. **Re-check the id contract.** Upstream references `tab_bar`, `tab_button`,
   `new_tab_button`, `primary_menu_popover` and `theme_switcher` from the breakpoint
   setters and from `AdwTabOverview`'s `inverted` binding. `build` compares the ids the
   upstream tab bar defines against the ones the strip defines and fails if the strip is
   missing any, so a rename upstream is caught rather than silently breaking the overlay.

5. **Verify, then look at it.**

```sh
tools/kgx-verify.py all
```

`kgx-verify.py` covers three things: the overlay's version stamp matches the installed
Console, the overlay type-checks against GTK4 and libadwaita, and the stylesheet parses
and matches. None of that replaces looking at the terminal, but it catches everything
that can be caught without a screen.

## Why the version stamp exists

`~/.local/share/kgx-overlay/.supported-major` records which Console major the overlay was
built for. `kgx-compact` compares it against the running binary and, on a mismatch,
**starts stock Console and prints why** rather than applying a mismatched template:

```
kgx-compact: overlay NOT applied (overlay is built for Console 51, installed is 52);
starting stock Console (title bar visible)
```

A partial port therefore degrades to "title bar came back", never to a broken terminal.

## Why a GNOME Shell extension cannot do this

Worth stating because it is a natural guess. A Shell extension runs inside gnome-shell
and can only see windows, not other processes' widgets. kgx is a client-side-decorated
app: its `AdwHeaderBar` is drawn by GTK inside the kgx process, so GNOME Shell never
drew a title bar and there is nothing at the compositor layer to remove.

Mutter 51 agrees — introspecting the typelib directly:

```
Meta.Window members matching "decor" : []
Meta members matching "decor"/"toggle": []
```

There is no `decorated` property and no undecorate call in the extension API at all.
Changing the widget tree requires being inside the process, which is exactly what the
resource overlay does.

## Why CSS cannot do it either

Not for the title bar. `AdwHeaderBar` keeps its height regardless:

| rule | resulting header bar height |
| --- | --- |
| (none) | 47px |
| `min-height: 0` | 47px |
| `min-height: 0; opacity: 0` | 47px |
| `min-height: 0` on header bar *and* its buttons | 47px |

CSS *is* used here, for cosmetics only. GTK4 also has no `display` property, so
`display: none` is a parse error, not a way out.