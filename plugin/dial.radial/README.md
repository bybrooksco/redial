# Surface Dial radial menu

An on-screen tool menu for the Microsoft Surface Dial, as an Omarchy shell
plugin. Driven over IPC and a socket by the `surface-dial-hypr` daemon.

Four layouts, same data and same IPC — pick one from the settings window's
**Appearance** section (applies immediately, no restart), or set `layout`
(and `face`, for `dial`) by hand in `config.json`:

- **`dial`** — a radial instrument face, in one of four styles chosen by `face`:

  - **`classic`** (default) — the original instrument in a rectangular window.
    Horizontal labels on the circumference, concentric rings, sector spokes, a
    graduated bar scale, and an elbowed leader out to a callout column beside
    the dial. That column is why this face is landscape.
  - **`capsule`** — tools as radial pills on a round backing (below).
  - **`pie`** — full-bleed pie wedges, game-menu style (Overwatch/GTA-style
    weapon wheel). No rings, no scale, no callout — the wedge you're pointing
    at *is* the selection. Icon on every wedge; the hub carries the selected
    tool's name, value and click hint, the only text on the face.
  - **`gauge`** — tools laid across a 180° dome with a needle, like a car
    speedometer. The middle ground between Classic's density and Pie/Carousel/
    Toast's full minimalism: still reads as a precision instrument, without
    the rings/hairlines/callout column.

  The backing follows the face unless `plate` is set explicitly (`classic` →
  `rect`, `gauge` → `none` since it draws its own dome band, `capsule`/`pie`
  → `disc`).

  Note on `capsule` at small tool counts: the pills are laid out radially, so
  with five tools they sit far apart on a large circumference. `capsuleSpan`
  widens them to close the gaps, but the capsule keeps a fixed radial length,
  so pushing it far squares the shape off rather than lengthening the pill.

  Tools are **capsules arranged radially**
  around the rim: outline when idle, filled and enlarged when selected, with the
  label set on the capsule and the click action as a secondary line beside it. A
  thin leader runs from the centre to the selection. Round, with no rectangular
  frame.

  The interior rings each carry a different reading rather than decoration:

  | Ring | Carries |
  |---|---|
  | fine dash scale | rotation, the honest 0.1° readout; the selected sector takes the accent |
  | value arc | the active tool's value — drawn **only** when the tool has one, so its presence is itself information |
  | slot ticks | one per tool, marking the angular divisions |
- **`deck`** — a horizontal card rail along a screen edge, every tool the
  same size.
- **`carousel`** — a friendlier restyle of the same row-of-cards idea:
  fewer visual details, and the selected card is simply larger than every
  other one (not a continuous size falloff by distance — that would make the
  row's own width shift as the selection moves, which `carousel` avoids by
  construction: one large plus *n*−1 small card widths sums to the same
  total regardless of which tool is large).
- **`toast`** — the smallest footprint: one pill naming the armed tool (icon,
  name, click hint) plus a dot-pagination strip below it, the same idea as a
  phone's "3 of 6" onboarding screens. No needle, no ring, no per-tool
  layout math — the tradeoff is that it gives up the free "how far to the
  next tool" feedback every other layout/face shows just by being circular
  or ordered.

## Install

**New machine, or pairing a new dial?** Run `surface-dial-setup` first (no
arguments gives a doctor-style report; it prompts before changing anything).
It checks the pieces this README doesn't otherwise cover: `input` group
membership, the `70-surface-dial.rules` udev rule (hidraw + uinput
permissions), Bluetooth pairing, the daemon's Hyprland autostart entry, and
whether this plugin is enabled — all four of hidraw, uinput, BLE pairing, and
group membership have independently caused silent, hard-to-diagnose failures
on this project before, which is the whole reason the
script exists rather than leaving this as tribal knowledge.

Copy this directory to `~/.config/omarchy/plugins/dial.radial/`, then:

    omarchy-shell shell setPluginEnabled dial.radial true

User plugins are disabled by default, so a plugin can be *discovered and
listed* while its IPC target does not exist yet. If `omarchy-shell dialmenu
ping` says "Target not found", this is why.

Omarchy runs Quickshell with its file watcher disabled and restarts the shell
deliberately, so **editing the QML requires `omarchy-restart-shell`** — a plugin
rescan will not re-instantiate a `keepLoaded` panel. Handy check: the layer-shell
namespace (`hyprctl layers`) tells you which revision is actually live.

The daemon itself (`~/.local/bin/surface-dial-hypr`) is a separate file, not
part of this plugin directory; `surface-dial-setup` checks for it but does not
install it. Licensed MIT — see `LICENSE`.

