# Design notes

Why the daemon and plugin behave the way they do. The code carries short
functional comments; the reasoning, measurements and the bugs that shaped each
decision live here. Dates are when a decision was made or measured.

- [Interaction model](#interaction-model)
- [Stepping](#stepping)
- [Haptics](#haptics)
- [Menu highlight alignment](#menu-highlight-alignment)
- [Held modifier (Zoom)](#held-modifier-zoom)
- [Scroll routing](#scroll-routing)
- [Pen buttons](#pen-buttons)
- [Eraser](#eraser)
- [Tool history](#tool-history)
- [Click gestures](#click-gestures)
- [Input loop and threads](#input-loop-and-threads)
- [Fit with Omarchy](#fit-with-omarchy)
- [Overlay window](#overlay-window)
- [Config bindings](#config-bindings)
- [Faces and layouts](#faces-and-layouts)
- [Settings window](#settings-window)

## Interaction model

The dial rests in a safe default tool (Volume). Rotating at rest only changes
volume: harmless, reversible and audible. Other tools are armed deliberately
and disarm themselves after a few seconds of stillness, so nothing stays armed.
Volume is index 0 and is the idle home.

How long "a few seconds" is is `auto_return_s` (default 6 s, which is what the project has used since the
first version; range 3-300 s, read live). It is also the first setting added specifically because the
default can be too short for someone using the dial with limited reach or effort. Tools that hold a
modifier (Zoom's Ctrl) are capped at 10 s whatever the setting says: while one is armed, every key typed
in another app carries that modifier, so "never" and "a long time" are deliberately not offered.

A continuous, scroll-wheel-driven Zoom was tried and removed in early
development; it earned nothing and made the dial feel loose.

## Stepping

The detent is constant per tool. The angle you turn per click never changes,
so the rhythm under your hand is uniform and predictable. Rotation speed scales
the magnitude of each step instead (a fast spin moves 4 volume points per click,
not 1), which is how a good jog wheel behaves. Scaling the angle instead makes
the feel shift while you turn, which reads cheap.

Speed is measured as counts accumulated over a fixed window, not from the gap
between consecutive events. The dial emits several rotation events sharing one
timestamp, so a per-event dt collapses toward zero and the computed speed
explodes (observed: 3.7M counts/sec on a device that tops out near 1600). That
pinned magnitude at its ceiling on every turn.

## Haptics

The dial has no mechanical detents; the clicks are a motor driven over hidraw.
Measured 2026-08-28: clicks stay individually countable down to about 100 ms
apart, and the three waveforms are not distinguishable by feel.

There is no intensity control on this device. HID usage 0x23 is absent from the
descriptor. Every distinction is therefore built from pulse count and spacing,
expressed as `(repeat, retrigger_ms)` and handed to the firmware in a single
write. Meaning is carried by rhythm, not waveform.

## Menu highlight alignment

Found in real use on 2026-09-30: the overlay's highlight and the actual pick
could disagree ("the previous tool, not the one I meant").

The daemon only increments `menu_pick` once `menu_accum` reaches a full
`MENU_STEP`, but `menu_accum / MENU_STEP` alone ranges up to ±1.0. `Math.round()`
on the QML side, which turns the streamed position into a highlighted tool, was
therefore flipping to the next tool at the halfway point of a detent, half a
detent before `menu_pick` itself moved. Dividing by `2 * MENU_STEP` keeps the
fraction within ±0.5 of `menu_pick`, so the highlight and the real pick cross
the boundary at the same instant.

Related: the position socket (ordered, low-latency) already drives which icon
is highlighted once it is live. The per-detent IPC `highlight` call is a
fire-and-forget subprocess with no ordering guarantee against it, and under
fast rotation a stale one landing late flickered the highlight to the wrong
tool. It is skipped while the stream covers it, which is also correct and saves
spawning a process per detent.

## Held modifier (Zoom)

`wtype`'s docs say modifiers are released automatically once the program
terminates. So a modifier can be held across many separate scroll events by
keeping one `wtype` process alive (pressed, then parked in a long sleep) and
killing it to release.

This is a real stuck-key risk if the daemon dies uncleanly while a tool holds
one. Both a normal-exit path (`atexit`) and SIGTERM release it. SIGKILL can
still leak the `wtype` child; `pkill wtype` recovers that by hand.

## Scroll routing

Wheel-based scroll (the dial's Scroll tool and the pen's eraser drag both go
through `scroll_mode()`) breaks in exactly one known situation, not in
"terminals" generally. foot's alternate-scroll-mode (DECSET 1007) converts wheel
motion into Up/Down key events only for an app that has both switched to the
alternate screen and asked for that fallback itself. A bare shell prompt does
neither, so real wheel events sent there are already inert.

An earlier fix sent literal Up/Down directly to every terminal window class, on
the theory that it was more honest than relying on the conversion. That was
wrong and reintroduced the same bug against bash history instead of Claude
Code's prompt: window class alone cannot tell a bare prompt (arrows are history,
destructive) apart from a full-screen pager in the same class (arrows are safe
navigation). Only an app that both opts into 1007 and binds the resulting
arrows destructively is actually broken. So far, only Claude Code.

The eraser drag uses the same routing, since `org.omarchy.agent` (Claude Code)
would otherwise hit the same bug via a drag instead of a rotation. The decision
is made once per touch, not per motion event.

## Pen buttons

**Tail button.** It reports as a keyboard over BLE, sending SUPER + F18/F19/F20.
Those keycodes sit in the F13–F24 range, which is not reliably present in xkb
keymaps, so a Hyprland binding on `SUPER + F20` never matches even though the
kernel delivers the key. Omarchy's own bindings file warns about this range. The
daemon reads it straight off the evdev stream, which needs no keymap.

**Defaults are chosen by accident risk, not convenience.** The pen sits in the
hand for hours, so the easiest control to brush gets the most harmless default,
and anything that commits needs deliberate effort:

| Gesture | Why | Default |
|---|---|---|
| single click | easy to brush | Space (costs nothing) |
| double click | needs intent | Enter (commits) |
| press and hold | assumed hardest to trigger, wasn't | Dictation |

Enter is on the double click because a single click is far too easy to trigger
by accident while holding the pen, and Enter submits things. Escape lives on the
eraser tap instead: flipping the pen over cannot be done by accident, which is
what a disruptive key needs.

**Why hold defaults to Dictation.** The Omarchy menu was the original default,
on the theory that a hold was the hardest to trigger by accident. Real use on
2026-09-26 proved that wrong: the menu includes power and sleep entries, and a
hold was easy to trigger while just holding the pen normally. Dictation is
harmless to fire by accident (it toggles back off on the next press), so it is
the default rather than leaving every fresh install to rediscover the same bug.

**Barrel button.** Configurable (`pen.barrel`), bound globally and deliberately
not allowlisted. Right-click is the default because that is what a stylus
barrel is conventionally for (Krita's pop-up palette expects it), and the click
lands wherever hover has put the cursor, i.e. under the pen. A `mouse` action
keeps real press/release passthrough so a held barrel plus drag still works;
any other action type fires once on press only, for the same accident-risk
reasons as the tail button.

## Eraser

Dragging the stylus eraser on the screen scrolls, like a touch drag, but only
in an allowlist of window classes. The stylus is never grabbed, so the eraser
behaves completely normally everywhere else. Creative apps (Krita, GIMP,
Blender, Inkscape and others) are never matched, so their eraser cannot be
broken by this.

Gain is per class, because apps consume wheel events very differently: a
terminal moves in discrete lines (about 3 per notch) so it needs a big push to
feel responsive, while a browser treats hi-res events as smooth pixel motion
and the same gain sends it flying. The digitizer reports 18 units per mm.

The eraser's second level is duration, not pressure. The eraser end reports a
constant 2432 with zero tilt (measured 2026-08-28, 12 contacts), so there is no
pressure signal to threshold. A stationary contact is classified on release: a
quick tap is Escape, a hold is delete-word. Deciding at release needs no timer
and cannot misfire while the pen is still down.

## Tool history

- **Zoom** uses Ctrl+scroll held while armed, not Ctrl+=/-. Ctrl+=/- only
  changes editor font size in most apps. Obsidian's Graph, Canvas and embedded
  PDF/image views don't treat that as zoom and ignored it. Ctrl+scroll is the
  pinch-zoom convention those views listen for, and browsers already treated it
  as page zoom, so nothing that worked before regresses. Built for using the pen
  one-handed with no free hand for the keyboard, but not Obsidian-specific.
  A discrete Ctrl+=/- Zoom was added back once, then replaced the same day
  (2026-09-16) by this.
- **Media** scrubs rather than skips (2026-09-20): rotation moves the playhead of
  whatever is playing. Unlike track changes, "a bit further" is meaningful, so
  it takes magnitude and a fast spin jumps further. Detent is the standard 60
  for fine control (it was 150 when this skipped tracks). Next/previous track
  remain available as click-gesture options.
- **Arrow Keys** (2026-09-18) is plain single-line/character navigation, a
  sibling to Word Nav. Click flips between vertical and horizontal. The
  declarative do/cw/ccw vocabulary has no notion of state that persists between
  detents, so `axis_toggle` is handled directly in the `Dial` class
  (`arrow_horizontal`). cw/ccw hold the vertical default; horizontal overrides
  them at dispatch time rather than replacing them, so a bug in the override
  can't lose the tool entirely. No magnitude, same as Word Nav.
- **Window Size** (2026-09-20) resizes the focused window. Same click-flips-the-
  axis shape as Arrow Keys, but the alternate axis is data (`alt`). Clockwise
  always grows and counter-clockwise always shrinks; `resize_active()` works out
  which edge Hyprland must move for that to hold. No magnitude: a fixed step per
  detent keeps every click the same size.

## Feel settings and the two-page window

Five timings and thresholds that used to be constants are now live settings (`sensitivity`, `auto_return_s`,
`return_buzz`, `double_click_ms`, `hold_ms`), read through one shared reader (`live_config`) that re-reads the file
only when its mtime moves and validates every value the same way: numbers are clamped to a range, anything else is
the default. They exist because the defaults can be wrong for a particular person; the first one was added when a
user with limited reach found six seconds short, and the rest follow the same reasoning. Defaults are unchanged.

Details that are easy to get wrong: the release handler has its own "was this a hold?" check, separate from the one
that opens the menu, so it must use the same `hold_time()` or a press longer than 0.4 s but shorter than the setting
is swallowed; the window for a double click is used in three places (single click waiting, the second press, the
third press); sensitivity scales three things (tool steps, the menu step, continuous gain), each with a test that
fails if that one wiring is reverted. Tools that hold a modifier stay capped at 10 s (see Interaction model).

The settings window has no scrolling (its height is its contents), and the new rows would have made it taller than
before. So it is two pages, **Look** (position, size, appearance, the tool ring and its Save) and **Feel** (the five
rows, clicks, pen); each page is shorter than the old single page. Pages are shown by a `visible:` condition on the
existing sections, not by moving code, so the drag ring is untouched. `omarchy-shell dialtools page look|feel`
switches page without a mouse. Save appears only on Look, since tool changes are the only staged ones.

## Click gestures

Triple click exists for dictation: double click starts or stops recording, triple
click submits what it typed. To tell a double from a triple, a double click waits
`DOUBLE_S` for a possible third press before it fires. Set `triple` to `none`
and there is nothing to wait for, so a double fires instantly again.

The `tool` choice (single click only) runs the armed tool's own click action,
which is why it is the default there. Choices are re-read whenever `config.json`
changes, so the settings window applies them on the next click. The option lists
are published to `clicks.json` and `pen_clicks.json` at startup so that window
never hardcodes them.

## Input loop and threads

The main thread does one thing: read the dial, decide, and return. Anything that
can take time goes elsewhere, in order. This came out of a latency review of the
daemon (2026-10-02), with measurements.

- **Tool actions run on one ordered worker (`ACTIONS`).** An action is a
  subprocess or a Hyprland query. On the reading thread it stalls rotation for
  as long as it takes (about 4 ms per `wpctl`/`hyprctl` spawn). One worker keeps
  strict FIFO order, so `resize_active`'s read-then-dispatch stays sequential,
  and contains any exception an action raises (it used to propagate out of the
  read loop and kill the daemon). The queue is bounded at 64 and drops rather
  than blocks, because blocking is the thing being avoided. Magnitude and axis
  are decided on the input thread at submit time, so a queued action never
  depends on later state.
- **Haptics** already had their own thread and a small queue. The overlay socket
  is non-blocking and drops frames when the panel is behind.
- **The pen's watchers** are separate threads that block only themselves.
- **Focused-window lookups use Hyprland's own socket**, not `hyprctl`. The Scroll
  tool asks on every rotation event (up to about 100 a second). Measured: 3.6 ms
  per `hyprctl` spawn against 0.03 ms through the socket, with the same answer.
  It falls back to `hyprctl` if the socket is unavailable. On a 300-event spin
  the input loop spent 1124 ms blocked before and 12 ms after.
- **Events keep the kernel's timestamp.** The loop used to re-stamp each event
  with `time.monotonic()` when it read it, so any stall bunched buffered events
  into one instant and the speed estimate read that as a fast spin. The daemon
  now asks the kernel for `CLOCK_MONOTONIC` stamps (`EVIOCSCLOCKID`) and uses
  them. A timestamp in another clock domain, or from the future or distant past,
  is ignored in favour of the read time. Checked against a virtual input device:
  three events 50 ms apart read 150 ms later kept their 50 ms spacing.
- **Per-detent logging is off by default.** Set `DIAL_DEBUG=1` to log each detent
  and press; the journal otherwise gets one line every two seconds while rotating.

Considered and left alone: the idle loop wakes about four times a second
(measured 0.0% CPU over eight hours), events are read one per syscall (about 100
a second), and opening the Volume overlay still runs one `wpctl get-volume` on
the input thread. Moving the overlay's open/highlight/close onto the worker is
possible, but they would all have to move together or a close could overtake an
open and leave the overlay stuck up.

## Fit with Omarchy

A review against Omarchy's own conventions (2026-10-03), checked against the shipped
scripts on 4.0.4, not recalled from memory.

Changed because of it:

- **Installs like any other Omarchy plugin.** `omarchy plugin add <git-url>` clones the
  whole repo into `~/.config/omarchy/plugins/<id>/` and requires `manifest.json` at the
  repo root; this repo had it one folder down, so that command would have failed. A root
  `manifest.json` now points its `panel` entry point at `plugin/redial/DialMenu.qml`,
  so nothing moved. Checked with Omarchy's `omarchy-plugin-validate`, with a real
  `omarchy plugin add` in a scratch `HOME`, and by loading the nested layout in the
  running shell (overlay, Gauge face and settings window all rendered). The older layout
  (a copy of `plugin/redial` alone) still validates and is what `install.sh` makes
  when run from a plain clone. The validator forbids symlinks inside the plugin folder,
  and a test keeps it that way. `omarchy plugin update` is a `git pull`, so updating the
  plugin is one command too.
- **Settings live in the Omarchy menu, not on a chord.** Omarchy has a menu-extension
  file for exactly this. Its own default bindings use at most two modifiers plus ALT or
  CTRL; the old `SUPER+SHIFT+CTRL+D` came from a personal hub mapping. `install.sh` now
  adds Setup > re:dial through `scripts/add-menu-entry.py`, which edits the user's
  JSONC file without disturbing it, checks that the result still parses, and leaves the
  file untouched if not. A key is one line in `bindings.lua`, documented in the README.
- **Notifications go through `omarchy-notification-send`**, which 45 of Omarchy's own
  scripts use. `notify-send` is not in its base packages (it was only here as a
  dependency of other apps), so on a stock install the daemon's messages could have
  silently not appeared. The old call stays as a fallback. Replacing the previous
  message in place is kept via the notifier's `-r` id.
- **One consent, not ten.** `install.sh` shows its plan and asks once. The shell
  restart, the sudo steps and the Rise widget (which patches another project's files)
  are still asked about separately. Packages go through `omarchy-pkg-add`.
- **No PKGBUILD.** The plan was an AUR package, but Omarchy's convention is git-based
  plugins, and a system package can't write to `~/.config` anyway.

Already matching: autostart uses `launch_on_start` (the same `uwsm-app` launch Omarchy
uses at login); dictation calls `voxtype record toggle`, which is what Omarchy's own
binding calls; all runtime dependencies except `playerctl`, `voxtype` and a notifier are
in Omarchy's base package list.

Left for the maintainer, because they are taste or need a decision:

- **Names.** `redial-hypr` leaks an implementation detail; Omarchy's own commands
  read `omarchy-<noun>-<verb>`. Renaming breaks every existing install and autostart line.
- **The Rise installer** patches another project's files by exact-match anchors. It works,
  but it is the most fragile code here and serves a third-party bar. It belongs in
  `contrib/`, and the stock bar should get a supported bar button instead (the
  `bar-widget` kind failed to load in 2026-09; worth retesting on 4.0.x).
- **Options.** Seven appearances and 160 lines of config are a lot to ship as a default.
  Pick one default that looks native (the `omarchy` layout is the candidate) and let the
  rest be discoverable.

## Overlay window

`DialMenu.qml` owns one shared `PanelWindow` with a `mode` of `live` or
`settings` (merged 2026-09-26; before that they were two windows). `live` is the
tool-rail/radial overlay, driven by the daemon while the dial turns, and must be
fully click-through: the dial is the input device, so it can never eat a click
meant for the window underneath. `settings` is `ToolPicker`'s content, with real
mouse and keyboard input (IPC target `dialtools`, bar widget,
Omarchy menu entry). `mode` picks the content and the mask/focus policy.

The inactivity watchdog is scoped to the "popped up because you're using the
dial" case. A manual peek at the Live tab from Settings should sit there until
you leave it, like Settings itself.

The Live tab has no in-window way back to Settings, because it is click-through
by design. Returning goes through the same hotkey or bar widget as opening it.
That is a deliberate trade.

A one-time check still needs a human: open Settings, flip to Live, click an app
under where the overlay sits, and confirm the click lands there. If it ever
fails, the scoped fallback is two `PanelWindow`s sharing the same `mode` state.

## Config bindings

`anchor` and `layout` are deliberately not taken from the daemon's `open()`
payload (found and fixed 2026-09-30). Both already have a live binding to `cfg`,
which reads the same config file the daemon reads. Assigning them imperatively,
even to the right value, permanently replaces that binding with a static one.
The daemon validates `layout` against its own allowed-values tuple, so when that
tuple was stale (missing carousel and toast) it echoed back `dial` on every real
rotation, which froze `root.layout` at `dial` no matter what the settings window
wrote afterward. `cfg`'s binding is the single source of truth.

`ToolPicker` follows the same rule: it never assigns `root.anchor` directly,
because that is a binding off `configDoc`.

## Faces and layouts

- **Carousel** is a lower-detail restyle of the row-of-cards idea. It is not
  routed through the face `Loader`, because it isn't circular and the dial face
  contract (`angleOf`, a square `Canvas`) would fight it.
  Every card is driven by one animated scalar, `pos`. A card's weight is a "hat"
  function of its distance from `pos` (1 on the selection, 0 two or more cards
  away, linear between), and those weights always sum to exactly 1. So the row's
  total width is constant on every frame, even when the dial outruns the
  animation. Measured in the live shell: 47 frames through a fast spin including
  a wrap-around, row width 400.0 on all of them.
  The first version animated each card's width, glyph size and colour on
  separate timers and toggled the name label's `visible`. That jumped the icon
  vertically (the label changed the column height instantly) and re-rasterised
  the glyph every frame. Now the icon is laid out once at full size and only
  scaled, and the label fades in below it, always laid out. A wrap-around jumps
  instead of sweeping across every card.
- **Omarchy** reuses the vocabulary of Omarchy 4's own OSD (`osd/Osd.qml`):
  `BorderSurface` with the `popups` border spec, `Color.popups.text`, an accent
  bar, 16px padding, and the OSD's bottom-centre slot (67px up). Like the OSD,
  every column is pinned to a fixed width (the widest tool name, the widest
  readout "100%") so the card never changes size between tools. It deliberately
  ignores `cfg.colors` and follows the shell theme, because its job is to look
  like part of the shell. Tools with a live value (Volume, Brightness) get the
  OSD's value bar; the rest get one segment per tool plus a `k/n` readout, which
  keeps the "where am I in the list" feedback that Minimal Toast gave up.
- **Minimal Toast** is the smallest footprint: one pill naming the armed tool
  plus a dot strip, like a phone onboarding screen. It gives up the free "how far
  to the next tool" feedback that circular and ordered layouts show.
- **Toast jitter.** A pill that resized to each tool's name (and re-centered)
  shoved the whole thing sideways on every rotation past a longer name. It is now
  fixed-size, with long names eliding. A dot that widened on selection reflowed
  every dot after it, the other half of the jitter. Scale doesn't feed back into
  layout the way width does. Solid fill, no border: outlines read as clutter the
  color contrast already carries.
- The dot strip never sets `width`, so its `width` stays 0; read
  `implicitWidth` and `implicitHeight`, as Carousel's row is.
- **Disc backing** hugs the face's declared content radius plus a margin. It used
  to fill the full square, leaving a wide ring of dead backing past the wedges.
  Faces that declare no radius fall back to full-square sizing.
- **Backing opacity.** The theme background can carry its own alpha, so take only
  its RGB and set alpha explicitly; `opacity: 0.97` alone still let a terminal
  read straight through. The settings window forces alpha to 1, ignoring
  `plateOpacity`, since a dialog must be fully legible.
- Each `highlight` IPC call is a fire-and-forget round trip with no ordering
  guarantee. Once the position socket is live it alone drives index and position,
  so a stale call can't flicker the highlight backwards.

## Settings window

- Position, size, appearance, clicks and pen apply immediately. Tool changes are
  staged (`dirty`) and written when you press Save; the daemon then reloads them
  while the dial is idle, so there is no restart either way. `anchor` is just where
  Quickshell draws the overlay, not state the daemon holds.
- `tools.json`, `clicks.json` and `pen_clicks.json` are written by the daemon at
  startup, so the window never hardcodes a tool or action list. A tool added to
  the daemon's library just shows up. Keys the window doesn't own are read whole
  and written back untouched.
- `status.json` is the one file written continuously: state, Bluetooth battery, version and a
  timestamp, rewritten on any change and at least every 15 s. The window treats a file older than
  45 s (or missing) as "the daemon is not running", so a dead daemon is visible without the
  daemon having to say so. Battery comes from `bluetoothctl info`; where that tool is missing
  the fields are null and the window simply omits them.
- **Appearance** is one picker across all seven overlay options, though four are a
  `face` (still layout `dial`) and three are their own `layout`. It writes both
  keys together so a layout-only choice never leaves a stale `face` and vice
  versa.
- **Click gestures** share one picker parametrized by `group` (`dial` or
  `pentail`). The barrel button is one action plus a toggle, so it has its own
  block.
- **Reordering** is drag on a ring in the same order the real dial face uses. The
  center is empty on purpose: that is the dial's click/dictation zone, never a
  tool slot. The reorder commits on release, not live: a `Repeater` over a plain
  JS array has no stable delegate identity across a reorder, so a live swap would
  destroy the delegate the mouse is holding and abort the drag. The cost is that
  other chips don't preview-shuffle while you drag.
