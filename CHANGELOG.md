# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Dial | Pen tabs** at the top of the settings window. The Dial keeps its pages (Look, Feel, Every setting, Help); the Pen tab holds the Surface Pen controls, moved off the Feel page and grouped by how you use them: away from screen (tail button), on screen while hovering (barrel button), and on screen in contact (eraser).
- `pen.eraser_scroll_speed` (0.25 to 4, default 1): scales every app's eraser scroll speed. On the Pen page as Slow, Normal, Fast and Faster.

- **Desktops other than Omarchy.** `install-generic.sh` installs the daemon on KDE Plasma, GNOME/Ubuntu, COSMIC, plain Hyprland, Sway or niri (a systemd user service, the udev rule and the `input` group, each sudo step asked), and `--uninstall` removes it. `docs/PLATFORMS.md` says what works on each.
- Key actions (Zoom, Undo, Text, Pages and every `key` click) go through a uinput virtual keyboard on desktops without a window backend (GNOME, KDE, COSMIC) or wherever `wtype` is missing, since `wtype` needs a Wayland protocol those desktops don't offer. Hyprland, Sway and niri keep `wtype`. `DIAL_KEYS=uinput|wtype` overrides. Checked live on COSMIC (Pop!_OS 24.04): the compositor picks up the device. Tested in `tests/test_dial.py` (`UinputKeys`).

- **`redial-overlay`**, the tool ring on desktops without Omarchy (COSMIC, KDE Plasma, Sway, plain Hyprland). Three styles, chosen with `overlay_style`: **Menu** (every tool by name, the selected one marked ❯, the default), **Card** (the Omarchy layout's one line: icon, name, one segment per tool) and **Strip** (a status-bar row). It uses the desktop's own colours and monospace font (COSMIC theme files, KDE `kdeglobals`, or the GTK theme) and picks up a theme change on the next hold. The daemon sends it the same calls it sends Omarchy's overlay, over the existing socket. `install-generic.sh` installs it when gtk-layer-shell is present. GNOME has no layer-shell, so the ring shows as notifications there. Tested in `tests/test_overlay.py` and `tests/test_dial.py` (`OverlaySocket`).
- **`redial-settings`**, a small settings window for desktops without Omarchy: which tools are on the ring, and the ring's style. It keeps every other key in `config.json`, re-reads the file before saving, and won't write over a config it can't read. `install-generic.sh` adds it to the app launcher as "re:dial settings", and the Settings tool opens it. Tested in `tests/test_settings.py`.
- **Waybar module** for desktops without Omarchy: `redial-bar` (status, battery and click summary; left-click opens settings, right-click restarts the daemon), with the block to paste in `config/waybar.snippet.jsonc`.
- The default ring leaves out the tools that can't act on this desktop: on GNOME, KDE and COSMIC, the window tools (no window backend yet) and Settings when no settings window is installed. `tools.json` says which tools work here (`works_here`), and the settings window greys the rest.
- Without Omarchy, holding the dial names each tool you pass in a notification, so the ring is never invisible.

### Fixed
- Dictation no longer reports success when it failed. The "voxtype toggled" notice used to appear even when voxtype was not running (for example, its GPU driver failed to load after a kernel update). `run()` now returns whether the command worked, and a failed toggle shows "Dictation unavailable". Tested in `tests/test_dial.py` (`DictationNotice`).
- The haptics were silently off on machines where another package's udev rule claims every hidraw device (Vial's `99-vial.rules` does): the dial's rule now uses `:=`, so it can't be overridden.
- Notifications through `notify-send` (any desktop without Omarchy) now replace each other instead of stacking.
- Eraser scroll started late. A drag now locks its axis after about 2 mm instead of 5 mm, and the travel before the lock is replayed, so the page moves from the first millimetre. A touch that never locks an axis is still a tap.
- The first eraser scroll after the daemon started was slow: the virtual pointer is now created at startup, not on first use.

## [0.9.0] - 2026-10-23