## Configuration

Optional. Every value has a default in code, so the plugin runs correctly with
no config file at all.

    ~/.config/dial-radial/config.json

See `config.example.json` for the full document with defaults. The file is
watched, so edits apply live — no restart. A malformed file logs a warning and
falls back to defaults rather than taking the overlay down.

Colours accept `"theme"` (follow the Omarchy palette), a role name
(`accent`, `foreground`, `background`, `urgent`, `muted`), or a literal hex.
All colour resolution goes through one function in `Settings.qml`, which is the
only place coupled to Omarchy's palette.

## Shape and placement

`capsuleFillet` (0–1) is the corner fillet on the tool capsules, expressed as a
fraction of the largest radius the shape allows: `1` gives a stadium — a circle
if the capsule is square — and `0` a hard box. One continuous number rather than
a set of named shapes.

`plate` chooses the backing: `disc` (default), `none`, or `rect` (the older
rectangular plate with corner registration marks). `none` is the most minimal
but was measured to leave hairlines and labels unreadable over a terminal, so
the default is `disc`; switching is one config value, not a redesign.

`anchor` places the overlay — `bottom` by default. Both layouts honour it.

`size` scales the dial layout: `large` (the default and the original full size), `medium`
(0.75x) or `small` (0.55x). The overlay shrinks toward the edge or corner `anchor` pins it
to, so a smaller dial stays where you put it. Pick it in the tool-settings window (next
to Position) -- it applies immediately, no restart. The deck layout is not scaled.
Bottom matters for reach: on a large panel operated one-handed, the bottom edge
is the reachable one, and a centred overlay collides with the bar.

## Faces

