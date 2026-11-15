"""The daemon's tunables, and the settings it reads from config.json (re-read on change)."""

import json
import math
import os

from .log import log
from .paths import CONFIG_PATH

# --- timing ---------------------------------------------------------------
HOLD_S = 0.40  # press longer than this opens the menu
# Where the dashboard parks. center | top | bottom | left | right |
# top-left | top-right | bottom-left | bottom-right
# Config is shared with the overlay plugin; every key is optional and re-read when the menu
# opens. Env vars win.


def load_config():
    """Best-effort read of the shared config. Never raises."""
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            doc = json.load(f)
        return doc if isinstance(doc, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception as e:
        log(f"config unreadable, using defaults: {e}")
        return {}


def cfg_str(doc, key, default, allowed=None):
    v = doc.get(key, default)
    if not isinstance(v, str) or (allowed and v not in allowed):
        return default
    return v


# deck/carousel = card rail; dial = radial plate; toast = pill + dots; omarchy = the shell's OSD
# style. Only validates the echoed payload; QML reads "layout" and "face" from config.json itself.
MENU_ANCHOR = "bottom"
MENU_LAYOUT = "dial"
ANCHORS = (
    "center",
    "top",
    "bottom",
    "left",
    "right",
    "top-left",
    "top-right",
    "bottom-left",
    "bottom-right",
)
DOUBLE_S = 0.25  # second click inside this window = double click
# Click actions are configurable (CLICK_ACTIONS). A double click waits DOUBLE_S for a
# possible triple unless "triple" is "none".
DISARM_S = 6.00  # default: an armed tool reverts to idle after this much stillness
DISARM_MIN_S, DISARM_MAX_S = 3.0, 300.0  # range of config "auto_return_s"
# The first movement after this much stillness shows the active tool on screen even if no full
# step has happened yet, so a gentle first turn is never met with silence.
ACK_QUIET_S = 3.0
# Finding the dial again after it sleeps or drops. The daemon does not poll on a timer: it sleeps
# until the kernel's input device list changes (DeviceWatch), so a reconnect is noticed at once and
# an idle daemon wakes only for the slow safety net below. A device that is listed but cannot be
# opened yet (its permissions are still being applied) is retried a few times in quick succession.
WATCH_SAFETY_S = 2.0
OPEN_RETRY_S = 0.02  # udev applies a new node's permissions within a few tens of milliseconds
OPEN_RETRY_MAX = 50  # so about a second in all, then the safety timeout takes over
DROP_IN_USE_S = 5.0  # a drop this soon after the last action was mid-use, so it is shown
REATTACH_PAUSE_S = 0.25  # after a drop, so a device that flaps cannot spin the loop
# A tool that holds a modifier (Zoom's Ctrl) is capped: while it is armed, every key typed elsewhere
# carries that modifier, so it must never be left armed for long.
HOLD_MOD_DISARM_CAP_S = 10.0
READING_RETURN_S = 60.0  # Scroll, H Scroll, Pages: reading pauses are long; see disarm_after()

# --- stepping ---
# Detent angle is constant per tool; speed scales step magnitude, measured over a fixed
# window. See docs/DESIGN.md#stepping.
SPEED_WINDOW = 0.20  # seconds
MAG_FALLOFF = 500.0  # counts/sec per extra unit of magnitude
MAG_MAX = 4  # never more than this many units per detent
# Menu highlight uses the SAME detent as the tools themselves (60 counts,
# 6 deg) so the whole device has one consistent rhythm -- one click, one
# step, whether that step is a volume point or the next tool. At 250 the
# menu felt heavy and unlike the rest of the dial.
MENU_STEP = 60  # counts per menu-highlight change

# --- haptics --------------------------------------------------------------
HAPTIC_WAVEFORM = 3  # ordinal 3 == CLICK; 4 and 5 feel the same, unused
HAPTIC_MIN_GAP = 0.10  # never fire ticks closer than this, or they smear.
# Keep-awake: the firmware sleeps at most 5:00 after the last touch (8 drops, 2026-10/11).
# A host READ of a feature report does not reset that timer; a haptic write with waveform
# NONE (ordinal 1) does, and the motor stays still (both tested on the dial 2026-11-06).
KEEP_AWAKE_S = 60.0
# ...but only while someone is at the desk: dial used within this many minutes (config
# "keep_awake_minutes", live) and no lock screen up. Otherwise the firmware's own sleep applies.
KEEP_AWAKE_MINUTES = 30
# shortcut: GNOME/KDE lock screens aren't processes we can see; read logind's LockedHint for them.
SCREEN_LOCKERS = {"hyprlock", "swaylock", "gtklock", "waylock", "i3lock"}
HAPTIC_NONE = 1
# Rotation stall: the dial sometimes stops sending turns while presses still arrive (2026-10-23,
# 2026-11-06; raw hidraw showed nothing sent while turning). A menu held this long with no turn
# at all is that stall, so the link is dropped and the dial reconnects turning again.
STALL_HOLD_S = 3.0
STALL_KICK_GAP_S = 30.0  # at most one stall reconnect per this many seconds
# 100ms is the measured floor: clicks stayed countable
# down to group E (100ms) in hand testing 2026-08-28.

# Haptic vocabulary: no intensity control, so meaning is pulse count and spacing,
# (repeat, retrigger_ms) in one write. See docs/DESIGN.md#haptics.
PAT_TICK = (0, 0)  # one detent -- fires constantly, must stay light
PAT_MENU = (3, 0)  # menu opened -- rare, wants weight not a count
PAT_SELECT = (3, 30)  # tool selected -- distinct but still quick
PAT_IDLE = (3, 120)  # auto-disarmed -- slow, unmistakable, unasked for
PAT_DICTATION = (6, 0)  # heaviest event on the device

# Scroll is CONTINUOUS, not detented: wheel motion is emitted proportional to
# rotation for smooth movement, while haptic ticks fire on their own coarser
# interval. A tick every 6 deg felt chunky against how little the page moved.
SCROLL_GAIN = 4.0  # hi-res wheel units per dial count (120 = one notch)
POINTER_GAIN = 0.35  # pixels per dial count at a slow turn
POINTER_ACCEL_COUNTS = 800  # dial counts/s at which pointer speed has doubled
POINTER_ACCEL_MAX = 3.0  # extra speed factor at a fast spin (so at most 4x)
MAX_LAUNCHERS = 12
SCROLL_TICK = 60  # dial counts between haptic ticks while scrolling --
# same 6 deg detent as every other tool, so the whole
# device has one rhythm. Below ~45 counts the motor
# cannot keep up at normal scrolling speed and ticks
# start being dropped, which feels worse than fewer.

# Zoom is also continuous (Ctrl+scroll), but a "notch" of zoom is a much
# bigger visual jump than a notch of scroll, so it starts gentler than
# SCROLL_GAIN. Untested by hand yet -- retune on the actual dial.
ZOOM_GAIN = 2.0

# Window Size tool: pixels per detent, and how close (px) a window's far edge
# must be to the monitor edge to count as pinned to it -- see resize_active().
RESIZE_STEP = 40
RESIZE_EDGE_SLACK = 30

# Media scrubbing: seconds per detent at a slow turn. Each step of rotation speed
# doubles it (5, 10, 20, 40 s at magnitude 1..4), so a song scrubs finely and a
# two-hour film is still reachable. See seek_media().
SEEK_STEP_S = 5

# Brightness tool: percent per detent at a slow turn -- 2 (5 moved the
# screen too fast, 1 too slow). A faster spin multiplies it by the rotation-speed
# magnitude (1..4), like Volume. Then the floor -- never dim to a
# black screen you can't see to undo.
BRIGHT_STEP = 2
BRIGHT_MIN = 1


_live = {"mtime": object(), "doc": {}}


def live_config():
    """The config as of its last change, re-read only when the file's mtime moves."""
    try:
        mtime = os.stat(CONFIG_PATH).st_mtime_ns
    except OSError:
        mtime = None
    if mtime != _live["mtime"]:
        _live.update(mtime=mtime, doc=load_config())
    return _live["doc"]


def pen_section(doc):
    """The config's "pen" section, or {} if it is missing or not an object."""
    pen = doc.get("pen")
    return pen if isinstance(pen, dict) else {}


def live_derived(cache, build):
    """`build(config doc)`, recomputed only when the config file has changed.

    `cache` is a dict holding the last doc and value. The doc object itself changes only when
    the file does (see live_config), so identity is the whole check.
    """
    doc = live_config()
    if cache.get("doc") is not doc:
        cache.update(doc=doc, value=build(doc))
    return cache["value"]


def live_num(key, default, lo, hi):
    """A config number clamped to [lo, hi]; anything else (text, true/false, NaN) is `default`."""
    v = live_config().get(key)
    if isinstance(v, int | float) and not isinstance(v, bool) and math.isfinite(v):
        return min(max(float(v), lo), hi)
    return default


def live_bool(key, default):
    v = live_config().get(key)
    return v if isinstance(v, bool) else default


def disarm_after(tool):
    """Seconds of stillness before `tool` falls back to the rest tool (config "auto_return_s").

    Clamped to 3-300 s. A tool that holds a modifier is capped at HOLD_MOD_DISARM_CAP_S.
    """
    secs = live_num("auto_return_s", DISARM_S, DISARM_MIN_S, DISARM_MAX_S)
    # Per tool: config "tool_return_s" {"Scroll": 120} beats the tool's own "return_s" (reading
    # tools stay longer: you stop to read, and the next turn should still scroll, not change
    # volume).
    own = live_config().get("tool_return_s")
    own = own.get(tool.get("name")) if isinstance(own, dict) else None
    if isinstance(own, int | float) and not isinstance(own, bool) and math.isfinite(own):
        secs = min(max(float(own), DISARM_MIN_S), DISARM_MAX_S)
    elif tool.get("return_s"):
        secs = max(secs, min(float(tool["return_s"]), DISARM_MAX_S))  # never shorter than yours
    return min(secs, HOLD_MOD_DISARM_CAP_S) if tool.get("hold_mod") else secs


def sensitivity():
    """How much of a turn each step takes (config "sensitivity", 0.5-2). Higher = less turning."""
    return live_num("sensitivity", 1.0, 0.5, 2.0)


def double_window():
    """Seconds a second press has to count as a double click (config "double_click_ms", 150-600)."""
    return live_num("double_click_ms", DOUBLE_S * 1000, 150, 600) / 1000


def hold_time():
    """Seconds to hold the button to open the tool menu (config "hold_ms", 200-1500)."""
    return live_num("hold_ms", HOLD_S * 1000, 200, 1500) / 1000


def return_buzz():
    """Whether the dial buzzes when a tool drops back to Volume (config "return_buzz")."""
    return live_bool("return_buzz", True)


def osd_enabled():
    """Whether the dial shows levels and tool names on screen as you turn (config "osd")."""
    return live_bool("osd", True)


def deadzone():
    """Counts the dial must turn after a pause before turning registers (config "deadzone")."""
    return live_num("deadzone", 0, 0, 100)


DEADZONE_REST_S = 0.4  # this long without turning and the dead zone applies again


def menu_latch():
    """Whether a quick press-and-release leaves the tool menu open (config "menu_latch").

    Off: the menu is hold, turn, release. On: hold until it opens and let go to keep it open,
    then turn to choose and click to select; turning while still holding behaves as before.
    """
    return live_bool("menu_latch", False)


def menu_idle_timeout():
    """Seconds a latched menu waits untouched before closing without a choice.

    Capped under the overlay's own 15 s watchdog, so the daemon always closes first and the
    picture never disappears while the menu is still live.
    """
    return live_num("menu_timeout_ms", 8000, 3000, 12000) / 1000


def menu_step():
    """Dial counts per menu-highlight change, scaled by sensitivity."""
    return max(10, round(MENU_STEP / sensitivity()))
