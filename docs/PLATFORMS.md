# Where re:dial runs

re:dial has two halves, and they reach different desktops:

- **The daemon** (`redial-hypr`): reads the dial and pen, drives the haptics, runs the tools. It
  needs only Python 3.10+ and the kernel's input devices, so it runs on any Linux desktop. It picks
  a window-manager backend by itself (`DIAL_WM` overrides it).
- **The overlay and settings window**: on Omarchy, a plugin for its shell. Elsewhere,
  `redial-overlay` draws the tool ring while you hold the dial, in one of three styles
  (`overlay_style`: `menu`, the default; `card`; or `strip`), in the desktop's own colours and
  monospace font. It reads COSMIC's theme files and KDE's `kdeglobals`, falls back to the GTK
  theme everywhere else, and picks up a changed theme on the next hold. It needs GTK 3 and
  gtk-layer-shell (`gir1.2-gtklayershell-0.1` on Ubuntu/Pop, `gtk-layer-shell` on Fedora/Arch).
  GNOME has no layer-shell, so there the ring shows as notifications. Levels and hints are
  notifications on every desktop except Omarchy. Outside Omarchy,
  `redial-settings` ("re:dial settings" in the app launcher) chooses the tools on the ring and the
  ring's style. Everything else is in `~/.config/redial/config.json`
  (`plugin/redial/config.example.json` lists every key).

**Install:** on Omarchy, `install.sh`. Anywhere else, `bash install-generic.sh`. It installs the
daemon as a systemd user service and asks before each sudo step. `--uninstall` removes it.

## Status

**Works** = checked on that desktop. **Expected** = the code supports it, nobody has tried it yet.
**No** = missing.

| | Omarchy | Hyprland (no Omarchy) | Sway / i3 / niri | KDE Plasma | Ubuntu (GNOME) | COSMIC |
|---|---|---|---|---|---|---|
| Dial input and haptics | Works | Expected | Expected | Expected | Expected | Expected |
| Volume, media, brightness | Works | Expected | Expected | Expected | Expected | Expected |
| Scroll and Pointer (uinput) | Works | Expected | Expected | Expected | Expected | Expected |
| Keys: Zoom, Undo, Text, Pages | Works (`wtype`) | Expected (`wtype`) | Expected (`wtype`) | Expected (uinput) | Expected (uinput) | Device picked up (uinput)¹ |
| Window and workspace tools | Works | Expected | Expected, untested | No² | No² | No² |
| Tool ring overlay | Works | Expected (`redial-overlay`) | Expected (`redial-overlay`) | Expected (`redial-overlay`) | Notifications | See below³ |
| Settings window | Works | `redial-settings` (tools and style) | `redial-settings` | `redial-settings` | `redial-settings` | `redial-settings` |
| Bar widget | Works | Waybar module | Waybar module | No (Plasma panel)⁴ | No | No (COSMIC panel)⁴ |
| Pen tail button and eraser | Works (Studio 2+) | Expected | Expected | Expected | Expected | Expected |
| Installer | `install.sh` | `install-generic.sh` | `install-generic.sh` | `install-generic.sh` | `install-generic.sh` | `install-generic.sh` |

1. 2026-11-01, on the tower (Pop!_OS 24.04, COSMIC): the uinput keyboard was created and
   `cosmic-comp` opened it. Nobody has typed into an app with it yet.
2. Each desktop has its own way to move windows (below). On these desktops the window tools log
   "not available here" and do nothing. The other tools are unaffected.
3. `redial-overlay` is written for COSMIC first. It is filled in once it has been seen there.
4. `redial-bar` is a Waybar module (`config/waybar.snippet.jsonc`). Plasma's and COSMIC's own
   panels need their own applets. Until then, open "re:dial settings" from the app launcher.

## How keys are sent

There are two ways to send keys, and the daemon picks one by itself:

- **`wtype`** sends key *names* through a Wayland protocol (virtual-keyboard). Letters come out
  right on any keyboard layout. Hyprland, Sway and niri support that protocol. GNOME does not.
  KDE offers it only in recent versions and may block it. COSMIC's support is unconfirmed.
- **A uinput virtual keyboard** ("re:dial Virtual Keyboard") sends key *codes* from the kernel, so
  every desktop sees it like a real keyboard. The cost: letters follow the physical QWERTY
  position, so on an AZERTY layout `z` types `w`. The shortcuts re:dial ships (Ctrl+Z, Ctrl+C,
  arrows, Page Up/Down, Enter) are mostly unaffected by layout.

