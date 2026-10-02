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
- Carousel: one animated position drives every card, removing the icon pop and keeping the row width constant on every frame.
- `active_tools` and `tools` changes now apply live, while the dial is idle. No daemon restart.
- Python sources are ruff-formatted; shell scripts are shellcheck-clean.

## [1.0.0]

Initial public layout: daemon, Quickshell plugin with four faces (Pie Wheel,
Gauge, Carousel, Minimal Toast), Surface Pen support, doctor/setup script,
Rise bar widget installer, udev rules and test suite.