`FaceClassic.qml`, `FaceCapsule.qml`, `FacePie.qml` and `FaceGauge.qml` are
peers behind a `Loader` (`DialMenu.qml`'s `faceFiles` map), sharing one
contract (`cfg`, `tools`, `index`, `position`, `live`) and everything outside
the face: settings, socket, IPC, plate, anchor, daemon. `carousel` and
`toast` are **not** faces — they're not circular, so the `dial` contract
(`angleOf()`, a square Canvas) would fight them rather than fit them; they're
two more top-level `layout` values instead, hardcoded directly in
`DialMenu.qml` next to `deck`, which was never a face either.

Faces are separate components rather than branches in one file because they
differ in geometry, in what the interior rings (if any) mean, and in where
the callout lives — gating that together would be a parallel implementation
tangled into a single scope. `FacePie.qml`/`FaceGauge.qml` reuse
`FaceCapsule.qml`'s/`FaceClassic.qml`'s exact `angleOf()`/needle-
interpolation math rather than re-deriving it — `FaceGauge.qml` is the one
exception, since its 180°-dome topology genuinely isn't the same problem as
a full circle. Adding a fifth face means adding a file, a `faceFiles` entry
and a `face` value; if the shared drawing keeps growing, hoist the common
helpers rather than copying them again.

## Tools

The tool set is data, not code, and lives in the daemon's `TOOL_LIBRARY`
(`~/.local/bin/surface-dial-hypr`) — eleven tools as shipped:

| Tool | Rotate | Click |
|---|---|---|
| Volume | volume up/down (speed scales the step) | mute |
| Windows | cycle windows | maximize |
| Workspaces | previous/next workspace | last workspace |
| Scroll | real wheel events (suppressed where they'd corrupt input) | — |
| Undo | redo / undo | — |
| Zoom | Ctrl+scroll | reset zoom |
| Media | **scrub** the playing media, 5 s per click, doubling with rotation speed | play/pause |
| Word Nav | word left/right | — |
| Arrow Keys | Up/Down, or Left/Right once toggled | flip axis |
| Window Size | grow/shrink the focused window 40 px per click | flip width/height |
| Brightness | screen backlight, 2 % per click (speed scales it), floor 1 % | — |

Window Size and Brightness are per-machine in practice: list them in `active_tools`
where they make sense (Brightness needs a backlight; with none it logs once and does
nothing). Changing which tools are active applies live: the daemon reloads the
list the next time the dial is idle (never mid-gesture, because the state machine holds a
tool index) and re-arms the default tool. The log says what it loaded.

Two ways to choose tools in `config.json`, checked in this order:

    { "active_tools": ["Volume", "Zoom", "Scroll", "Undo"] }

Pick and reorder from the built-in library by name — this is what the
**tool picker** panel writes. Open it with `SUPER+SHIFT+CTRL+D`, or
`omarchy-shell dialtools toggle` directly.

**Bar button.** A `bar-widget` entry point on this (local) plugin failed to load with a
`File name case mismatch` QML warning (backed out 2026-09-16), and Omarchy's stock bar
isn't the bar on machines running Quickshell Rise anyway (it hides the stock bar). So the
button is a Rise widget instead -- group `G19`, off by default, switched on under the
control panel's WIDGETS grid. Left-click opens this tool-settings window (same as the
hotkey); right-click restarts the dial daemon.
It is installed by `surface-dial-rise-widget` (the kit installer and `surface-dial-setup`
both run it), which patches Rise's V2 files with exact-match edits and refuses to write
anything if they don't match. Its status line comes from `surface-dial-bar`.

Active tools sit on a ring in their real dial order, drag one around the
circumference to reorder; the center is deliberately empty, matching the
actual dial's click/dictation zone rather than implying a tool slot that
doesn't exist. Inactive tools sit below as tap-to-add chips. It reads the
library itself from
`~/.config/dial-radial/tools.json`, which the daemon regenerates on every
startup — a tool added to `TOOL_LIBRARY` shows up in the picker automatically,
nothing to keep in sync by hand. With no `active_tools` key, every library
tool is active, in library order — unchanged from before this existed.

    { "tools": [ { "name": "Volume", "icon": "", "detent": 60, "magnitude": true,
                   "cw":    { "do": "volume", "direction": "up" },
                   "ccw":   { "do": "volume", "direction": "down" },
                   "click": { "do": "exec", "label": "mute",
                              "cmd": ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"] } } ] }

A full `tools` array replaces the library entirely with hand-authored specs,
same as before `active_tools` existed — for a custom tool the library can't
express. Wins over `active_tools` if both are present.

`detent` is dial counts per step; the device reports **3600 counts per
revolution**, so 60 counts is 6°. `magnitude` lets rotation speed scale the step
(1–4); leave it off for anything discrete, where "1.6 workspaces" is meaningless.

Two fields apply to the whole tool rather than one rotation direction:

| Field | Does |
|---|---|
| `continuous: true` | ignores `cw`/`ccw` entirely; every rotation event drives the virtual pointer directly instead of stepping on fixed detents |
| `hold_mod: "ctrl"` | holds that modifier for as long as the tool stays armed (a parked `wtype` process — see `press_mod`/`release_mod`), so a `continuous` tool's wheel events arrive as e.g. Ctrl+scroll |
| `gain` | hi-res wheel units per dial count for a `continuous` tool; defaults to `SCROLL_GAIN` |
| `invert: true` | flips which rotation direction is positive wheel motion, so `cw` can mean "increase" consistently even though the default (`Scroll`) has `cw` = wheel-down |

### Action vocabulary

| Verb | Fields | Does |
|---|---|---|
| `exec` | `cmd` (argv array) | runs a command |
| `hypr` | `lua` | Hyprland Lua dispatcher |
| `key` | `keys`, `repeat` | sends a key combo via `wtype`; `repeat` honours magnitude |
| `volume` | `direction` | built-in; magnitude is the percent step |
| `dictation` | — | toggles `voxtype` |
| `seek` | `direction` (`forward`/`back`), `step` (seconds) | scrubs the playing MPRIS player via `playerctl position`; the step doubles per rotation-speed step, so the tool needs `magnitude` |
| `resize` | `axis` (`x`/`y`), `direction` (`grow`/`shrink`), `step` (px) | resizes the focused window; points the delta at the edge that has a neighbour, so grow always grows |
| `brightness` | `direction` (`up`/`down`), `step` (percent), `device` | backlight percent × magnitude, clamped 1–100; names the device explicitly |
| `wheel` | — | marks a `continuous` tool; the virtual pointer drives it |
| `none` / `null` | — | nothing |

Any action may carry `label`, which is what the overlay shows as the click
action. An unknown verb or a malformed spec is logged and becomes a no-op — a
typo costs you one action, never the daemon.

**Hyprland 0.56 replaced string dispatchers with a Lua API.** `"cyclenext"` is
parsed as Lua and fails, and `hyprctl` still exits 0, so the failure is only
visible in its output. Use `hl.dsp.window.cycle_next()`. Reference:
`/usr/share/omarchy/default/hypr/bindings/`.

## Click gestures

Single, double and triple click each run an action you choose, in `config.json`:

    { "clicks": { "single": "tool", "double": "dictation", "triple": "enter" } }

Those are the defaults. Options: `tool` (single only — the armed tool's own click),
`dictation`, `enter`, `escape`, `backspace`, `space`, `tab`, `mute`, `play_pause`,
`next_track`, `prev_track`, `maximize`, `none`. The list comes from the daemon
(`~/.config/dial-radial/clicks.json`, written at every start), so the settings window
never hardcodes it. Pick them in the settings window's **Clicks** section — click a chip
to cycle, right-click to go back.

The daemon re-reads `clicks` whenever `config.json` changes, so an edit applies on the
next click with no restart. Things to know:

- To tell a double from a triple, a double click waits 0.25 s for a possible third press,
  so its action fires that much later. Set `triple` to `none` and there is nothing to wait
  for: double click is instant again.
- Overriding `single` replaces the tool's own click, so Arrow Keys and Window Size can't
  flip axis while it is overridden.
- An unusable value (unknown name, `tool` on double/triple) is logged and falls back to
  the default for that gesture.

## Surface Pen

Pen support shares this daemon and is on by default; it is harmless with no pen
attached, since the watchers simply find no device. For a dial-only install:

    { "pen": { "enabled": false } }

## Environment overrides

    DIAL_DEVICE=/dev/input/event27    force a specific dial node
    STYLUS_DEVICE, PEN_KBD_DEVICE     same, for the pen
    DIAL_MENU_LAYOUT, DIAL_MENU_ANCHOR   one-off overlay overrides

Two devices can legitimately share an evdev name — a real dial and a virtual one
used for testing — and the by-name search takes whichever comes first. The name
check still runs, so an override can only select a device that really is what it
claims to be.

## IPC

    omarchy-shell dialmenu open '{"tools":[{"icon":"","name":"Volume","hint":"mute"}],"index":0}'
    omarchy-shell dialmenu highlight 2
    omarchy-shell dialmenu layout dial|deck
    omarchy-shell dialmenu anchor bottom|center|top-left|...
    omarchy-shell dialmenu close
    omarchy-shell dialmenu state

Tool objects take `icon`, `name`, `hint` (the click action), and optionally
`value` (0-100) and `valueText` for a live readout.

A second, independent IPC target is the tool picker settings screen (see
Tools above) — separate from the dial overlay above since it opens/closes on
its own, not from dial rotation:

    omarchy-shell dialtools toggle
    omarchy-shell dialtools open
    omarchy-shell dialtools close
    omarchy-shell dialtools state

## Continuous rotation

`open`/`close` go over IPC, but rotation does not: the dial emits ~100 events a
second and every `omarchy-shell` call spawns a process. The plugin instead hosts
a socket at `$XDG_RUNTIME_DIR/dial-radial.sock` and the daemon streams:

    pos <float>\n

Position is in **tool units** — `1.5` means exactly between tools 1 and 2 — so
the needle angle and the selected index derive from one number and cannot
disagree. The needle is a rotation on an `Item`, never a canvas repaint, so the
scale is drawn once and only redrawn when the selection changes.

The socket is optional. If nothing is listening the daemon logs it and the
needle steps per detent instead.

## Known issues

### Scroll corrupts the input line in Claude Code (open, 2026-08-29)

Selecting **Scroll** and turning the dial over a Claude Code terminal walks its
prompt history and destroys whatever is typed.

The Scroll tool emits genuine `REL_WHEEL_HI_RES` through the virtual pointer,
which is correct. The damage happens downstream: Claude Code runs in **foot** on
the alternate screen, and foot's `alternate-scroll-mode` translates wheel events
into **Up/Down key events** while the alternate screen is displayed. The arrows
the daemon stopped sending are re-synthesized by the terminal.

**Do not "fix" this in `foot.ini`.** `alternate-scroll-mode=no` sets only foot's
*initial* value, and the `claude` binary contains `\e[?1007h` with no matching
`\e[?1007l` — the application turns the mode back on at runtime. The config
change appears to do nothing, for a reason that is not visible from the config.

The fix belongs here, keyed on the focused window class: `focused_class()`
already exists in the daemon and the eraser drag path already consults
`ERASER_SCROLL_CLASSES` at touch-down. The dial's Scroll tool consults nothing.
Open question is what Scroll should send *instead* over `org.omarchy.agent` —
suppressing wheel stops the damage but leaves the transcript unscrollable, which
is a real loss on a machine where stylus and single-finger touch cannot scroll.

Until then: do not select Scroll over an agent terminal.

**General shape of this class of bug:** a wheel event is only pointer-following
until something downstream converts it back to keys. Any terminal on the
alternate screen is a candidate, so a per-class guard is the durable answer
rather than a fix aimed at one application.

## Prior art

Microsoft discontinued the Surface Dial. [daniel5151/surface-dial-linux]
(https://github.com/daniel5151/surface-dial-linux) is the existing Linux
userspace daemon, in maintenance mode per its author. This is an independent
implementation and shares no code with it.
