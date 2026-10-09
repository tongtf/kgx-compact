# kgx-compact

[![CI](https://github.com/tongtf/kgx-compact/actions/workflows/ci.yml/badge.svg)](https://github.com/tongtf/kgx-compact/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Run GNOME Console (kgx) with no window title bar and a slim tab strip, without patching
Console itself.

The stock kgx window is an `AdwHeaderBar` (title, close/maximise/minimise, find, new
tab, menu) with the tab bar underneath. This replaces both with one compact strip and
tells the compositor not to decorate the window, so nothing is drawn above the terminal.

## How it works

Console builds its window from a GtkBuilder template compiled into the binary as
`/org/gnome/Console/kgx-window.ui`. GIO can replace a single compiled-in resource
without touching the rest of the binary:

```
G_RESOURCE_OVERLAYS=/org/gnome/Console=~/.local/share/kgx-overlay
```

`kgx-compact` is a launcher that sets that variable and then execs the real `/usr/bin/kgx`.
The overlay is a `kgx-window.ui` in which the header bar is gone and `decorated` is
`False`. Cosmetics (blending the strip into the terminal) live in the GTK4 user
stylesheet, not in the overlay.

## Quick start

Requires GNOME Console 51+, GNOME, Python 3 and GTK4.

```sh
git clone https://github.com/tongtf/kgx-compact.git
cd kgx-compact
./install.sh
gsettings set org.gnome.desktop.applications/terminal exec "$HOME/.local/bin/kgx-compact"
```

Open a new terminal. `install.sh --print-plan` shows what it would do and writes nothing;
`install.sh --uninstall` removes it, leaving your own CSS rules alone.

## Layout

| path | role |
| --- | --- |
| `install.sh` | per-user installer / uninstaller, no root |
| `overlay/compact-tab-bar.ui.xml` | the compact strip, as a fragment |
| `tools/kgx-patch.py` | extracts the pristine upstream templates and **generates** the overlay from them |
| `tools/kgx-verify.py` | runs every check |
| `tools/check-overlay.py` | type-checks the overlay against GTK4/libadwaita |
| `tools/check-css.py` | parses the stylesheet with the real GTK4 parser |
| `tools/verify-css-match.py` | resolves each CSS selector against real widgets |
| `src/kgx-compact` | the launcher |
| `src/gtk.css` | the stylesheet |
| `pkg/PKGBUILD` | optional Arch packaging |
| `tests/run.sh` | the test suite |

Installed layout:

| path | role |
| --- | --- |
| `~/.local/bin/kgx-compact` | launcher; point your terminal setting here |
| `~/.local/share/kgx-overlay/kgx-window.ui` | the generated overlay |
| `~/.local/share/kgx-overlay/.supported-major` | Console major it was built for |
| `~/.local/share/kgx-compact/upstream/` | pristine templates, for diffing |
| `~/.config/gtk-4.0/gtk.css` | managed block appended — your own rules preserved |

## The overlay is generated, not hand-edited

This is the part that matters for longevity. The overlay could be maintained by hand, but
it has to be redone on every Console upgrade, and hand-edited copies rot quietly. Instead
`kgx-patch.py` derives it from the pristine template plus four declarative edits:

1. `decorated=False` on the `KgxWindow` template — no compositor title bar.
2. `show-start/end-title-buttons = False` on `AdwTabOverview` — no window control buttons.
3. `AdwHeaderBar` + `AdwTabBar` replaced by `compact_tab_bar`.
4. The narrow-window `AdwBreakpoint` also shows the new-tab button, since no header bar
   is left to hold it.

Every edit **asserts the structure it expects to find**. If a Console release moves things
around, `build` exits non-zero, names what did not match, and writes nothing — rather than
emitting an overlay that parses but does the wrong thing. It also checks that the strip
still defines every id upstream references from its breakpoint setters and bindings, so a
rename upstream is caught instead of silently breaking the window.

```sh
tools/kgx-patch.py dump    # after a Console upgrade
tools/kgx-patch.py build
tools/kgx-verify.py all
```

More detail, including what to do when an edit genuinely stops applying, is in
[docs/UPGRADING.md](docs/UPGRADING.md).

## Failure behaviour

The overlay is version-pinned. On a mismatch the launcher starts stock Console and says
so, rather than applying a template from a different release:

```
kgx-compact: overlay NOT applied (overlay is built for Console 51, installed is 52);
starting stock Console (title bar visible)
```

A half-finished port degrades to "the title bar came back", never to a broken terminal.

## Tests

```sh
./tests/run.sh
```

23 checks, all against a throwaway `$HOME`; the real installation is never touched.
They cover the fragment, the generator (including that it refuses a changed upstream
template and writes nothing when it does), version-stamp mismatch detection, installer
idempotency and uninstall correctness, and the CSS checkers.

The CSS checkers are themselves tested against deliberately broken input, because the
failure they exist to catch is silent: a selector that matches nothing parses perfectly
and does nothing. `verify-css-match.py` builds the real widget tree and resolves each
selector against it, and `tests/run.sh` asserts it rejects a typo'd node name.

## Packaging

Tested in CI on Arch, Ubuntu and Debian. The package installs the files and nothing
else — it does **not** touch any user account and enables nothing. Run the per-user
installer yourself afterwards, then follow the `gsettings` command it prints.

This is deliberate on both families: `G_RESOURCE_OVERLAYS` and the GTK4 user stylesheet
are per-user, and the generated overlay is pinned to the Console version installed on
that machine, so a global enable would be wrong.

Neither package is in a public repository; that needs someone who maintains one.

### Arch

```sh
pkg/build-release.sh          # -> /tmp/kgx-compact-release/{tarball,PKGBUILD}
cd /tmp/kgx-compact-release && makepkg -si
kgx-compact-install
```

### Debian / Ubuntu

```sh
pkg/build-release.sh          # autodetects; pass "debian" to force it
cd /tmp/kgx-compact-release/kgx-compact-1.0.0 && dpkg-buildpackage -b -us -uc
sudo dpkg -i ../kgx-compact_1.0.0*.deb
kgx-compact-install
```

`build-release.sh` reads the version from `pkg/PKGBUILD` and cross-checks it against
`debian/changelog`, refusing to build if they disagree. `tests/run.sh` also asserts that
both recipes install the same set of tools, so adding a tool to one and forgetting the
other fails the build rather than shipping a half-installed package.

## Requirements

**GNOME Console 51 or newer.** This is a hard floor, not a preference: the overlay is
patched against the window template that ships in 51, and `kgx-patch.py` deliberately
*refuses* to patch a template it does not recognise. On anything older you get Console's
normal title bar and a refusal message explaining why, which is the intended behaviour.

Worth knowing if you are on Debian or Ubuntu: at the time of writing those ship GNOME 48
and 46 respectively, so the version-specific checks skip there and the overlay will not
apply. Nothing is broken — the tooling reports it plainly — but the feature needs Console
51+.

| | Arch | Debian / Ubuntu |
| --- | --- | --- |
| terminal | `gnome-console` **51+** | `gnome-console` **51+** |
| toolkit | `gtk4` `libadwaita` | `libgtk-4-1` `libadwaita-1-0` |
| introspection | `python-gobject` | `python3-gi` `gir1.2-gtk-4.0` `gir1.2-adw-1` |
| strings | `binutils` | `binutils` |
| headless display | `xorg-server-xvfb` | `xvfb` |

The launcher degrades gracefully if `strings` is missing, and the checkers need PyGObject
only to run — the overlay itself does not.

## Why not a GNOME Shell extension?

Natural guess, but structurally impossible. A Shell extension runs inside gnome-shell and
sees windows, not other processes' widgets. kgx is client-side-decorated: its title bar is
drawn by GTK inside the kgx process, so GNOME Shell never drew one. Mutter 51 exposes no
decoration API to extensions at all — introspecting the typelib gives an empty result for
both `Meta.Window` and the `Meta` module.

CSS cannot remove it either: `AdwHeaderBar` stays 47px tall under every combination of
`min-height`, `opacity` and `padding`. That is why the `.ui` overlay exists, and why CSS
here is cosmetic only. Details and measurements in [docs/UPGRADING.md](docs/UPGRADING.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The most useful contribution is almost always a
bug report, or help porting the overlay to a new Console release — see
[docs/UPGRADING.md](docs/UPGRADING.md). Please do not commit a generated overlay or
`upstream/`; both are rebuilt from the installed Console.

Security reports go through GitHub's private advisory flow; see [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).