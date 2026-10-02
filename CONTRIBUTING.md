# Contributing

Thanks for helping keep a good piece of hardware out of the landfill.

## Setup

No build step. Clone, then:

```
python3 tests/test_dial.py        # no dial or display needed
ruff check . && ruff format --check .
shellcheck install.sh bin/surface-dial-setup bin/surface-dial-bar scripts/pair-dial.sh
```

Install `ruff` and `shellcheck` from your package manager or `pip`.

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
