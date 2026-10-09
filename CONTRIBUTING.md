# Contributing

Thanks for looking. This is a small project with a narrow purpose, so the most useful
help is usually a bug report or a fix for something that broke.

## What this project is

Console builds its window from a GtkBuilder template compiled into its binary as
`/org/gnome/Console/kgx-window.ui`. GIO can replace that single resource, so removing
the title bar needs no patch to Console itself.

The overlay is **generated**, not hand-written: `tools/kgx-patch.py` extracts the
pristine template from the installed Console and applies four declarative edits, each of
which asserts the structure it expects. That matters because Console releases every six
months and its internal layout is not a stable API.

## Reporting a problem

Console 51+ on GNOME. Please include:

```sh
tools/kgx-patch.py probe            # per-edit verdict against the installed Console
```

```sh
kgx --version                     # which Console
tools/kgx-verify.py all              # what the checkers say
```

and say which of these you hit:

- **The title bar is back.** Usually the version stamp no longer matches after an
  upgrade. `kgx-compact` prints the reason on stderr when it starts; paste that line.
- **The strip looks wrong** (leftover hairline, odd spacing). A description of what you
  see, plus your `src/gtk.css` if you changed it.
- **`kgx-patch.py build` refused.** Paste the full output. The refusal message names the
  element it expected and did not find, which is usually enough to diagnose.
- **Asking whether an older Console can be supported.** Run `kgx-patch.py dump` then
  `kgx-patch.py probe` on that release; the per-edit verdicts say exactly which parts
  would need new work. Known results: 51 works, 48 partially (edits 2 and 3 do not
  apply), 46 not at all (no `<template>` element in this shape).
- **Console will not start.** This would be a bug in the overlay. Include the stderr
  from launching it directly:
  ```sh
  G_MESSAGES_DEBUG=all ~/.local/bin/kgx-compact 2>&1 | head -50
  ```

## Porting to a new Console release

This is the most likely thing to need help with, and the docs walk through it:

1. `tools/kgx-patch.py dump`
2. `tools/kgx-patch.py build`
3. `tools/kgx-verify.py all`

If `build` refuses, read [docs/UPGRADING.md](docs/UPGRADING.md) — it explains what each
edit asserts and what to do when an edit is no longer needed. Please open an issue even
if you work it out yourself, so the next release is handled.

## Pull requests

- Keep the generated overlay **out** of pull requests. `upstream/` is gitignored and
  rebuilt by `dump`; committing it would only create conflicts.
- If you change `overlay/compact-tab-bar.ui.xml` or the edits in `tools/kgx-patch.py`,
  add or update the matching check in `tests/run.sh`. The checkers are the only thing
  standing between a plausible-looking change and a silently broken window.
- Run `./tests/run.sh` first. It needs no display for most of it and skips what it
  cannot do, so it is safe to run anywhere.
- Do not reformat unrelated code. The overlay diffs are already hard enough to read.

## Two things that will silently do nothing

Both have caught people out, including me:

- **A CSS selector that matches nothing** parses perfectly and does nothing. Use
  `tools/verify-css-match.py`, which resolves selectors against real widgets.
- **GTK4 has no `display` property.** `display: none` is a parse error, not a way to
  hide a widget. `AdwHeaderBar` also cannot be collapsed by CSS at all — its height
  stays 47px — which is why the structural change needs the `.ui` overlay.

## Adding a packaging recipe for another distribution

`pkg/PKGBUILD` is the reference. Note that the package installs nothing and enables
nothing on its own: `G_RESOURCE_OVERLAYS` and the GTK4 user stylesheet are both per-user,
and the overlay is pinned to the installed Console version, so a global enable would be
wrong on any distribution.