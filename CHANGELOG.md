# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Legible on every theme.** The settings window's text colours are now computed from the active theme and adjusted only as far as needed to reach 4.5:1 contrast (WCAG AA), including text on the accent colour. Before, 19 of the 22 shipped Omarchy themes fell short somewhere (catppuccin-latte and rose-pine as low as 2:1). Tested against all 22 palettes.
- **Restart dial service** button: when the settings window finds the daemon is not running it offers a button that runs the new `surface-dial-restart` (also usable from a terminal).
- **First-run welcome card** on the Look page: three sentences on turn, click and hold, with Got it / More help. Shown once (`intro_seen` in the config).
- **Help page** in the settings window (third tab): what turn, click, hold and the menu do, and where to look when something is wrong.
- **Speak the tool name** (`announce_tool`, Feel page): says the tool aloud as you arm it or move through the menu, using `spd-say` or `espeak-ng` if installed. Off by default. Tested with stubs only; not yet heard on real hardware.
- **Reduce motion** (Feel page, `reduce_motion`): the dial display stops sliding, scaling and fading. Every animation now uses one of three speeds (120, 160, 260 ms) instead of nine different ones from 100 to 260.
- **Settings window is operable from the keyboard.** Every control is now a shared `Pressable`: Tab and Shift+Tab move between them, Enter or Space press, Shift+Enter or right-click go the other way (the click-action pickers also take Left/Right), and a focus ring shows where you are. Escape closes the window, and it takes keyboard focus when it opens. Tool-ring items can be moved with Left/Right and removed with Delete. Controls tell screen readers their role, name and state. No target is smaller than 32 px (the pen toggles were 22), and the ring's faint "click" label is now readable. If the content is taller than the screen it scrolls. Tested headlessly (`tests/qml`); **not yet tried with a real screen reader**.
- **Status line** in the settings window: Connected (with battery %), asleep ("click it to wake it"), or "dial service is not running". The daemon writes `~/.config/dial-radial/status.json` every few seconds (state, battery from Bluetooth, version, heartbeat); a stale file means the daemon is down.
- **Ignore small turns** (`deadzone`, Feel page): a tremor and bump filter. After a pause the dial must turn a set distance before anything registers; back-and-forth shake cancels out and never gets through, and a real turn is released whole. Off by default.
- **Tap menu** (`menu_latch`, Feel page > Tool menu): the tool menu can be opened by holding until it appears and then letting go; turn to choose and click to select, with no need to hold while turning. An untouched tap menu closes by itself without changing the tool (`menu_timeout_ms`, 3 to 12 s). The default is unchanged (hold, turn, release).
- Six optional tools, off by default so the ring is unchanged: **Focus** (Tab / Shift+Tab, click = Enter, so any dialog can be driven by the dial alone), **Tabs**, **Select**, **Pages**, **Tile Focus** and **Move Window**.
- Eleven new click actions for the dial and the pen buttons: `launcher` (Omarchy menu), `screenshot`, `copy`, `paste`, `cut`, `select_all`, `redo`, `tab_next`, `tab_prev`, `fullscreen`, `float`. `copy` and `paste` are terminal-aware (Ctrl+Insert / Shift+Insert, so they never interrupt a program); detection uses the `terminal` tag Omarchy puts on terminal windows.
- The daemon now keeps its own log at `~/.local/state/surface-dial/daemon.log` (256 KB, one rotation). Started the Omarchy way its stderr is `/dev/null`, so there was no record of connects, disconnects or errors. `surface-dial-setup` shows where it is.
- **Feel settings**, live and clamped, in `config.json` and a new **Feel** page of the settings window: `sensitivity` (0.5-2), `auto_return_s` (3-300 s, default 6; Zoom capped at 10 s because it holds Ctrl), `return_buzz`, `double_click_ms` (150-600), `hold_ms` (200-1500). Defaults unchanged.
- The settings window is now two pages, **Look** and **Feel**, so it stays shorter than before (it does not scroll). `omarchy-shell dialtools page look|feel`.
- **Omarchy** layout: a card in the same visual language as Omarchy's own OSD, following the shell theme.
- `--version` and `--help` on the daemon.
- Optional systemd user unit (`systemd/surface-dial.service`) that restarts the daemon on failure.
- CI: ruff, shellcheck and the test suite, on Arch.
- `SECURITY.md`, `CONTRIBUTING.md`, issue templates, `.editorconfig`.

### Changed
- `install.sh` now offers the shell restart after the plugin changes even if the shell is not answering at that moment (it used to skip it silently, leaving the old QML running).
- Settings window: the header text was stale (it described a checklist and a daemon restart); it now describes the drag ring and the Save step. The title is "Surface Dial", matching the menu entry. Helper text contrast raised from 4.4:1 to 5.3:1 on a white-on-black theme.
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
