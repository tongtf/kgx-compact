# Security policy

## Scope

kgx-compact is a handful of shell and Python scripts and one XML file. It does not run as
a service, open a socket, or run any elevated code. It sets one environment variable for
a process it starts and writes to a few files under the invoking user's home directory.

The files it writes:

| path | what |
| --- | --- |
| `~/.local/bin/kgx-compact` | launcher script |
| `~/.local/share/kgx-overlay/kgx-window.ui` | generated GTK builder template |
| `~/.local/share/kgx-overlay/.supported-major` | version stamp |
| `~/.local/share/kgx-compact/` | copies of its own files, plus dumped upstream templates |
| a delimited block in `~/.config/gtk-4.0/gtk.css` | the stylesheet |

`./install.sh --uninstall` removes all of those and leaves anything else alone. Nothing
outside `$HOME` is touched, and the installer needs no root.

## What to report

Please report a vulnerability privately via GitHub's "Report a vulnerability" button on
the Security tab rather than opening a public issue.

Worth reporting:

- anything that writes outside `$HOME`, or to a path not listed above
- anything that executes input derived from a downloaded file or another user's data
- the installer doing something other than what `--print-plan` said it would
- `--uninstall` deleting or modifying a file the user owns

## Trust boundary worth understanding

The overlay is **GTK builder XML**, and `G_RESOURCE_OVERLAYS` makes Console load it in
place of its own compiled-in template. It is trusted code inside your own Console
process — equivalent in kind to editing Console's own resources. The upstream templates
it is generated from come from the `kgx` binary already installed on your system.

The practical consequence: only install an overlay you have read, and be no more relaxed
about `~/.local/share/kgx-overlay/kgx-window.ui` than about the Console binary itself.
`tools/kgx-patch.py build` prints what it is about to write, and `kgx-verify.py overlay`
will tell you whether the result matches the installed Console.

## Supported versions

Only the newest released Console is supported at any time, because the overlay is
regenerated per release. Run `tools/kgx-verify.py overlay` to check whether your overlay
still matches; a mismatch is reported, not silently applied.