# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Omarchy** layout: a card in the same visual language as Omarchy's own OSD, following the shell theme.
- `--version` and `--help` on the daemon.
- Optional systemd user unit (`systemd/surface-dial.service`) that restarts the daemon on failure.
- CI: ruff, shellcheck and the test suite, on Arch.
- `SECURITY.md`, `CONTRIBUTING.md`, issue templates, `.editorconfig`.

### Changed
- `install.sh` now restarts what it updated: it offers to restart the daemon and the shell, because replacing files does not change what is already running (the shell keeps an old `DialMenu.qml` until restarted). It also offers to start the daemon if it is not running.
- Installs with `omarchy plugin add <git-url>`: a root `manifest.json` makes the repo a plugin Omarchy accepts, without moving any files.
- `install.sh` shows its plan and asks once (about two prompts where it used to ask eight in the same environment), uses `omarchy-pkg-add`, and recognises the `omarchy plugin add` layout.
- Settings open from the Omarchy menu (Setup > Surface Dial) instead of a `SUPER+SHIFT+CTRL+D` chord. Bind `omarchy-shell dialtools toggle` yourself if you want a key.
- On-screen messages use `omarchy-notification-send` where available (`notify-send` stays as a fallback).
- The dial's input loop no longer blocks on subprocesses: tool actions run on an ordered worker, and focused-window lookups use Hyprland's socket instead of spawning `hyprctl` (3.6 ms to 0.03 ms per lookup).
- Rotation speed uses the kernel's event timestamps, so a stall can't be mistaken for a fast spin.
- A failing tool action is logged instead of crashing the daemon.
- Per-detent logging needs `DIAL_DEBUG=1`.
- Carousel: one animated position drives every card, removing the icon pop and keeping the row width constant on every frame.
- `active_tools` and `tools` changes now apply live, while the dial is idle. No daemon restart.
- Python sources are ruff-formatted; shell scripts are shellcheck-clean.

## [1.0.0]

Initial public layout: daemon, Quickshell plugin with four faces (Pie Wheel,
Gauge, Carousel, Minimal Toast), Surface Pen support, doctor/setup script,
Rise bar widget installer, udev rules and test suite.
