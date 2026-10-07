# Contributing

Thanks for helping keep a good piece of hardware out of the landfill.

## Setup

No build step. Clone, then:

```
python3 tests/test_dial.py        # no dial or display needed
coverage run --include=bin/surface-dial-hypr tests/test_dial.py && coverage report --fail-under=60   # CI's floor (currently 67%)
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml   # keyboard/accessibility of Pressable; headless (note: /usr/bin/qmltestrunner is the Qt 5 one)
ruff check bin/surface-dial-hypr bin/surface-dial-rise-widget scripts/add-menu-entry.py tests
ruff format --check bin/surface-dial-hypr bin/surface-dial-rise-widget scripts/add-menu-entry.py tests
shellcheck install.sh bin/surface-dial-setup bin/surface-dial-bar scripts/pair-dial.sh
```

These are exactly what CI runs. (`ruff check .` alone would skip the daemon: ruff only
walks `.py` files, and `bin/surface-dial-hypr` has no extension.) Install `ruff` and
`shellcheck` from your package manager or `pip`.

## Debugging

`DIAL_DEBUG=1` logs every detent and press. The tests set `DIAL_CONFIG_DIR` to a
temporary directory so importing the daemon never touches your real config; set it
yourself if you import the daemon in a script.

## Working on the QML plugin

After editing QML, run `omarchy-restart-shell`. In testing on Omarchy 4.0.4 the
shell logged "Local plugin changed, reloading" but kept running the old
`DialMenu.qml`, so a change can look like it did nothing, or worse, look like it
worked when it didn't. Drive the overlay without a dial with
`omarchy-shell dialmenu open '<json>'` and `omarchy-shell dialmenu highlight N`.

## Ground rules

- **Tests pass and lint is clean** before a PR. CI checks both.
- **Test what you change.** The daemon's decisions (gestures, tools, config) are
  tested without hardware; add a test next to the existing ones. Feel on the real
  dial can't be tested, so say how you checked it by hand.
- **Per-machine config stays per-machine.** Nothing in this repo may overwrite
  `~/.config/dial-radial/config.json` once it exists.
- **Keep installs non-destructive.** Anything that edits a file outside this repo
  asks first and backs the original up.
- **Small and plain over clever.** Prefer a short function to a new abstraction.

## Reporting bugs

Open an issue with your Omarchy/Hyprland version, `surface-dial-hypr --version`,
and the daemon log. For permission or "dial not found" problems, run
`surface-dial-setup` first and paste its output.

By contributing you agree your work is released under the MIT license.