uinput is used on GNOME, KDE and COSMIC, or anywhere `wtype` is missing. `DIAL_KEYS=uinput` or
`DIAL_KEYS=wtype` forces one. A key name the uinput table doesn't know falls back to `wtype`.

## Desktop profiles

### KDE Plasma (6.x; Kubuntu, Fedora KDE, KDE neon, Arch)

- **Keys:** uinput, as above.
- **Window tools (next step):** KWin has no command-line window control, but it runs JavaScript
  sent over D-Bus (`org.kde.KWin /Scripting loadScriptFromText`). `kdotool` and `wdotool` work
  this way, using `workspace.activeWindow` and `workspace.windowList()` on Plasma 6. A KDE backend
  would do the same. Needs KWin 5.22+.
- **Overlay:** Quickshell runs on KWin (it uses layer-shell), but the overlay needs Omarchy's shell
  modules too. Notifications go through Plasma's own notifier.
- **Packages (Kubuntu/Ubuntu names):** `python3`, `bluez`, `wireplumber`, `playerctl`,
  `brightnessctl`, `libnotify-bin`.

### Ubuntu (GNOME, 24.04 LTS and later)

- **Keys:** uinput. GNOME has no virtual-keyboard protocol, so `wtype` can't work there at all.
- **Window tools (next step):** GNOME gives outside programs no window control on Wayland.
  `org.gnome.Shell.Eval` is locked unless GNOME runs in unsafe mode, and switching that on would
  be a security hole. The supported way is a small GNOME Shell extension that offers the few
  actions re:dial needs over D-Bus. That is a separate piece to write, install and keep working
  across GNOME releases.
- **Python:** 24.04 ships 3.12, which is new enough.
- **Packages:** same as KDE. `/dev/uinput` usually exists, and the udev rule gives the `input`
  group access.

### COSMIC (Pop!_OS 24.04, Fedora COSMIC, Arch `cosmic` group)

- **Keys:** uinput. Checked: COSMIC picks up the device.
- **Window tools (next step):** no command-line tool yet. COSMIC's compositor offers the standard
  window-list protocols (ext-foreign-toplevel, plus COSMIC's own for workspaces), which a client
  speaking Wayland could use. That is more work than KDE. COSMIC also added EI (emulated input)
  and a remote-desktop portal in 1.6/1.7, another route for keys later on.
- **Session:** `graphical-session.target` is active on Pop!_OS 24.04, so the systemd user
  service starts at login.

## Test plan for a desktop that isn't Omarchy

Run on the tower (COSMIC) first, then on a KDE and an Ubuntu live USB. Copy each result into the
table above, with the date.

1. `bash install-generic.sh`, accept the sudo steps, log out and back in.
2. Pair the dial: `bash scripts/pair-dial.sh`.
3. `~/.local/state/redial/daemon.log` should say `window manager backend: none`,
   `virtual keyboard created` and `attached`.
4. Turn: volume changes and the haptic clicks are felt.
5. Edit `active_tools` in `~/.config/redial/config.json` and try Scroll, Media, Zoom (in a
   browser), Text (in a text editor) and Pages.
6. Turn the dial off and back on: does it reconnect by itself?
7. Note anything that fails without a message. Those cases matter most.
8. `bash install-generic.sh --uninstall`.

## Sources

- [KWin scripting over D-Bus, as used by wdotool](https://docs.rs/crate/wdotool/0.1.6/source/README.md)
  and [kdotool](https://docs.rs/crate/kdotool/latest/source/src/lib.rs)
- [Virtual keyboard protocol and which compositors support it](https://wayland.app/protocols/virtual-keyboard-unstable-v1)
- [GNOME Shell Eval locked behind unsafe mode](https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/7298ee23e91b756c7009b4d7687dfd8673856f8b/js/ui/shellDBus.js),
  [and the extension route instead](https://discourse.gnome.org/t/terminal-command-to-open-app-drawer-and-switch-between-applications/8226)
- [COSMIC 1.7: EI and the remote-desktop portal](https://blog.desdelinux.net/en/Cosmic-1.7-arrives-with-support-for-scalable-cursors-and-remote-control-via-Steam-input/)
- [Quickshell install options per distribution](https://quickshell.org/docs/v0.3.0/guide/install-setup)