### Added
- **re:dial classic**, the standard design language, and the layer structure behind it: a language is a folder in `plugin/redial/languages/` (`Language.qml` plus one file per look), selected with `language`; unknown or broken languages fall back to `classic`. The contract for adding a language or a look is in `plugin/redial/languages/README.md`.
- `color_scheme`: `light` (the new default, ink on vellum), `dark`, or `theme` (match the desktop theme, read from Omarchy's `colors.toml`). It fills four colour roles (ground, line, accent, alert) in `ColourScheme.js`; a theme colour that does not reach 3:1 on the background falls back to a readable one. `colors.accent` still overrides the accent. Tested in `tests/qml/tst_colourscheme.qml`.
- `reference_lines` (default `true`): one switch for the construction lines, crosshair and registration marks.
- A title block on the Classic plate showing the tool's place on the ring (`SHEET 3/8`).
- The overlay draws three states itself in re:dial classic, instead of handing them to Omarchy's OSD: **turning** a tool with the ring closed (the scale lit to the level with a dimension arc and figures; at most ~10 updates a second), **hints** from the introduction (a revision cloud with the gesture to make and, on the guided tour, the step), and **can't act** (section hatching and a status: a tool with nothing to act on, or the dial dropping within 5 s of use). They travel as `turn`/`hint`/`cant` lines on the existing socket; when the overlay is not listening, or the chosen look does not draw them yet, they go to Omarchy's OSD exactly as before. Tested in `tests/test_dial.py` (`OverlayNotes`) and `tests/qml/tst_notes.qml`.

- **Settings** tool: picked from the ring it opens the settings window, then turning walks its controls and a click presses one, so the dial can set itself up. Its keys go only to that window (closed, a turn or click opens it again). It is a tool, so a shared machine can leave it off the ring.
- **Every setting** page in the settings window: every key re:dial reads (`plugin/redial/schema.json`), grouped and searchable, with its key, default, range and a Reset; lists and objects open `config.json` in your editor. Tests fail when a key the daemon reads, or one in `config.example.json`, has no row, or when a range disagrees with the daemon's clamp.
- Colour (Light, Dark, Match desktop), Reference lines and Design language on the Look page.
- **Style** on the Look page: swatches for the accent, ink and ground colours (Auto, the theme's roles and its 16 slots, stored as theme references so a theme switch re-colours the dial), Backing strength, Line weight (Fine, Normal, Bold), Scale density (Low, Medium, High) and the six drawing elements. Controls the chosen appearance does not draw are greyed. These were a fly-out in one bar; now everyone sets the dial in the same place.
- `tool_return_s`: return-to-Volume time for one tool. Scroll, Pages and Settings stay armed at least 60 s, never less than `auto_return_s`.
- Windows names the window you land on, and Media shows the playing position and title, on the overlay (or the OSD).

### Changed
- The colour scheme now colours every face and layout (except `omarchy`) and the settings window, not only Classic; `colors.*` left at `"theme"` follow it.
- The settings window is drawn in re:dial classic: square corners, hairline outlines, uppercase section labels, an underlined current page and a sheet title block.
- The default ring (no `active_tools`) is Volume, Windows, Workspaces, Scroll, Undo, Zoom, Media, Settings, plus Brightness only where there is a backlight. Arrow Keys and Window Size moved to the library. Rings saved from the settings window are unchanged.
- The settings window is a normal window: it opens floating and centred at 960x720 (install.sh adds one Hyprland rule for it, and uninstall.sh removes it), and can be moved, resized and Alt-Tabbed to. Its layout follows its width: narrow, one column as before; wide, the ring sits beside the Look controls and Every setting shows its groups two across. The ring and settings are separate windows again, so the daemon closing its ring never touches settings. The Settings tool sends keys only while the settings window has focus.
- Tool ring changes in the settings window apply at once, like every other setting; the Save button is gone. Before, closing the window without Save quietly dropped them.
- Click actions (dial, pen tail, eraser, barrel; Feel page and Every setting) show their place ("4 OF 32") and open a list of every action grouped by where it helps (typing and dictation, pointer, editing, web and windows, sound and media, open); Left and Right still step through.
- The settings window shows when there is more to scroll: a scroll bar, and the content fades into the edge with "MORE BELOW".
- Help has four setups: browse the web, point and click, dictate, run the computer.
- **Clicks for one tool** (`tool_clicks`): any tool can have its own single, double and triple click; each falls back to the tool's own default, then to the clicks for every tool. "Tool's own click" can sit on any of the three. Set on the Feel page. Tested in `tests/test_dial.py` (`PointerTools`).
- **Text** replaces Word Nav and Select: turning moves a word at a time, a click flips to selecting, a double click copies. **Scroll** takes over H Scroll: a click flips it sideways. Rings saved with the old names load the new tools. The library is 18 tools.
- **Pointer clicks**: click is a left click, double click flips left-right / up-down, triple click is a right click (was: click flipped the axis and nothing pressed the button).

- The Classic look is redrawn in re:dial classic (`languages/classic/Classic.qml`, replacing `FaceClassic.qml`): the lit sector turns with the hand as a pre-drawn layer instead of repainting all 180 bars on every detent, the leader eases between tools, the chosen glyph grows by transform, labels and callout keys are a step darker, and its colours come from the colour scheme. Construction lines are now on by default.
- Opening and closing: the overlay fades in over 120 ms and out over 100 ms with stronger curves. `reduce_motion` still removes all sliding and scaling but keeps that short fade.
- Every look's position comes from one helper, `Placement.js` (it was pasted five times; audit finding 6). Tested in `tests/qml/tst_placement.qml`.

### Fixed
- A dial that wakes with clicks working but turning dead now has a way out: the **Reconnect dial** click action (`reconnect_dial`, in the picker under The dial) drops its Bluetooth link, and the next press reconnects it. Seen once (2026-10-23): Bluetooth and the input device both looked fine, the dial just sent almost no turns; the self-heal, which covers a dial with no input device at all, could not see it. The log now records how many turns arrived before the first press after each reconnect, so it leaves evidence.
- "cannot open ... Permission denied" is no longer logged on every reconnect: the daemon retries for about a second while udev sets the new device's permissions, and only a failure that outlasts that is logged.
- `colors.accent`, `colors.line` and `colors.background` now recolour every look, Classic included; they were only read by some faces, and Classic took only a six-digit accent.
- With the settings window open, the overlay no longer stops showing levels and notes.
- Media scrubbed one player and play/pause hit another: the player was chosen by app name (`-p firefox` is whichever Firefox player comes first, so YouTube in one tab and Jellyfin in another were mixed up) and the click went to playerctl's default player. Turning, clicking and the readout now share one player, chosen by MPRIS instance; nothing playing says so on screen instead of guessing.
- Scroll over Claude Code in an ordinary terminal (foot > bash > claude) no longer walks its prompt history: the guard now checks the focused window's processes, not only the `org.omarchy.agent` class.
- Classic's leader no longer crosses the dial: for tools on the left (such as Focus and Tabs) it follows the scale round to the right and leaves between two labels, and when the callout has to sit higher or lower than the leader's natural line (tools at the bottom) it runs round the scale to meet it. Its first line now sits on the leader.

## [0.8.5] - 2026-10-14

### Added
- Colours can be a theme slot, `color0` to `color15`: that colour of whichever Omarchy theme is active, so the dial re-colours when you switch themes. Works for themes that name their colours (`red`, `bright_blue`) and themes that number them, because it reads Omarchy's generated `alacritty.toml`. The parser is `plugin/redial/ThemeSlots.js`, tested in `tests/qml/tst_themeslots.qml`.
- Self-heal for a dial that Bluetooth reports connected but that never became an input device (BlueZ handed the kernel an empty HID map). After 12 s the daemon drops the link so the dial reconnects on its next touch, backing off 30 s, 2 min, then 10 min. Logged as `self-heal:`.
- A test that an old-name Rise widget is renamed on upgrade.
- `docs/BETA-GUIDE.md`: what testers need, hardware basics, what to try, and how to report.

### Fixed
- Upgrading from the Surface Dial beta left the Rise bar widget calling the removed `surface-dial-bar`. `install.sh` now refreshes an already-installed widget.

### Changed
- `.coverage` is no longer tracked. The roadmap and BETA.md now describe the rename and the in-place upgrade.

## [0.8.4] - 2026-10-11 (renamed to re:dial)

### Changed
- **The project is now re:dial.** "Surface Dial" and "Surface Pen" remain the names of the hardware it works with; the software, its commands and its files are re:dial.
  - Commands: `surface-dial-hypr`, `-setup`, `-restart`, `-bar`, `-rise-widget` are now `redial-hypr`, `redial-setup`, `redial-restart`, `redial-bar`, `redial-rise-widget`.
  - Plugin: `dial.radial` is now `redial` (`~/.config/omarchy/plugins/redial`). Settings live in `~/.config/redial/`, logs in `~/.local/state/redial/`, backups in `~/.local/share/redial-backups/`.
  - Menu: Setup > re:dial. Udev rule: `70-redial.rules`. Systemd unit: `redial.service`.
  - Repository: `bybrooksco/redial`.
  - The kernel device names of the hardware (`Surface Dial System Multi Axis`, `Surface Touch Device Stylus`) are unchanged, and so are the Omarchy shell IPC targets (`dialmenu`, `dialtools`).

### Added
- **Upgrading from the Surface Dial beta (0.8.3 and earlier) is automatic.** `install.sh` stops the old daemon, moves your settings and learning progress to the new locations, backs up and removes the old commands and plugin, swaps the autostart line and menu entry, refreshes the Rise bar widget, and offers to replace the old udev rule. Nothing is deleted; old files go to `~/.local/share/redial-backups/`.

## [0.8.3] - 2026-10-11 (fixes and window-manager backends)

### Added
- **Window-manager backends (branch `compositor-backends`).** Tools now describe window actions as verbs (`{"do": "wm", "op": "workspace", "to": "+1"}`) and a backend carries them out for the running compositor. Hyprland is unchanged (it renders exactly the commands it always did); **Sway and i3** (`swaymsg` / `i3-msg`) and **niri** (`niri msg action`) backends are written from their documented command lines; any other desktop (GNOME, KDE, ...) gets a no-op backend that logs once, so Volume, Brightness, Media, Zoom, Scroll, Undo/Redo and the other key-based tools keep working and only the window tools are unavailable. Detected from the session's environment; `DIAL_WM=hyprland|sway|i3|niri|none` overrides. **Sway, i3 and niri are untested on a real session** until someone runs them there; the Quickshell overlay is still Omarchy-only. The old `{"do": "hypr", "lua": ...}` action still works on Hyprland.

### Fixed
- **Pen eraser pressed Escape while scrolling.** A scroll with the back of the pen often began with a 30 to 60 ms bounce of contact that counted as a tap. Touches shorter than 100 ms are now ignored, and the Pen settings gain an Eraser section: what a quick tap and a press-and-hold do (including "Nothing"), and how short a touch to ignore (`pen.eraser`, `pen.eraser_tap_min_ms`). Applies live.
- **Launchers were killed after 5 seconds** and held up the dial while they ran. Programs you open (launchers, the assistant) are now started and left alone.
- **Ctrl could stay held** if the dial dropped while Zoom was armed.
- **The settings window could overwrite a hand-edited `config.json`** that was caught mid-edit (a trailing comma), and a reload threw away unsaved tool edits. It now pauses writes with a banner until the file is readable again, and keeps unsaved edits.
- Scroll on Sway, i3 and niri no longer starts a process per knob event (the focus lookup is cached for 150 ms).
- The pairing script stops scanning as soon as it finds the dial.

### Security
- The daemon's files are private to your user (0600, folders 0700). The overlay socket has no `/tmp` fallback. The CI token is read-only. SECURITY.md states the rules for downloaded themes and packs.

## [0.8.2] - 2026-10-11 (teaching styles)

### Added
- **Three ways of teaching the dial**, chosen with `onboarding_mode` (Feel page, "How hints teach"): `adaptive` (as before), `discover` (a hint to press and one to hold, nothing more) and `guided` (a short tour on connect: turn, press, hold, close the ring, pick a tool, then a pointer to settings; a step nobody does is asked again after 20 s, up to three times, then skipped). All three share one `progress.json`, so changing style keeps what was already learned.
- **Per-tool hints** in adaptive and discover: the first time a tool is picked, one line about what turning it does; and if it is turned a while without a click, one line about what its click does. Each tool is taught once, only when it is tried, and progress per tool (steps, whether it was clicked) is saved for a later levels view.

## [0.8.1] - 2026-10-09 (first-run experience)

The first informal test (2026-10-08) showed that turning the dial for the first time did too little and that nobody reads a settings page. This version answers the first turn, teaches by what you do, and wakes faster.

### Added
- **The dial now answers on screen.** Each volume or brightness step shows Omarchy's own on-screen display with the new level (muted volume shows the muted icon). Before, turning the default tool changed the volume silently.
- **The first movement after a quiet spell is acknowledged** (3 seconds of stillness, or a connect or wake), even if the turn was too small to complete a step: the overlay shows the active tool, so a gentle first turn is never met with silence. Dead-zone twitches and menu turning do not trigger it.
- **Faster wake, and no polling.** The daemon used to check for the dial every 3 seconds while it was asleep or disconnected, and paused a second after a drop. It now sleeps until the kernel reports that the input device list changed (`DeviceWatch`, using `poll()` on `/proc/bus/input/devices`), so a reconnecting dial is noticed the instant it appears and an idle daemon uses no CPU. A device that is listed but not yet openable (permissions still being applied) is retried ten times at 0.1 s, then handled by a 2 second safety timeout. The Bluetooth reconnect itself is not under its control. The log now says how long the dial was away each time it attaches.
- **Move Window: click flips between workspaces and positions.** It still carries the focused window to the next or previous workspace; a click now switches to moving it around the current workspace, one position per step, by swapping it with the next or previous window in the workspace's order (so it passes through every position however many windows there are, like the Windows tool does for focus). The on-screen message says which mode you are in. A fresh arm always starts on workspaces.
- **On-screen display setting** (`osd`, Feel page, default on): the volume or brightness overlay and the first-turn tool name can be turned off for a cleaner screen. They are on by default because they are what makes the dial answer a new user, and they are handy for movies. Applies live.
- **Hints while you learn (the adaptive introduction, first version).** A small engine watches what the person does (steps, clicks, opening the tool menu, choosing a tool) and, when their behaviour shows they are ready, shows one short line on the on-screen display: press the dial (after ten steps of turning with no press), hold to choose a tool, how to finish choosing (when the menu closes without a change), and finally where the settings are. Each hint shows at most three times and never within 30 seconds of another; doing the thing makes it go away for good. Progress and plain usage counts are kept in `progress.json` next to the config, on this machine only. `guide` (Feel page: Hints while you learn) turns it off; it also stays quiet when the on-screen display is off. `surface-dial-hypr --reset-guide` starts the introduction again. It only watches: it never changes what the dial does.
- **A sleeping dial is noticed in about 25 ms, not seconds.** (Measured with a virtual dial that disappears and reappears: the daemon is listening again 23 ms after the device returns.) A repeated "cannot open" is logged once, not on every retry.
- **Brightness with no backlight says so** ("No screen backlight on this machine") instead of doing nothing.
- The beta notes and feedback sheet describe the hints and the new `progress.json` file.
- The connect message now says what turning does ("Surface Dial ready: Turn to change volume").

## [0.8.0] - 2026-10-07 (first beta package)

The build prepared for the first testers (first numbered 0.9.7, renumbered 0.8.0 on 2026-10-09 to match how far along the project really is). Not yet public; see `docs/ROADMAP.md` for what comes before 1.0.

### Added
- **Single-file installer** for testers: `scripts/make-installer.sh <ref> <out>` builds one file (about 220 KB, small enough to email) that contains the whole release. Running it checks its own checksum, shows a plain-language notice, unpacks to `~/.local/share/surface-dial-beta/` and then runs the normal `install.sh`, which asks before every change. The unpacked folder stays so `uninstall.sh` is available. `--extract-only` and `--unattended` for the careful and the scripted.
- **`FEEDBACK.md`**: a short sheet for testers (setup, eight things to try on day one, questions for after a few days).
- **Tool descriptions on hover.** Hover a tool in the settings window (the ring or the chips below it) and a short description appears: what turning does and what a click does. It also appears when a tool gets keyboard focus, and screen readers are given it as the control's description. Every tool now carries its description in its data (published in `tools.json`), so tools you define can have one too. `omarchy-shell dialtools tip <name>` shows one without a mouse.
- **`uninstall.sh`**: removes everything `install.sh` added (programs, plugin, start-at-login lines, menu entry), moving it to a backup folder first; keeps your settings unless `--purge`; asks before the one sudo step.
- The Help page ends with the version number, so a bug report can say which version it is about.
- **Pointer** tool (move the mouse with the dial, accelerating with speed; click flips the axis) and **H Scroll** (sideways scrolling). Both off by default. The virtual pointer now supports relative motion and the horizontal wheel.
- Click actions: **Left / Right / Middle click** (so the dial can press what Pointer points at), **Open a terminal / browser / files**, and **Quick assistant**, which runs the command you set in `assistant.cmd` (any AI or chat, local or hosted; no vendor assumed; changes apply without a restart).
- **`launchers`** in the config: your own click actions that run a command (up to 12).
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

## [0.6.0] - 2026-09-30

Initial layout as one package (never released; numbered retroactively on 2026-10-09): daemon, Quickshell plugin with four faces (Pie Wheel,
Gauge, Carousel, Minimal Toast), Surface Pen support, doctor/setup script,
Rise bar widget installer, udev rules and test suite.

## Earlier stages (numbered retroactively on 2026-10-09; none were released)

- **0.7** (10-02 to 10-03): public-launch polish. Lint and format clean, CI, docs, the Omarchy layout, input thread kept free of subprocesses, Omarchy conventions.
- **0.5** (09-26): Studio and laptop work merged, pen click settings, the two windows became one.
- **0.4** (09-19 to 09-22): second machine (Laptop Kit), bar button, Window Size and Brightness, triple-click, the Bluetooth "zombie connect" fix, audit and hardening.
- **0.3** (09-16 to 09-18): tool library and `active_tools`, Zoom, Arrow Keys, Media, Word Nav, the terminal scroll fix, setup doctor.
- **0.2** (08-29 to 09-15): first overlay plugin, Classic and Capsule faces, picker window, Scroll.
- **0.1** (08-20 to 08-28): bring-up. Pairing, HID and haptics reverse-engineering, first daemon.
