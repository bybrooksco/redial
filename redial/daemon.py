"""re:dial -- the Surface Dial and Surface Pen daemon (Hyprland, Sway, niri, KDE, GNOME, COSMIC).

Interaction model
-----------------
The dial RESTS in a safe default tool (Volume): rotating at rest only changes
volume -- harmless, reversible, and it announces itself audibly. Other tools
are armed only deliberately, and disarm themselves:

  hold 400ms   -> tool menu opens; rotating highlights; release selects
  rotate       -> drives the armed tool; the detent angle is CONSTANT,
                  rotation speed scales how much each detent does
  single click -> the armed tool's own action
  double click -> toggle voice dictation (global, from any tool)
  6s idle      -> armed tool reverts to Volume, so nothing stays armed

Haptics
-------
The dial has NO mechanical detents; the clicks are a motor we drive over
hidraw. Measured 2026-08-28: clicks stay individually countable down to
~100ms apart, and the three waveforms are not distinguishable by feel -- so
meaning is carried by RHYTHM, not waveform:

  tick (rpt 0)        -> one detent, one unit of change
  menu (rpt 3)        -> menu opened
  select (rpt 3/30ms) -> tool selected
  idle (rpt 3/120ms)  -> auto-disarmed back to Volume
  dictation (rpt 6)   -> dictation toggled

Requires write access to the dial's hidraw node. Without it the daemon still
works, silently, and says so once in the log.

Hardware: 3600 counts/revolution (0.1 deg/count), REL_DIAL + BTN_0.
"""

import atexit
import json
import math
import os
import re
import select
import shutil
import signal
import struct
import sys
import threading
import time
from collections import deque

from .cli import parse_args, reset_guide_file  # noqa: F401  (tests reach them through here)
from .config import (
    ACK_QUIET_S,
    BRIGHT_STEP,
    DEADZONE_REST_S,
    DROP_IN_USE_S,
    MAG_FALLOFF,
    MAG_MAX,
    MAX_LAUNCHERS,
    OPEN_RETRY_MAX,
    OPEN_RETRY_S,
    PAT_DICTATION,
    PAT_IDLE,
    PAT_MENU,
    PAT_SELECT,
    PAT_TICK,
    POINTER_ACCEL_COUNTS,
    POINTER_ACCEL_MAX,
    POINTER_GAIN,
    READING_RETURN_S,
    REATTACH_PAUSE_S,
    RESIZE_STEP,
    SCROLL_GAIN,
    SCROLL_TICK,
    SEEK_STEP_S,
    SPEED_WINDOW,
    STALL_HOLD_S,
    STALL_KICK_GAP_S,
    WATCH_SAFETY_S,
    ZOOM_GAIN,
    _pen_section,
    deadzone,
    disarm_after,
    double_window,
    hold_time,
    live_bool,
    live_config,
    live_derived,
    load_config,
    menu_idle_timeout,
    menu_latch,
    menu_step,
    osd_enabled,
    return_buzz,
    sensitivity,
)
from .controls import _show_level, media_command, seek_media, set_brightness, show_level, vol
from .devices import (
    ABS_X,
    ABS_Y,
    BTN_0,
    BTN_STYLUS,
    BTN_TOOL_RUBBER,
    BTN_TOUCH,
    DEVICE_NAME,
    EV_ABS,
    EV_FORMAT,
    EV_KEY,
    EV_REL,
    EV_SIZE,
    PEN_KBD_NAME,
    REL_DIAL,
    STYLUS_NAME,
    DeviceWatch,
    event_time,
    open_input,
    use_monotonic_event_clock,
)
from .feedback import (
    MENU_STREAM,
    MENU_UI,
    backlight_device,
    cant_note,
    notify,
    omarchy_shell,
    osd,
    overlay_note,
    speak,
    turn_note,
)
from .haptics import HAPTIC
from .keys import key, press_mod, release_mod, repeat_key, uinput_keys
from .log import debug, log
from .paths import CONFIG_PATH
from .status import _status, kick_dial, status_loop
from .system import ACTIONS, launch, make_private, run, single_instance, write_json_atomic
from .uinput import KEYBOARD, POINTER, VirtualPointer
from .wm import (
    HYPR_ERRORS,
    SCROLL_SUPPRESS_CLASSES,
    backend,
    focused_class,
    focused_is_terminal,
    focused_runs_suppressed_program,
    hypr,
    hypr_json,
)

# Pen tail button arrives as SUPER+F18/19/20: not bindable via xkb, so read off evdev.
# See docs/DESIGN.md#pen-buttons.
KEY_F18, KEY_F19, KEY_F20 = 188, 189, 190
# Maps the physical event to a named slot. Defaults are chosen by accident risk and are
# configurable (pen.tail_clicks). See docs/DESIGN.md#pen-buttons.
PEN_BUTTON = {
    KEY_F20: ("single click", "single"),
    KEY_F19: ("double click", "double"),
    KEY_F18: ("press and hold", "hold"),
}

# Eraser drag scrolls only in these window classes (allowlist; the stylus is never grabbed).
ERASER_SCROLL_CLASSES = {
    "foot",
    "alacritty",
    "Alacritty",
    "kitty",
    "ghostty",
    "com.mitchellh.ghostty",
    "wezterm",
    "org.wezfurlong.wezterm",
    "xterm",
    "org.omarchy.agent",
    "zen",
    "firefox",
    "chromium",
    "google-chrome",
    "org.mozilla.firefox",
}
# Hi-res wheel units per unit of ABS_Y travel (18/mm), per class: terminals need more
# push than browsers. See docs/DESIGN.md#eraser.
ERASER_SCROLL_GAIN_DEFAULT = 0.6
# An eraser TAP (down and up with almost no travel) is Escape. Flipping the
# pen over is a deliberate two-step act, so unlike the tail button's single
# click it cannot be brushed by accident -- which is what makes it a safe
# home for a disruptive key. A touch that travels this far locks a drag axis and
# is a scroll, not a tap. It was ~5mm, which made every scroll start late; the
# travel before the lock is replayed so the page moves from the first millimetre.
ERASER_AXIS_LOCK_TRAVEL = 36  # ABS units (18/mm), ~2mm
# An eraser drag carries TWO axes. Vertical scrolls; horizontal steps the
# text cursor. The axis is chosen once, by whichever accumulates more travel
# first, and then locked for that drag so a wobble cannot flip it mid-stroke.
ERASER_CURSOR_STEP = 55  # ABS_X units per cursor move, ~3mm
# Eraser tap vs hold is classified on release by duration; there is no pressure signal.
ERASER_HOLD_S = 0.45
# A touch shorter than this is a brush, not a tap: a scroll often starts with a bounce of contact
# 30-60 ms long, which used to fire Escape. The default is easy to beat on purpose; the Pen
# settings can raise, lower or switch it off (0).
ERASER_TAP_MIN_MS_DEFAULT = 100
ERASER_SCROLL_GAIN = {
    "foot": 1.6,
    "alacritty": 1.6,
    "Alacritty": 1.6,
    "kitty": 1.6,
    "ghostty": 1.6,
    "com.mitchellh.ghostty": 1.6,
    "wezterm": 1.6,
    "org.wezfurlong.wezterm": 1.6,
    "xterm": 1.6,
    "org.omarchy.agent": 1.6,
    "zen": 0.30,
    "firefox": 0.30,
    "org.mozilla.firefox": 0.30,
    "chromium": 0.30,
    "google-chrome": 0.30,
}


_scroll_warned_class = None


def scroll_mode():
    """Classify the focused window for a wheel-based scroll tool.

    Returns "wheel" (default -- real wheel events, safe everywhere not
    listed below, terminal emulators included) or "suppress" (send nothing;
    the focused app binds Up/Down destructively and foot would hand it
    exactly that if a wheel event were sent).
    """
    global _scroll_warned_class
    cls = focused_class()
    prog = None if cls in SCROLL_SUPPRESS_CLASSES else focused_runs_suppressed_program()
    if prog:
        cls = f"{cls}:{prog}"
    if cls in SCROLL_SUPPRESS_CLASSES or prog:
        if _scroll_warned_class != cls:
            _scroll_warned_class = cls
            cant_note(
                "tool", "Scroll is paused here", "This app turns scrolling into prompt history"
            )
        return "suppress"
    _scroll_warned_class = None
    return "wheel"


# A plain `kill` exits through sys.exit, so atexit hooks run (release_mod lets go of a held key).
signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))


# --------------------------------------------------------------------------
# --- the guide ---
# Teaches the dial by what the person actually does, one idea at a time, instead of up front:
# a hint appears only when their behaviour shows they are ready for it (or stuck) and they have
# not just done the thing. Progress and counters live in progress.json next to the config; the
# counters are plain usage totals, kept on this machine only.
#
# Three styles, picked by the "onboarding_mode" setting (all share the same progress file):
#   adaptive  four stages, each shown when behaviour says the person is ready for it (default)
#   discover  almost nothing up front: two hints (press, then hold), only when they are needed
#   guided    a short linear tour on first connect: do each gesture once, in order
# Adaptive and discover also teach each tool the first time it is picked, and again with its
# click if the person turns it a while without ever clicking. Guided teaches only the tour.
GUIDE_COOLDOWN_S = 30.0  # never two hints within this long
GUIDE_MAX_SHOWS = 3  # a hint that has not worked after this many showings is dropped
GUIDE_FLUSH_S = 30.0  # progress is written at least this often while counters change
GUIDE_STEPS_BEFORE_HINT = 10  # steps of turning with the next thing still undone
GUIDE_MODES = ("adaptive", "discover", "guided")
TOUR_REPROMPT_S = 20.0  # a tour step nobody has done is asked again after this long...
TOUR_MAX_PROMPTS = 3  # ...up to this many times, then skipped so the tour never gets stuck
TOUR_TURN_STEPS = 3  # steps of turning that count as having tried it


def _hint_press():
    label = click_hint(TOOLS[IDLE_TOOL]) if TOOLS else ""
    return f"Press the dial: {label}" if label and label != "—" else None


def _hint_pick():
    if menu_latch():
        return "Turn to a tool, then click to choose it"
    return "Keep holding, turn to a tool, then let go"


# id, the event that completes it, what makes its hint appear, the hint text, whether showing the
# hint is itself the lesson. Order is the order of learning; an event completes its stage even when
# it happens early or out of order.
GUIDE_STAGES = [
    {
        "id": "press",
        "done": "click",
        "when": ("steps", GUIDE_STEPS_BEFORE_HINT),
        "text": _hint_press,
    },
    {
        "id": "hold",
        "done": "menu",
        "when": ("steps", GUIDE_STEPS_BEFORE_HINT),
        "text": lambda: "Hold the button to choose a tool",
    },
    {"id": "pick", "done": "pick", "when": ("event", "menu_same"), "text": _hint_pick},
    {
        "id": "own",
        "done": None,
        "when": ("steps", 3 * GUIDE_STEPS_BEFORE_HINT),
        "text": lambda: "Make it yours: Menu > Setup > re:dial",
    },
]

# Discover: two hints. Press when turning alone has gone on a while, hold right after the first
# press. No pick hint, no pointer to settings; the person finds those or they do not need them.
DISCOVER_STAGES = [
    GUIDE_STAGES[0],
    {
        "id": "hold",
        "done": "menu",
        "when": ("event", "click"),
        "text": lambda: "Hold the button for the tool ring",
    },
]


def _tour_close():
    return "Click to close the ring" if menu_latch() else "Let go to close the ring"


def _tour_pick():
    if menu_latch():
        return "Hold, turn to another tool, then click to choose it"
    return "Hold, turn to another tool, then let go"


# The guided tour: id, the events that finish it, how many of them it takes, what it asks. The
# last step only points at settings, and being shown is its lesson. An event that finishes a later
# step moves the tour past every step before it.
TOUR_STEPS = [
    {"id": "turn", "done": ("step",), "need": TOUR_TURN_STEPS, "text": lambda: "Turn the dial"},
    {"id": "press", "done": ("click",), "need": 1, "text": lambda: "Now press it"},
    {
        "id": "hold",
        "done": ("menu",),
        "need": 1,
        "text": lambda: "Press and hold to open the tool ring",
    },
    {"id": "close", "done": ("menu_same", "pick"), "need": 1, "text": _tour_close},
    {"id": "pick", "done": ("pick",), "need": 1, "text": _tour_pick},
    {
        "id": "feel",
        "done": (),
        "need": 1,
        "text": lambda: "Too fast or slow? Menu > Setup > re:dial > Feel",
    },
]


# The gesture a hint asks for, from the event that answers it (the overlay draws it).
HINT_GESTURE = {
    "step": "turn",
    "click": "press",
    "menu": "hold",
    "menu_same": "hold",
    "pick": "hold",
}


def guide_stages(mode):
    return DISCOVER_STAGES if mode == "discover" else GUIDE_STAGES


class Guide:
    """The introduction: counts what the person does and speaks up when it will help.

    `event(kind)` takes "step", "click", "menu" (menu opened), "pick" (a different tool chosen)
    and "menu_same" (menu closed without a change). `armed(name, rest)` says which tool is now
    active, `attached()` that the dial just connected or woke. `say(text, meta)` shows a line
    (meta: the gesture it asks for and, on the tour, "step" of "steps"),
    `mode()` returns "adaptive", "discover" or "guided", and `describe(name)` returns the
    {"intro", "click"} lines for a tool (or None). Nothing here blocks or changes what the dial
    does; it only watches and, now and then, shows a line of text.
    """

    def __init__(
        self,
        path,
        say,
        clock=time.monotonic,
        enabled=lambda: True,
        mode=lambda: "adaptive",
        describe=lambda name: None,
    ):
        self.path = path
        self.say = say
        self.clock = clock
        self.enabled = enabled
        self.mode = mode
        self.describe = describe
        self.state = self._load()
        self.session_steps = 0  # turning since the last hint or stage change
        self.last_hint = -1e9
        self.last_flush = clock()
        self.dirty = False
        self.tool = None  # the active tool, for the per-tool hints
        self.tool_rest = True  # ...and whether it is the resting tool (Volume), which is skipped
        self.tool_steps = 0  # steps on the active tool since it was armed or last hinted
        self.last_prompt = -1e9  # when the guided tour last asked for its current step

    @staticmethod
    def _fresh():
        return {
            "version": 2,
            "done": [],
            "shown": {},
            "counts": {"steps": 0, "clicks": 0, "menus": 0, "picks": 0},
            "tools": {},
            "tour": {"step": 0, "n": 0, "prompts": 0, "skipped": [], "done": False},
        }

    @staticmethod
    def _int(v):
        return isinstance(v, int) and not isinstance(v, bool) and v >= 0

    def _load(self):
        state = self._fresh()
        try:
            with open(self.path, encoding="utf-8") as f:
                doc = json.load(f)
            if isinstance(doc, dict):
                if isinstance(doc.get("done"), list):
                    state["done"] = [d for d in doc["done"] if isinstance(d, str)]
                if isinstance(doc.get("shown"), dict):
                    state["shown"] = {k: v for k, v in doc["shown"].items() if self._int(v)}
                if isinstance(doc.get("counts"), dict):
                    for k in state["counts"]:
                        v = doc["counts"].get(k)
                        if self._int(v):
                            state["counts"][k] = v
                self._load_tools(state, doc.get("tools"))
                self._load_tour(state, doc.get("tour"))
        except (OSError, ValueError):
            pass  # no file yet, or a damaged one: start the introduction from the beginning
        return state

    def _load_tools(self, state, tools):
        if not isinstance(tools, dict):
            return
        for name, entry in tools.items():
            if isinstance(name, str) and isinstance(entry, dict):
                fresh = self._tool_entry()
                for k in ("intro", "click_shown", "steps"):
                    if self._int(entry.get(k)):
                        fresh[k] = entry[k]
                if isinstance(entry.get("clicked"), bool):
                    fresh["clicked"] = entry["clicked"]
                state["tools"][name] = fresh

    def _load_tour(self, state, tour):
        if not isinstance(tour, dict):
            return
        for k in ("step", "n", "prompts"):
            if self._int(tour.get(k)):
                state["tour"][k] = tour[k]
        state["tour"]["step"] = min(state["tour"]["step"], len(TOUR_STEPS) - 1)
        if isinstance(tour.get("skipped"), list):
            state["tour"]["skipped"] = [s for s in tour["skipped"] if isinstance(s, str)]
        if isinstance(tour.get("done"), bool):
            state["tour"]["done"] = tour["done"]

    @staticmethod
    def _tool_entry():
        return {"intro": 0, "click_shown": 0, "clicked": False, "steps": 0}

    def flush(self):
        """Write progress, atomically. Best effort: the dial works without it."""
        if not self.dirty:
            return
        try:
            write_json_atomic(self.path, self.state)
            self.dirty = False
        except OSError as exc:
            log(f"could not write progress ({exc})")
        self.last_flush = self.clock()

    def reset(self):
        """Start the introduction again (the counters go too)."""
        self.state = self._fresh()
        self.session_steps = 0
        self.tool_steps = 0
        self.last_prompt = -1e9
        self.dirty = True
        self.flush()

    def _complete(self, stage_id):
        if stage_id not in self.state["done"]:
            self.state["done"].append(stage_id)
            self.session_steps = 0
            self.dirty = True
            self.flush()

    def _speaking(self):
        return self.enabled()

    def _learning(self):
        return self._speaking() and self.mode() != "guided"

    def _entry(self, name):
        return self.state["tools"].setdefault(name, self._tool_entry())

    # --- what the dial tells us
    def event(self, kind):
        counts = self.state["counts"]
        key = {"step": "steps", "click": "clicks", "menu": "menus", "pick": "picks"}.get(kind)
        if key:
            counts[key] += 1
            self.dirty = True
        mode = self.mode()
        if kind == "step":
            self.session_steps += 1
            self.tool_steps += 1
            if self.tool:
                self._entry(self.tool)["steps"] += 1
        if kind == "click" and self.tool and not self.tool_rest:
            self._entry(self.tool)["clicked"] = True
        if mode == "guided":
            self._tour_event(kind)
        else:
            for stage in guide_stages(mode):
                if stage["done"] == kind:
                    self._complete(stage["id"])
            if not self._maybe_hint(kind, mode):
                self._maybe_tool_click_hint(kind)
        if self.dirty and self.clock() - self.last_flush >= GUIDE_FLUSH_S:
            self.flush()

    def armed(self, name, rest=False):
        """A different tool is now active. The resting tool is taught by the other hints."""
        self.tool, self.tool_rest, self.tool_steps = name, rest, 0
        if rest or not self._learning():
            return
        entry = self._entry(name)
        if entry["intro"]:
            return
        lines = self.describe(name) or {}
        if not lines.get("intro"):
            return
        entry["intro"] = 1
        self.dirty = True
        self.last_hint = self.clock()
        self.session_steps = 0
        self.flush()
        self.say(lines["intro"], {"gesture": "turn"})

    def attached(self):
        """The dial connected or woke: the tour (if it is the chosen style) asks its next step."""
        if self.mode() != "guided" or not self._speaking() or self.state["tour"]["done"]:
            return
        self._tour_say()

    # --- adaptive and discover
    def _next_stage(self, mode):
        for stage in guide_stages(mode):
            if stage["id"] not in self.state["done"]:
                return stage
        return None

    def _maybe_hint(self, kind, mode):
        """Show the next stage's hint if it is due. True when a hint was shown."""
        stage = self._next_stage(mode)
        if stage is None or not self._speaking():
            return False
        what, need = stage["when"]
        ready = self.session_steps >= need if what == "steps" else kind == need
        if not ready or self.state["shown"].get(stage["id"], 0) >= GUIDE_MAX_SHOWS:
            return False
        now = self.clock()
        # The cooldown spaces out hints the guide volunteers while someone turns; one that answers
        # something they just did (a menu closed without a choice) is help they asked for.
        if what == "steps" and now - self.last_hint < GUIDE_COOLDOWN_S:
            return False
        text = stage["text"]()
        if not text:
            return False
        self.last_hint = now
        self.session_steps = 0
        self.state["shown"][stage["id"]] = self.state["shown"].get(stage["id"], 0) + 1
        self.dirty = True
        if stage["done"] is None:
            self._complete(stage["id"])  # showing it was the lesson
        self.flush()
        self.say(text, {"gesture": HINT_GESTURE.get(stage["done"], "")})
        return True

    def _maybe_tool_click_hint(self, kind):
        """A tool turned a while with no click on it: say what its click does."""
        if kind != "step" or self.tool_rest or not self.tool or not self._learning():
            return
        entry = self._entry(self.tool)
        if entry["clicked"] or entry["click_shown"] >= GUIDE_MAX_SHOWS:
            return
        if self.tool_steps < GUIDE_STEPS_BEFORE_HINT:
            return
        now = self.clock()
        if now - self.last_hint < GUIDE_COOLDOWN_S:
            return
        text = (self.describe(self.tool) or {}).get("click")
        if not text:
            return
        entry["click_shown"] += 1
        self.tool_steps = 0
        self.last_hint = now
        self.dirty = True
        self.flush()
        self.say(text, {"gesture": "press"})

    # --- guided tour
    def _tour_say(self):
        tour = self.state["tour"]
        step = TOUR_STEPS[tour["step"]]
        text = step["text"]()
        tour["prompts"] += 1
        self.last_prompt = self.clock()
        self.dirty = True
        gesture = HINT_GESTURE.get(step["done"][0], "") if step["done"] else ""
        self.say(text, {"gesture": gesture, "step": tour["step"] + 1, "steps": len(TOUR_STEPS)})
        if TOUR_STEPS[tour["step"]]["id"] == "feel":
            tour["done"] = True  # showing the last step was the lesson
        self.flush()

    def _tour_event(self, kind):
        tour = self.state["tour"]
        if tour["done"] or not self._speaking():
            return
        if kind == "step":
            tour["n"] += 1
        for i in range(len(TOUR_STEPS) - 1, tour["step"] - 1, -1):
            step = TOUR_STEPS[i]
            if kind in step["done"] and (kind != "step" or tour["n"] >= step["need"]):
                self._tour_advance(i + 1)
                return
        if self.clock() - self.last_prompt < TOUR_REPROMPT_S:
            return
        if tour["prompts"] >= TOUR_MAX_PROMPTS:  # asked enough: move on rather than stall
            tour["skipped"].append(TOUR_STEPS[tour["step"]]["id"])
            self._tour_advance(tour["step"] + 1)
        else:
            self._tour_say()

    def _tour_advance(self, nxt):
        tour = self.state["tour"]
        tour["n"], tour["prompts"] = 0, 0
        tour["step"] = min(nxt, len(TOUR_STEPS) - 1)
        self.dirty = True
        self._tour_say()


class NoGuide:
    """What the dial uses until the daemon starts the real guide (and in most tests)."""

    def event(self, kind):
        pass

    def armed(self, name, rest=False):
        pass

    def attached(self):
        pass

    def flush(self):
        pass


GUIDE = NoGuide()


def guide_path():
    return os.path.join(os.path.dirname(CONFIG_PATH), "progress.json")


def guide_enabled():
    """Whether hints are shown (config "guide", and never while the on-screen display is off)."""
    return live_bool("guide", True) and osd_enabled()


def guide_mode():
    """The introduction style (config "onboarding_mode"); anything unrecognised is adaptive."""
    v = live_config().get("onboarding_mode")
    return v if v in GUIDE_MODES else "adaptive"


def tool_lines(name):
    """What the per-tool hints say about `name`: {"intro": turning, "click": its click}."""
    lib = next((t for t in TOOL_LIBRARY if t["name"] == name), None)
    spec = next((t for t in TOOLS if t["name"] == name), None)
    lines = {}
    if lib and lib.get("description"):
        lines["intro"] = f"{name}: {lib['description'].split('. ')[0].rstrip('.')}"
    label = click_hint(spec) if spec else ""
    if label and label != "—":
        lines["click"] = f"{name}: click to {label}"
    return lines


def _say_sync(text, meta=None):
    if not overlay_note("hint", dict(meta or {}, prompt=text)):
        osd(message=text, duration=3500)


def guide_say(text, meta=None):
    ACTIONS.submit(_say_sync, text, meta)


class EraserState:
    """What the eraser end of the pen is doing, fed one stylus event at a time.

    Engages on BTN_TOUCH while BTN_TOOL_RUBBER is active -- the eraser end
    actually down, not merely hovering (proximity fires constantly). The
    focused window class is checked once, at touch-down, so the decision
    cannot flip mid-drag. Anywhere not on the allowlist, nothing is emitted
    at all and the eraser behaves exactly as it always has.
    """

    def __init__(self):
        self.rubber = False
        self.gain = ERASER_SCROLL_GAIN_DEFAULT
        self.y_mode = "wheel"
        self.touch_at = 0.0
        self.reset()

    def reset(self):
        """Forget any drag in progress (eraser lifted, or the device went away)."""
        self.dragging = False
        self.last_y = None
        self.last_x = None
        self.travel = self.trav_x = self.trav_y = 0.0
        self.axis = None
        self.cur_accum = 0.0
        self.pend_x = self.pend_y = 0.0  # signed travel before the axis locks, replayed on lock

    def handle(self, etype, code, value, now):
        if etype == EV_KEY and code == BTN_STYLUS:
            self._barrel(value)
        elif etype == EV_KEY and code == BTN_TOOL_RUBBER:
            self.rubber = bool(value)
            if not self.rubber:
                self.dragging, self.last_y, self.last_x = False, None, None
                self.axis = None
        elif etype == EV_KEY and code == BTN_TOUCH:
            if value == 1 and self.rubber:
                self._touch_down(now)
            else:
                self._touch_up(now)
        elif etype == EV_ABS and self.dragging and code in (ABS_X, ABS_Y):
            if code == ABS_Y:
                self._move_y(value)
            else:
                self._move_x(value)

    def _barrel(self, value):
        """Barrel button -> pen.barrel action (+ pen.barrel.hold). Bound globally, not allowlisted.

        A "mouse" action passes press/release through; any other action fires once on press, or
        on release when a hold action is set (so a hold never also fires the press action).
        """
        enabled, name = pen_barrel_config()
        if not enabled:
            return
        hold, hold_s = pen_barrel_hold()
        spec = _PEN_BARREL_BY_NAME[name][3]
        if value == 1 and hold != "none":
            self.barrel_held = False
            self.barrel_timer = threading.Timer(hold_s, self._barrel_hold, (hold,))
            self.barrel_timer.daemon = True
            self.barrel_timer.start()
        elif value == 0 and getattr(self, "barrel_timer", None):
            self.barrel_timer.cancel()
            self.barrel_timer = None
        if isinstance(spec, dict) and spec.get("do") == "mouse":
            btn = mouse_button(spec)
            if btn is not None:
                POINTER.click(btn, value == 1)
                log(f"barrel -> {name} {'down' if value else 'up'}")
        elif value == (1 if hold == "none" else 0) and not getattr(self, "barrel_held", False):
            fn = pen_barrel_fn(name)
            if fn:
                log(f"barrel -> {name}")
                ACTIONS.submit(fn, 1)  # off the pen's input thread (DESIGN.md: it only reads)

    def _barrel_hold(self, hold):
        """The hold timer ran out with the barrel still down (a release that raced it has
        already cleared barrel_timer, so a stale timer does nothing)."""
        if getattr(self, "barrel_timer", None) is None:
            return
        self.barrel_held = True
        fn = pen_barrel_fn(hold)
        if fn:
            log(f"barrel hold -> {hold}")
            ACTIONS.submit(fn, 1)

    def _touch_down(self, now):
        cls = focused_class()
        if cls not in ERASER_SCROLL_CLASSES:
            log(f"eraser down in {cls} -> left alone")
            return
        self.reset()
        self.dragging = True
        self.touch_at = now
        self.gain = ERASER_SCROLL_GAIN.get(cls, ERASER_SCROLL_GAIN_DEFAULT) * pen_eraser_config()[3]
        # Same routing as the dial's Scroll tool (SCROLL_SUPPRESS_CLASSES); decided once per touch.
        self.y_mode = scroll_mode()
        log(f"eraser down in {cls} (gain {self.gain}, y_mode {self.y_mode})")

    def _touch_up(self, now):
        if self.dragging and self.axis is None:
            held = now - self.touch_at
            tap, hold, tap_min, _ = pen_eraser_config()
            if held >= ERASER_HOLD_S:
                kind, name = "hold", hold
            elif held >= tap_min:
                kind, name = "tap", tap
            else:
                kind, name = "brush", None
            fn = pen_eraser_fn(name) if name else None
            log(f"eraser {kind} ({held:.2f}s) -> {name or 'ignored'}")
            if fn:
                ACTIONS.submit(fn, 1)
        self.dragging, self.last_y, self.last_x = False, None, None
        self.axis = None

    def _pick_axis(self):
        if self.axis is None and self.travel >= ERASER_AXIS_LOCK_TRAVEL:
            self.axis = "y" if self.trav_y >= self.trav_x else "x"
            log(f"eraser drag axis = {self.axis}")
            if self.axis == "y" and self.pend_y and self.y_mode != "suppress":
                POINTER.scroll(self.pend_y * self.gain)
            elif self.axis == "x":
                self.cur_accum += self.pend_x

    def _move_y(self, value):
        if self.last_y is not None:
            dy = value - self.last_y
            self.travel += abs(dy)
            self.trav_y += abs(dy)
            self._pick_axis()
            if self.axis is None:
                self.pend_y += dy
            elif self.axis == "y" and dy and self.y_mode != "suppress":
                POINTER.scroll(dy * self.gain)
        self.last_y = value

    def _move_x(self, value):
        if self.last_x is not None:
            dx = value - self.last_x
            self.travel += abs(dx)
            self.trav_x += abs(dx)
            self._pick_axis()
            if self.axis is None:
                self.pend_x += dx
            elif self.axis == "x":
                self.cur_accum += dx
                while abs(self.cur_accum) >= ERASER_CURSOR_STEP:
                    d = 1 if self.cur_accum > 0 else -1
                    self.cur_accum -= d * ERASER_CURSOR_STEP
                    key("Right" if d > 0 else "Left")
        self.last_x = value


def eraser_watcher():
    """Read the stylus device and feed an EraserState; reconnect when it goes away."""
    state = EraserState()
    while True:
        fh, path = open_input(STYLUS_NAME)
        if fh is None:
            time.sleep(5)
            continue
        try:
            with fh:
                while True:
                    data = fh.read(EV_SIZE)
                    if not data or len(data) < EV_SIZE:
                        break
                    _, _, etype, code, value = struct.unpack(EV_FORMAT, data)
                    state.handle(etype, code, value, time.monotonic())
        except OSError as exc:
            log(f"stylus read ended ({exc})")
        state.dragging, state.last_y = False, None
        time.sleep(2)


def pen_button_watcher():
    """Tail-button clicks, read straight from the pen's keyboard node."""
    while True:
        fh, path = open_input(PEN_KBD_NAME)
        if fh is None:
            time.sleep(5)
            continue
        log(f"pen buttons on {path}")
        try:
            with fh:
                while True:
                    data = fh.read(EV_SIZE)
                    if not data or len(data) < EV_SIZE:
                        break
                    _, _, etype, code, value = struct.unpack(EV_FORMAT, data)
                    if etype != EV_KEY or value != 1:
                        continue
                    entry = PEN_BUTTON.get(code)
                    if entry is None:
                        continue
                    label, slot = entry
                    fn = pen_tail_fn(slot)
                    if fn is None:
                        log(f"pen {label} -> unbound")
                    else:
                        log(f"pen {label} -> firing")
                        ACTIONS.submit(fn, 1)
        except OSError as exc:
            log(f"pen keyboard read ended ({exc})")
        time.sleep(2)


def dictation_toggle():
    if run(["voxtype", "record", "toggle"]):
        notify("\U0001f399  Dictation", "voxtype toggled")
    else:
        notify(
            "\U0001f399  Dictation unavailable",
            "voxtype isn't running: journalctl --user -u voxtype",
        )


# --------------------------------------------------------------------------
# Volume is index 0 and is the idle home: rotating at rest only changes volume.
# "detent" is the constant angle (in counts) between clicks for this tool.
# "mag" tools accept a magnitude 1..MAG_MAX derived from rotation speed;
# discrete tools ignore it because "1.6 windows" is meaningless.
# --- action vocabulary ----------------------------------------------------
#
# Tools are data, not code. Each rotation direction and the click carry an
# action spec, compiled here into a callable that takes the step magnitude.
#
#   {"do": "exec",      "cmd": ["wpctl", "set-mute", "..."]}
#   {"do": "wm",        "op": "cycle", "forward": true}   - window-manager verb, any compositor
#   {"do": "hypr",      "lua": "hl.dsp.window.cycle_next()"}   - Hyprland only
#   {"do": "key",       "keys": ["ctrl", "z"], "repeat": false}
#                        - optional "terminal_keys": [...] replaces keys when a terminal is focused;
#                          [] means send nothing there
#   {"do": "volume",    "direction": "up" | "down"}
#   {"do": "brightness","direction": "up" | "down", "step": 2}
#                                                - backlight percent per detent x magnitude
#   {"do": "seek",      "direction": "forward" | "back", "step": 5}   - scrub media; step is seconds
#                        at a slow turn, doubled per speed step
#                        (needs "magnitude": true on the tool)
#   {"do": "resize",    "axis": "x" | "y", "direction": "grow" | "shrink", "step": 40}
#   {"do": "dictation"}
#   {"do": "reconnect"}  - drop the dial's Bluetooth link so it reconnects on the next press
#   {"do": "wheel"}      - marker only; the continuous path drives the pointer
#   {"do": "none"} / null
#
# Every spec may carry "label", which is what the overlay shows as the click
# action. Unknown verbs are logged and become no-ops rather than raising: a
# typo in a config file must not take the dial down.
#
# Two more fields apply to the whole tool, not one direction:
#   "continuous": True   - cw/ccw are ignored; on_rotate drives POINTER
#                           directly every event instead of on fixed detents
#   "hold_mod": "ctrl"   - held for as long as this tool stays armed (via a
#                           parked wtype process, see press_mod/release_mod),
#                           so its continuous wheel events arrive as Ctrl+
#                           scroll instead of plain scroll
#   "gain"               - hi-res wheel units per dial count for a continuous
#                           tool; defaults to SCROLL_GAIN if omitted
#   "invert": True       - flips which rotation direction is positive wheel
#                           motion. Default (Scroll) has cw = wheel-down/
#                           scroll-down; Zoom sets this so cw = wheel-up,
#                           which Ctrl+scroll reads as zoom IN, matching the
#                           cw-increases convention every other tool uses.


def mouse_button(spec):
    """VirtualPointer button constant for a "mouse" action spec's "button", or None."""
    return {
        "left": VirtualPointer.BTN_LEFT,
        "right": VirtualPointer.BTN_RIGHT,
        "middle": VirtualPointer.BTN_MIDDLE,
    }.get(str(spec.get("button", "right")).lower())


CAST_ERRORS = (TypeError, ValueError, OverflowError)  # int()/float() on something unusable


def _spec_number(spec, key, default, cast):
    """spec[key] converted with `cast` (int or float), or `default` if absent or unusable."""
    try:
        return cast(spec.get(key, default))
    except CAST_ERRORS:
        return default


def _is_string_list(v):
    return isinstance(v, list) and all(isinstance(k, str) for k in v)


def _direction_up(spec, default="up", negative="down"):
    """True unless spec["direction"] names the `negative` way."""
    return str(spec.get("direction", default)).lower() != negative


def _compile_exec(spec):
    cmd = spec.get("cmd")
    if not _is_string_list(cmd):
        log(f"exec needs a list of strings for cmd: {spec!r}")
        return None
    return lambda mag, _c=list(cmd): launch(_c)


def _compile_hypr(spec):
    lua = spec.get("lua")
    if not isinstance(lua, str) or not lua:
        log(f"hypr needs a lua string: {spec!r}")
        return None
    return lambda mag, _l=lua: hypr(_l)


WM_OPS = ("cycle", "focus", "workspace", "send", "swap", "maximize", "fullscreen", "float")


def _compile_wm(spec):
    op = spec.get("op")
    if op not in WM_OPS:
        log(f"wm needs an op from {WM_OPS}: {spec!r}")
        return None
    args = {k: v for k, v in spec.items() if k not in ("do", "op", "label")}

    def run_op(mag, _o=op, _a=args):
        backend().op(_o, **_a)
        if _o in ("cycle", "focus"):
            show_level("window")  # say which window you landed on, so cycling isn't blind

    return run_op


_term_warned = {"at": -1e9}


def _terminal_cant():
    now = time.monotonic()
    if now - _term_warned["at"] > 3:
        _term_warned["at"] = now
        cant_note("tool", "Not in a terminal", "Here these keys would stop the running program")


def _compile_key(spec):
    keys = spec.get("keys")
    if not keys or not _is_string_list(keys):
        log(f"key needs a non-empty list of key names: {spec!r}")
        return None
    rep = bool(spec.get("repeat", False))
    tkeys = spec.get("terminal_keys")
    if tkeys is not None and not _is_string_list(tkeys):
        log(f"key terminal_keys must be a list of key names: {spec!r}")
        tkeys = None

    plain = list(keys)
    in_terminal = None if tkeys is None else list(tkeys)

    def press(mag):
        chosen = plain
        if in_terminal is not None and focused_is_terminal():
            if not in_terminal:
                _terminal_cant()  # nothing sensible to send in a terminal; say so, don't guess
                return
            chosen = in_terminal
        if rep:
            repeat_key(max(1, int(mag)), *chosen)
        else:
            key(*chosen)

    return press


def _compile_brightness(spec):
    up = _direction_up(spec)
    step = _spec_number(spec, "step", BRIGHT_STEP, int)
    dev = spec.get("device") if isinstance(spec.get("device"), str) else None
    return lambda mag, _u=up, _s=step, _d=dev: set_brightness(mag, _u, _s, _d)


def _compile_seek(spec):
    forward = _direction_up(spec, "forward", "back")
    step = _spec_number(spec, "step", SEEK_STEP_S, float)
    return lambda mag, _f=forward, _s=step: seek_media(_f, mag, _s)


# The settings window is a normal window (Quickshell FloatingWindow); install.sh's rule floats it.
SETTINGS_TITLE = "re:dial settings"


def settings_window_focused():
    """Whether re:dial's settings window has keyboard focus (so Tab and Enter land in it)."""
    try:
        w = hypr_json("activewindow") or {}
        return w.get("class") == "org.quickshell" and w.get("title") == SETTINGS_TITLE
    except HYPR_ERRORS:
        return False


SETTINGS_KEYS = {"next": ["Tab"], "prev": ["shift", "Tab"], "press": ["Return"]}


def settings_action(op):
    """The Settings tool: open the window, or walk and press its controls with the dial.

    Keys go only to the settings window, and only while it has focus. Closed or behind another
    window, any turn or click brings it to the front instead, so a click can never land as Enter
    in whatever app has focus.
    """
    if not omarchy_shell():
        # redial-settings is one window; launching it again just raises it. Walking its
        # controls with the dial is Omarchy-only for now, so every turn and click opens it.
        launch(["redial-settings"])
        return
    if op == "open" or not settings_window_focused():
        launch(["omarchy-shell", "-q", "dialtools", "open"])
        hypr(f'hl.dsp.focus({{ window = "title:^{SETTINGS_TITLE}$" }})')
        return
    key(*SETTINGS_KEYS[op])


def _compile_settings(spec):
    op = spec.get("op")
    if op != "open" and op not in SETTINGS_KEYS:
        log(f"settings needs an op from open, {', '.join(SETTINGS_KEYS)}: {spec!r}")
        return None
    return lambda mag, _o=op: settings_action(_o)


MEDIA_OPS = ("play-pause", "next", "previous")


def _compile_media(spec):
    op = spec.get("op")
    if op not in MEDIA_OPS:
        log(f"media needs an op from {MEDIA_OPS}: {spec!r}")
        return None
    return lambda mag, _o=op: media_command(_o)


def _compile_resize(spec):
    axis = str(spec.get("axis", "x")).lower()
    if axis not in ("x", "y"):
        log(f'resize axis must be "x" or "y": {spec!r}')
        return None
    grow = _direction_up(spec, "grow", "shrink")
    step = _spec_number(spec, "step", RESIZE_STEP, int)
    return lambda mag, _a=axis, _g=grow, _s=step: backend().op("resize", axis=_a, grow=_g, step=_s)


def _compile_volume(spec):
    up = _direction_up(spec)
    return lambda mag, _u=up: vol(max(1, int(mag)), _u)


def _compile_dictation(spec):
    return lambda mag: dictation_toggle()


def _compile_mouse(spec):
    btn = mouse_button(spec)
    if btn is None:
        log(f"mouse needs button left|right|middle: {spec!r}")
        return None

    def _click(mag, _b=btn):
        POINTER.click(_b, True)
        POINTER.click(_b, False)

    return _click


def _compile_assistant(spec):
    """Run the user's own assistant command, read from the config each time it is used.

    Which assistant is entirely theirs (a local model in a terminal, a chat app, a web page):
    config.json "assistant": {"cmd": ["..."], "label": "..."}. With none set it says how to set
    one instead of guessing.
    """

    def start(mag):
        conf = live_config().get("assistant")
        cmd = conf.get("cmd") if isinstance(conf, dict) else None
        if not cmd or not _is_string_list(cmd):
            notify("Quick assistant", 'Not set up: add an "assistant" command to config.json')
            return
        launch(list(cmd))

    return start


def kick_dial_async(why):
    # In a thread: bluetoothctl can take seconds, and the dial's own read loop must not wait.
    threading.Thread(target=kick_dial, args=(why,), daemon=True).start()


def _compile_reconnect(spec):
    return lambda mag: kick_dial_async("reconnect asked for")


def _compile_wheel(spec):
    # The continuous path owns the pointer; this only marks the tool.
    return lambda mag: None


_ACTION_VERBS = {
    "exec": _compile_exec,
    "hypr": _compile_hypr,
    "wm": _compile_wm,
    "key": _compile_key,
    "brightness": _compile_brightness,
    "seek": _compile_seek,
    "media": _compile_media,
    "settings": _compile_settings,
    "resize": _compile_resize,
    "volume": _compile_volume,
    "dictation": _compile_dictation,
    "mouse": _compile_mouse,
    "assistant": _compile_assistant,
    "reconnect": _compile_reconnect,
    "wheel": _compile_wheel,
}


def make_action(spec):
    """Compile an action spec to a callable(magnitude), or None for no action."""
    if not spec:
        return None
    if not isinstance(spec, dict):
        log(f"action must be an object, got {type(spec).__name__}: {spec!r}")
        return None
    verb = str(spec.get("do", "none")).lower()
    if verb in ("none", ""):
        return None
    compile_verb = _ACTION_VERBS.get(verb)
    if compile_verb is None:
        log(f"unknown action verb {verb!r}; ignoring")
        return None
    return compile_verb(spec)


# Every tool the daemon knows how to build, keyed by "name" for
# "active_tools" selection (see build_tools/load_tools below). This is the
# full shipped set; with no config file at all, every one of these is active
# and in this order -- the config only ever narrows or reorders it.
TOOL_LIBRARY = [
    {
        "name": "Volume",
        "description": (
            "Turn for volume; fast spins change it in bigger steps. Click mutes. This is the "
            "resting "
            "tool every other tool returns to."
        ),
        "icon": "\uf028",
        "detent": 60,
        "magnitude": True,
        "cw": {"do": "volume", "direction": "up"},
        "ccw": {"do": "volume", "direction": "down"},
        "click": {
            "do": "exec",
            "label": "mute",
            "cmd": ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"],
        },
    },
    {
        "name": "Windows",
        "description": "Cycle focus through your open windows. Click maximizes the focused window.",
        "icon": "\uf2d0",
        "detent": 150,
        "cw": {"do": "wm", "op": "cycle", "forward": True},
        "ccw": {"do": "wm", "op": "cycle", "forward": False},
        "click": {
            "do": "wm",
            "label": "maximize",
            "op": "maximize",
        },
    },
    {
        "name": "Workspaces",
        "description": (
            "Switch to the next or previous workspace. Click jumps back to the last one."
        ),
        "icon": "\uf00a",
        "detent": 450,
        # Deliberately unscaled by speed: "+1" can create workspaces, so a fast
        # spin under magnitude scaling would fling you into workspace 20.
        "cw": {"do": "wm", "op": "workspace", "to": "+1"},
        "ccw": {"do": "wm", "op": "workspace", "to": "-1"},
        "click": {
            "do": "wm",
            "label": "last workspace",
            "op": "workspace",
            "to": "previous",
        },
    },
    {
        # Keyboard scrolling follows keyboard FOCUS and only works where arrow
        # keys scroll; in a terminal they walk shell history instead. Real wheel
        # events need the uinput virtual pointer, which the continuous path uses.
        "name": "Scroll",
        "return_s": READING_RETURN_S,
        "description": "Smooth scrolling under the mouse pointer, faster when you turn faster.",
        "icon": "\uf07d",
        "detent": 60,
        "magnitude": True,
        "continuous": True,
        # Routes through scroll_mode() first, to suppress on the one known
        # class where a real wheel event would still land as destructive
        # keys downstream -- see SCROLL_SUPPRESS_CLASSES above.
        "terminal_aware": True,
        # Click flips to sideways (was the H Scroll tool until 2026-10-23); clockwise goes right.
        "axis_toggle": True,
        "alt": {
            "base_title": "\u2195  Scroll",
            "base_subtitle": "up / down",
            "title": "\u2194  Scroll",
            "subtitle": "sideways",
        },
        "cw": {"do": "wheel"},
        "ccw": {"do": "wheel"},
        "click": {"do": "none", "label": "flip up-down/sideways"},
    },
    {
        "name": "Undo",
        "description": "Counter-clockwise undoes, clockwise redoes.",
        "icon": "\uf0e2",
        "detent": 150,
        # Nothing in a terminal: there Ctrl+Z suspends the running program (an editor, a build).
        "cw": {"do": "key", "keys": ["ctrl", "shift", "z"], "terminal_keys": []},
        "ccw": {"do": "key", "keys": ["ctrl", "z"], "terminal_keys": []},
        "click": None,
    },
    {
        # Ctrl+scroll held while armed, not Ctrl+=/- (apps like Obsidian's Graph view ignore that).
        "name": "Zoom",
        "description": (
            "Zoom in and out (it holds Ctrl while armed, so it hands back to Volume after 10 "
            "seconds). Click resets the zoom."
        ),
        "icon": "\uf00e",
        "detent": 60,
        "magnitude": True,
        "continuous": True,
        "hold_mod": "ctrl",
        "gain": ZOOM_GAIN,
        "invert": True,
        "cw": {"do": "wheel"},
        "ccw": {"do": "wheel"},
        "click": {"do": "key", "label": "reset zoom", "keys": ["ctrl", "0"]},
    },
    {
        # Scrubs the playhead; takes magnitude so a fast spin jumps further.
        "name": "Media",
        "description": (
            "Scrub through the song or video that is playing; fast spins jump further. Click plays "
            "or pauses."
        ),
        "icon": "\uf001",
        "detent": 60,
        "magnitude": True,
        "cw": {"do": "seek", "direction": "forward"},
        "ccw": {"do": "seek", "direction": "back"},
        "click": {"do": "media", "label": "play/pause", "op": "play-pause"},
    },
    {
        # The dial's own way into settings, so nobody has to let go of it for the keyboard. A tool
        # rather than a fixed ring item: leave it off a ring that someone else should not change.
        "name": "Settings",
        "description": (
            "Opens re:dial's settings. Turn to move between controls, click to press one, so the "
            "dial can set itself up. Remove it from the ring to keep settings out of reach."
        ),
        "icon": "\uf013",
        "detent": 120,
        "return_s": READING_RETURN_S,  # you stop to read the window between turns
        "on_arm": {"do": "settings", "op": "open"},
        "cw": {"do": "settings", "op": "next"},
        "ccw": {"do": "settings", "op": "prev"},
        "click": {"do": "settings", "label": "press", "op": "press"},
    },
    {
        # Word Nav and Select in one (2026-10-23): click flips moving and selecting, a double
        # click copies. Built for the pen in one hand and no keyboard, like Zoom. No magnitude,
        # as Undo: a steady word per detent beats fast spins skipping an unknown number of words.
        "name": "Text",
        "default": False,
        "description": (
            "Move the text cursor a word at a time. Click flips between moving and selecting; "
            "double-click copies what you selected."
        ),
        "icon": "\uf035",
        "detent": 60,
        "axis_toggle": True,
        "cw": {"do": "key", "keys": ["ctrl", "Right"]},
        "ccw": {"do": "key", "keys": ["ctrl", "Left"]},
        "alt": {
            "base_title": "\u21c4  Text",
            "base_subtitle": "move a word",
            "title": "\u21c4  Text",
            "subtitle": "select a word",
            "cw": {"do": "key", "keys": ["ctrl", "shift", "Right"]},
            "ccw": {"do": "key", "keys": ["ctrl", "shift", "Left"]},
        },
        "clicks": {"double": "copy"},
        "click": {"do": "none", "label": "flip move/select"},
    },
    {
        # Click flips vertical/horizontal, handled in Dial (arrow_horizontal) because the do/cw/ccw
        # vocabulary has no persistent state. cw/ccw are the vertical default.
        "name": "Arrow Keys",
        "default": False,
        "description": "Press the arrow keys. Click flips between up/down and left/right.",
        "icon": "\uf047",
        "detent": 60,
        "axis_toggle": True,
        "cw": {"do": "key", "keys": ["Down"]},
        "ccw": {"do": "key", "keys": ["Up"]},
        "click": {"do": "none", "label": "toggle vertical/horizontal"},
    },
    {
        # Click flips the axis (alt axis is data). cw always grows; resize_active() picks the edge.
        # Fixed RESIZE_STEP per detent, no magnitude.
        "name": "Window Size",
        "default": False,
        "description": "Resize the focused window. Click flips between width and height.",
        "icon": "\uf065",
        "detent": 60,
        "axis_toggle": True,
        "cw": {"do": "resize", "axis": "x", "direction": "grow"},
        "ccw": {"do": "resize", "axis": "x", "direction": "shrink"},
        "alt": {
            "base_title": "\u2194  Window Size",
            "base_subtitle": "width",
            "title": "\u2195  Window Size",
            "subtitle": "height",
            "cw": {"do": "resize", "axis": "y", "direction": "grow"},
            "ccw": {"do": "resize", "axis": "y", "direction": "shrink"},
        },
        "click": {"do": "none", "label": "toggle width/height"},
    },
    {
        # Needs a backlight: laptops have an intel one that desktops lack, so this only
        # shows up where active_tools names it.
        # Magnitude like Volume: a faster spin takes bigger steps. The device is
        # always named explicitly (see backlight_device()).
        "name": "Brightness",
        "default": "backlight",  # on the ring only where there is a backlight to turn
        "description": "Screen brightness, where the machine has a backlight (laptops).",
        "icon": "\uf185",
        "detent": 60,
        "magnitude": True,
        "cw": {"do": "brightness", "direction": "up"},
        "ccw": {"do": "brightness", "direction": "down"},
        "click": None,
    },
    # --- tools for pointing and sideways scrolling, off by default like the ones below.
    {
        # Moves the mouse pointer. Its own clicks: click presses the left button, a double click
        # flips left/right and up/down, a triple click is a right click. Slow turns are fine
        # steps, fast spins cross the screen.
        "name": "Pointer",
        "description": (
            "Move the mouse pointer: small turns are fine steps, fast spins cross the screen. "
            "Click to left-click, double-click to flip between left/right and up/down, "
            "triple-click to right-click."
        ),
        "clicks": {"single": "mouse_left", "double": "tool", "triple": "mouse_right"},
        "icon": "\uf245",
        "detent": 60,
        "continuous": True,
        "pointer": True,
        "default": False,
        "gain": POINTER_GAIN,
        "axis_toggle": True,
        "alt": {
            "base_title": "\u2194  Pointer",
            "base_subtitle": "left / right",
            "title": "\u2195  Pointer",
            "subtitle": "up / down",
        },
        "cw": {"do": "wheel"},
        "ccw": {"do": "wheel"},
        "click": {"do": "none", "label": "flip left-right/up-down"},
    },
    # --- tools added for people who need to drive a whole session from the dial. Not in the
    # default set (the ring stays the size it was); add them in the settings window.
    {
        # Operate any form, dialog or toolbar with the dial alone: turn to move focus,
        # click to activate.
        "name": "Focus",
        "description": (
            "Move between buttons and fields with Tab and Shift+Tab. Click presses Enter, so any "
            "dialog can be used with the dial alone."
        ),
        "icon": "\uf11c",
        "detent": 60,
        "default": False,
        "cw": {"do": "key", "keys": ["Tab"]},
        "ccw": {"do": "key", "keys": ["shift", "Tab"]},
        "click": {"do": "key", "label": "activate (Enter)", "keys": ["Return"]},
    },
    {
        "name": "Tabs",
        "description": "Switch to the next or previous tab in a browser or editor.",
        "icon": "\uf24d",
        "detent": 60,
        "default": False,
        "cw": {"do": "key", "keys": ["ctrl", "Tab"]},
        "ccw": {"do": "key", "keys": ["ctrl", "shift", "Tab"]},
        "click": None,
    },
    {
        "name": "Pages",
        "return_s": READING_RETURN_S,
        "description": "Page Down and Page Up.",
        "icon": "\uf15c",
        "detent": 60,
        "default": False,
        "cw": {"do": "key", "keys": ["Page_Down"]},
        "ccw": {"do": "key", "keys": ["Page_Up"]},
        "click": None,
    },
    {
        # Move focus to the neighbouring tile. Click flips left/right and up/down, like Arrow Keys.
        "name": "Tile Focus",
        "description": (
            "Move focus between tiled windows. Click flips between left/right and up/down."
        ),
        "icon": "\uf2d0",
        "detent": 60,
        "default": False,
        "axis_toggle": True,
        "cw": {"do": "wm", "op": "focus", "dir": "r"},
        "ccw": {"do": "wm", "op": "focus", "dir": "l"},
        "alt": {
            "base_title": "\u2194  Tile Focus",
            "base_subtitle": "left / right",
            "title": "\u2195  Tile Focus",
            "subtitle": "up / down",
            "cw": {"do": "wm", "op": "focus", "dir": "d"},
            "ccw": {"do": "wm", "op": "focus", "dir": "u"},
        },
        "click": {"do": "none", "label": "toggle left-right/up-down"},
    },
    {
        # Carry the focused window to the next or previous workspace, and follow it. Click flips
        # to moving it around the current workspace: each detent swaps it with the next or
        # previous window in the workspace's order, so it walks through every position however
        # many windows there are (the way the Windows tool walks focus through them).
        "name": "Move Window",
        "description": (
            "Carry the focused window to the next or previous workspace and follow it. "
            "Click flips to moving it through the positions of this workspace."
        ),
        "icon": "\uf064",
        "detent": 60,
        "default": False,
        "axis_toggle": True,
        "cw": {"do": "wm", "op": "send", "to": "+1"},
        "ccw": {"do": "wm", "op": "send", "to": "-1"},
        "alt": {
            "base_title": "\u21c4  Move Window",
            "base_subtitle": "to another workspace",
            "title": "\u25a6  Move Window",
            "subtitle": "around this workspace",
            "cw": {"do": "wm", "op": "swap", "forward": True},
            "ccw": {"do": "wm", "op": "swap", "forward": False},
        },
        "click": {"do": "none", "label": "toggle workspaces/tiles"},
    },
]


# The ring with no config: the everyday tools (v1 trimmed Word Nav, Arrow Keys and Window Size
# out, they overlap Select, Pages and Tile Focus and stay one click away in settings), plus
# Brightness where the machine has a backlight.
def _action_kinds(x, acc=None):
    """Every action `do` a tool spec uses, however deeply its clicks and turns nest them."""
    acc = set() if acc is None else acc
    if isinstance(x, dict):
        if isinstance(x.get("do"), str):
            acc.add(x["do"])
        for v in x.values():
            _action_kinds(v, acc)
    elif isinstance(x, list):
        for v in x:
            _action_kinds(v, acc)
    return acc


def works_here(tool):
    """Whether a tool can act on this desktop.

    Window tools need a window-manager backend (none on GNOME, KDE or COSMIC yet), and Settings
    needs a settings window: Omarchy's, or redial-settings elsewhere.
    """
    kinds = _action_kinds(tool)
    if kinds & {"wm", "resize"} and not backend().supported:
        return False
    if "settings" in kinds and backend().name == "none" and not shutil.which("redial-settings"):
        return False
    return True


def default_tools(has_backlight=None):
    if has_backlight is None:
        has_backlight = backlight_device() is not None
    return [
        t
        for t in TOOL_LIBRARY
        if (t.get("default", True) is True or (t.get("default") == "backlight" and has_backlight))
        and works_here(t)
    ]


# Tools merged into another, so rings saved with the old names keep working.
TOOL_RENAMED = {"Word Nav": "Text", "Select": "Text", "H Scroll": "Scroll"}

DEFAULT_TOOLS = default_tools()


# --- click gestures ---
# "clicks": {"single": "tool", "double": ..., "triple": ...} in config.json, re-read live.
# (name, label, description, action spec), published to clicks.json for the settings window.
# "tool" (single only) runs the armed tool's own click.
CLICK_ACTIONS = [
    ("tool", "Tool's own click", "What the armed tool does on click.", None),
    ("dictation", "Dictation on/off", "Start or stop voice dictation.", {"do": "dictation"}),
    ("enter", "Enter", "Press Enter (submits dictation).", {"do": "key", "keys": ["Return"]}),
    ("escape", "Escape", "Press Escape.", {"do": "key", "keys": ["Escape"]}),
    ("backspace", "Backspace", "Delete one character.", {"do": "key", "keys": ["BackSpace"]}),
    ("space", "Space", "Press Space.", {"do": "key", "keys": ["space"]}),
    ("tab", "Tab", "Press Tab.", {"do": "key", "keys": ["Tab"]}),
    (
        "mute",
        "Mute",
        "Toggle output mute.",
        {"do": "exec", "cmd": ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]},
    ),
    (
        "mic_mute",
        "Mute microphone",
        "Toggle the microphone on and off (for calls).",
        {"do": "exec", "cmd": ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]},
    ),
    (
        "play_pause",
        "Play / pause",
        "Play or pause the player.",
        {"do": "media", "op": "play-pause"},
    ),
    (
        "next_track",
        "Next track",
        "Skip to the next track.",
        {"do": "media", "op": "next"},
    ),
    (
        "prev_track",
        "Previous track",
        "Go back to the previous track.",
        {"do": "media", "op": "previous"},
    ),
    (
        "maximize",
        "Maximize window",
        "Maximize the focused window.",
        {"do": "hypr", "lua": 'hl.dsp.window.fullscreen({ mode = "maximized" })'},
    ),
    (
        "launcher",
        "Omarchy menu",
        "Open the Omarchy menu (apps, settings, system).",
        {"do": "exec", "cmd": ["omarchy-menu", "toggle"]},
    ),
    (
        "screenshot",
        "Screenshot",
        "Take a screenshot.",
        {"do": "exec", "cmd": ["omarchy-capture-screenshot"]},
    ),
    (
        "copy",
        "Copy",
        "Copy the selection (Ctrl+Insert in a terminal, so it never interrupts a program).",
        {"do": "key", "keys": ["ctrl", "c"], "terminal_keys": ["ctrl", "Insert"]},
    ),
    (
        "paste",
        "Paste",
        "Paste (Shift+Insert in a terminal).",
        {"do": "key", "keys": ["ctrl", "v"], "terminal_keys": ["shift", "Insert"]},
    ),
    ("cut", "Cut", "Cut the selection.", {"do": "key", "keys": ["ctrl", "x"]}),
    (
        "select_all",
        "Select all",
        "Select everything (does nothing in a terminal).",
        {"do": "key", "keys": ["ctrl", "a"], "terminal_keys": []},
    ),
    (
        "redo",
        "Redo",
        "Redo (does nothing in a terminal).",
        {"do": "key", "keys": ["ctrl", "shift", "z"], "terminal_keys": []},
    ),
    (
        "tab_next",
        "Next tab",
        "Switch to the next tab.",
        {"do": "key", "keys": ["ctrl", "Tab"]},
    ),
    (
        "tab_prev",
        "Previous tab",
        "Switch to the previous tab.",
        {"do": "key", "keys": ["ctrl", "shift", "Tab"]},
    ),
    (
        "fullscreen",
        "Fullscreen",
        "Toggle fullscreen for the focused window.",
        {"do": "hypr", "lua": 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'},
    ),
    (
        "float",
        "Float / tile",
        "Toggle the focused window between floating and tiled.",
        {"do": "hypr", "lua": 'hl.dsp.window.float({ action = "toggle" })'},
    ),
    ("mouse_left", "Left click", "Press the left mouse button.", {"do": "mouse", "button": "left"}),
    (
        "mouse_right",
        "Right click",
        "Press the right mouse button.",
        {"do": "mouse", "button": "right"},
    ),
    (
        "mouse_middle",
        "Middle click",
        "Press the middle mouse button.",
        {"do": "mouse", "button": "middle"},
    ),
    (
        "terminal",
        "Open a terminal",
        "Open a new terminal window.",
        {"do": "exec", "cmd": ["omarchy-launch-terminal"]},
    ),
    (
        "browser",
        "Open the browser",
        "Open the web browser.",
        {"do": "exec", "cmd": ["omarchy-launch-browser"]},
    ),
    (
        "files",
        "Open files",
        "Open the file manager.",
        {"do": "exec", "cmd": ["omarchy-launch-nautilus"]},
    ),
    (
        "assistant",
        "Quick assistant",
        "Open your chat or AI assistant (set the command in config.json).",
        {"do": "assistant"},
    ),
    (
        "reconnect_dial",
        "Reconnect dial",
        "Drop the dial's Bluetooth link; press it to reconnect. For when turning stops working.",
        {"do": "reconnect"},
    ),
    ("none", "Nothing", "Do nothing.", None),
]


def custom_launcher_actions(doc):
    """Click actions for the user's own "launchers": [{"name", "label", "cmd": [...]}].

    Each becomes a click action named launch_<name> that runs `cmd` (a list, never a shell
    string). Read once at startup, so adding one needs a daemon restart. Bad entries are
    skipped with a log line rather than aborting the rest.
    """
    raw = doc.get("launchers")
    if raw is None:
        return []
    if not isinstance(raw, list):
        log("launchers must be a list; ignored")
        return []
    out, taken = [], {a[0] for a in CLICK_ACTIONS}
    for i, item in enumerate(raw[:MAX_LAUNCHERS]):
        cmd = item.get("cmd") if isinstance(item, dict) else None
        if not cmd or not _is_string_list(cmd):
            log(f"launchers[{i}] needs a non-empty list of strings for cmd; skipped")
            continue
        title = str(item.get("name") or item.get("label") or "").strip()
        slug = re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")
        key = f"launch_{slug}"
        if not slug or key in taken:
            log(f"launchers[{i}] needs a unique name ({title!r}); skipped")
            continue
        taken.add(key)
        label = str(item.get("label") or title)
        out.append((key, label, f"Run {cmd[0]}.", {"do": "exec", "cmd": list(cmd)}))
    return out


CLICK_ACTIONS[-1:-1] = custom_launcher_actions(load_config())
CLICK_DEFAULTS = {"single": "tool", "double": "dictation", "triple": "enter"}
_CLICK_BY_NAME = {a[0]: a for a in CLICK_ACTIONS}
_click_cache = {}
_click_fns = {}


def tool_clicks_spec(raw, where):
    """{kind: action name} for one tool's clicks, keeping only usable entries ("tool" included)."""
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        log(f"{where}: {raw!r} is not an object; ignored")
        return {}
    out = {}
    for k, v in raw.items():
        if k in CLICK_DEFAULTS and isinstance(v, str) and v in _CLICK_BY_NAME:
            out[k] = v
        else:
            log(f"{where}.{k}: {v!r} is not a usable action; ignored")
    return out


def click_choice(kind, tool=None):
    """Action name for a "single" | "double" | "triple" click while `tool` is armed.

    In order: your choice for that tool (config "tool_clicks"), the tool's own default (its
    "clicks"), then the click for every tool (config "clicks"). "tool" means the tool's own click.
    """

    def build(doc):
        raw = doc.get("clicks")
        raw = raw if isinstance(raw, dict) else {}
        choice = dict(CLICK_DEFAULTS)
        for k in CLICK_DEFAULTS:
            v = raw.get(k)
            if isinstance(v, str) and v in _CLICK_BY_NAME and not (v == "tool" and k != "single"):
                choice[k] = v
            elif v is not None:
                log(f"clicks.{k}: {v!r} is not a usable action; using {CLICK_DEFAULTS[k]!r}")
        per = doc.get("tool_clicks")
        per = per if isinstance(per, dict) else {}
        return choice, {t: tool_clicks_spec(v, f"tool_clicks.{t}") for t, v in per.items()}

    choice, per_tool = live_derived(_click_cache, build)
    if tool:
        own = per_tool.get(tool["name"], {}).get(kind) or tool.get("clicks", {}).get(kind)
        if own:
            return own
    return choice[kind]


def click_fn(name):
    """Compiled action for a click choice, or None (nothing / tool's own)."""
    if name not in _click_fns:
        spec = _CLICK_BY_NAME[name][3]
        _click_fns[name] = make_action(spec) if spec else None
    return _click_fns[name]


def click_hint(tool):
    """Click label the overlay shows for `tool`, honouring a single-click override."""
    name = click_choice("single", tool)
    return tool["click_label"] if name == "tool" else _CLICK_BY_NAME[name][1]


# --- pen button gestures ---
# Like the dial's clicks: configurable, live, published to pen_clicks.json. Reuses
# CLICK_ACTIONS minus the dial-specific "tool".
# The pen's barrel list already has its own mouse buttons, so the dial's are left out of it.
_PEN_SHARED_ACTIONS = [a for a in CLICK_ACTIONS if a[0] != "tool" and not a[0].startswith("mouse_")]

# Tail button: firmware only ever reports single / double / press-and-hold --
# there is no raw click counter, so there is no real "triple click" to detect,
# only these three slots to make configurable. Defaults reproduce the old
# hardcoded behaviour exactly (see the accident-risk reasoning above PEN_BUTTON).
PEN_TAIL_ACTIONS = _PEN_SHARED_ACTIONS + [
    (
        "menu",
        "Omarchy menu",
        "Toggle the Omarchy menu.",
        {"do": "exec", "cmd": ["omarchy-menu", "toggle"]},
    ),
]
PEN_TAIL_DEFAULTS = {"single": "space", "double": "enter", "hold": "dictation"}
# Hold defaults to Dictation: the old Omarchy-menu default was easy to trigger by accident
# and includes power entries. See docs/DESIGN.md#pen-buttons.
_PEN_TAIL_BY_NAME = {a[0]: a for a in PEN_TAIL_ACTIONS}
_pen_tail_cache = {}
_pen_tail_fns = {}


def pen_tail_choice(slot):
    """Configured action name for the tail button's "single"|"double"|"hold"."""

    def build(doc):
        raw = _pen_section(doc).get("tail_clicks")
        raw = raw if isinstance(raw, dict) else {}
        choice = dict(PEN_TAIL_DEFAULTS)
        for k in PEN_TAIL_DEFAULTS:
            v = raw.get(k)
            if isinstance(v, str) and v in _PEN_TAIL_BY_NAME:
                choice[k] = v
            elif v is not None:
                log(
                    f"pen.tail_clicks.{k}: {v!r} is not a usable action; "
                    f"using {PEN_TAIL_DEFAULTS[k]!r}"
                )
        return choice

    return live_derived(_pen_tail_cache, build)[slot]


def pen_tail_fn(slot):
    """Compiled action for the tail button's configured slot, or None (unbound)."""
    name = pen_tail_choice(slot)
    if name not in _pen_tail_fns:
        spec = _PEN_TAIL_BY_NAME[name][3]
        _pen_tail_fns[name] = make_action(spec) if spec else None
    return _pen_tail_fns[name]


# Eraser (the back of the pen): a short tap and a long press, each configurable, or "Nothing".
# Defaults keep the original behaviour. Applies live, no restart.
PEN_ERASER_ACTIONS = [
    ("none", "Nothing", "Do nothing.", None),
    ("escape", "Escape", "Press Escape (cancel, close a menu).", {"do": "key", "keys": ["Escape"]}),
    (
        "delete_word",
        "Delete word",
        "Delete the word before the cursor (Ctrl+Backspace).",
        {"do": "key", "keys": ["ctrl", "BackSpace"]},
    ),
] + [a for a in _PEN_SHARED_ACTIONS if a[0] not in ("none", "escape", "delete_word")]
PEN_ERASER_DEFAULTS = {"tap": "escape", "hold": "delete_word"}
_PEN_ERASER_BY_NAME = {a[0]: a for a in PEN_ERASER_ACTIONS}
_pen_eraser_cache = {}
_pen_eraser_fns = {}


def pen_eraser_config():
    """(tap action, hold action, minimum tap seconds, scroll speed multiplier), live-reloaded."""

    def build(doc):
        pen = _pen_section(doc)
        raw = pen.get("eraser")
        raw = raw if isinstance(raw, dict) else {}
        choice = dict(PEN_ERASER_DEFAULTS)
        for k in PEN_ERASER_DEFAULTS:
            v = raw.get(k)
            if isinstance(v, str) and v in _PEN_ERASER_BY_NAME:
                choice[k] = v
            elif v is not None:
                log(f"pen.eraser.{k}: {v!r} is not usable; using {PEN_ERASER_DEFAULTS[k]!r}")
        ms = pen.get("eraser_tap_min_ms")
        ok = isinstance(ms, (int, float)) and not isinstance(ms, bool) and 0 <= ms <= 500
        speed = pen.get("eraser_scroll_speed")
        speed_ok = (
            isinstance(speed, (int, float)) and not isinstance(speed, bool) and 0.25 <= speed <= 4
        )
        return (
            choice["tap"],
            choice["hold"],
            (ms if ok else ERASER_TAP_MIN_MS_DEFAULT) / 1000.0,
            speed if speed_ok else 1.0,
        )

    return live_derived(_pen_eraser_cache, build)


def pen_eraser_fn(name):
    """Compiled action for an eraser slot, or None (Nothing)."""
    if name not in _pen_eraser_fns:
        spec = _PEN_ERASER_BY_NAME[name][3]
        _pen_eraser_fns[name] = make_action(spec) if spec else None
    return _pen_eraser_fns[name]


# Barrel button: one physical click, so one configurable action plus an
# enable toggle -- not split into click vs. long-press. Default reproduces
# the old hardcoded behaviour (always right-click) exactly.
PEN_BARREL_ACTIONS = _PEN_SHARED_ACTIONS + [
    ("right_click", "Right click", "Right mouse click.", {"do": "mouse", "button": "right"}),
    ("middle_click", "Middle click", "Middle mouse click.", {"do": "mouse", "button": "middle"}),
    ("left_click", "Left click", "Left mouse click.", {"do": "mouse", "button": "left"}),
]
PEN_BARREL_DEFAULT = "right_click"
_PEN_BARREL_BY_NAME = {a[0]: a for a in PEN_BARREL_ACTIONS}
_pen_barrel_cache = {}
_pen_barrel_fns = {}


def pen_barrel_config():
    """(enabled, action name) for the stylus barrel button, live-reloaded."""

    def build(doc):
        raw = _pen_section(doc).get("barrel")
        raw = raw if isinstance(raw, dict) else {}
        enabled = bool(raw.get("enabled", True))
        action = raw.get("action")
        if not (isinstance(action, str) and action in _PEN_BARREL_BY_NAME):
            if action is not None:
                log(
                    f"pen.barrel.action: {action!r} is not a usable action; "
                    f"using {PEN_BARREL_DEFAULT!r}"
                )
            action = PEN_BARREL_DEFAULT
        return enabled, action

    return live_derived(_pen_barrel_cache, build)


# Barrel hold (Brooks 2026-11-15, "a power button"): the system's own right-click on press is
# never touched; holding the barrel while hovering can also run one action. Mouse buttons are
# left out: a hold can't be a click. Off ("none") by default, so the barrel works as before.
PEN_BARREL_HOLD_ACTIONS = _PEN_SHARED_ACTIONS
PEN_BARREL_HOLD_DEFAULT = "none"
PEN_BARREL_HOLD_MS = (500, 250, 1500)  # default, min, max
_PEN_BARREL_HOLD_BY_NAME = {a[0]: a for a in PEN_BARREL_HOLD_ACTIONS}
_pen_barrel_hold_cache = {}


def pen_barrel_hold():
    """(action name, seconds) for holding the barrel button, live-reloaded."""

    def build(doc):
        raw = _pen_section(doc).get("barrel")
        raw = raw if isinstance(raw, dict) else {}
        name = raw.get("hold", PEN_BARREL_HOLD_DEFAULT)
        if not (isinstance(name, str) and name in _PEN_BARREL_HOLD_BY_NAME):
            log(f"pen.barrel.hold: {name!r} is not a usable action; using nothing")
            name = PEN_BARREL_HOLD_DEFAULT
        ms, lo, hi = PEN_BARREL_HOLD_MS
        v = raw.get("hold_ms")
        if isinstance(v, int | float) and not isinstance(v, bool) and math.isfinite(v):
            ms = min(max(v, lo), hi)
        return name, ms / 1000

    return live_derived(_pen_barrel_hold_cache, build)


def pen_barrel_fn(name):
    """Compiled action for the barrel button's configured action, or None."""
    if name not in _pen_barrel_fns:
        spec = (_PEN_BARREL_BY_NAME.get(name) or _PEN_BARREL_HOLD_BY_NAME[name])[3]
        _pen_barrel_fns[name] = make_action(spec) if spec else None
    return _pen_barrel_fns[name]


def build_alt(spec):
    """Compile a tool's optional alternate-axis block (used with "axis_toggle")."""
    if not isinstance(spec, dict):
        return None
    return {
        "cw": make_action(spec.get("cw")),
        "ccw": make_action(spec.get("ccw")),
        "title": str(spec.get("title", "")),
        "subtitle": str(spec.get("subtitle", "")),
        "base_title": str(spec.get("base_title", "")),
        "base_subtitle": str(spec.get("base_subtitle", "")),
    }


def build_tools(specs):
    """Compile tool specs into the runtime tool table.

    A tool that fails to compile is skipped with a log line rather than
    aborting - losing one tool is recoverable, losing the daemon is not.
    """
    out = []
    for i, t in enumerate(specs or []):
        if not isinstance(t, dict):
            log(f"tool #{i} is not an object; skipped")
            continue
        name = str(t.get("name") or f"Tool {i + 1}")
        try:
            detent = int(t.get("detent", 60))
        except CAST_ERRORS:
            detent = 60
        click_spec = t.get("click")
        label = ""
        if isinstance(click_spec, dict):
            label = str(click_spec.get("label", "") or "")
        try:
            gain = float(t.get("gain", SCROLL_GAIN))
        except CAST_ERRORS:
            gain = SCROLL_GAIN
        hold_mod = t.get("hold_mod")
        ret = t.get("return_s")
        out.append(
            {
                "name": name,
                "icon": str(t.get("icon", "")),
                "detent": max(1, detent),
                "mag": bool(t.get("magnitude", False)),
                "continuous": bool(t.get("continuous", False)),
                "terminal_aware": bool(t.get("terminal_aware", False)),
                "horizontal": bool(t.get("horizontal", False)),
                "pointer": bool(t.get("pointer", False)),
                "axis_toggle": bool(t.get("axis_toggle", False)),
                "clicks": tool_clicks_spec(t.get("clicks"), f"tool {name!r} clicks"),
                "alt": build_alt(t.get("alt")),
                "gain": gain,
                "invert": bool(t.get("invert", False)),
                "hold_mod": hold_mod if isinstance(hold_mod, str) and hold_mod else None,
                "on_arm": make_action(t.get("on_arm")),
                "return_s": ret
                if isinstance(ret, int | float) and not isinstance(ret, bool)
                else None,
                "cw": make_action(t.get("cw")),
                "ccw": make_action(t.get("ccw")),
                "click": make_action(click_spec),
                "click_label": label or "\u2014",
            }
        )
    if not out:
        log("no usable tools in config; falling back to the built-in set")
        return build_tools(DEFAULT_TOOLS)
    return out


def write_tool_manifest():
    """Publish {name, icon, description, default} for every library tool alongside the config.

    This is what the Quickshell tool-picker panel reads to know what it can
    offer -- so the picker never hardcodes a tool list of its own, and a new
    tool added here shows up there automatically. Best-effort: a failure to
    write it costs the picker a stale list, not the daemon.
    """
    here = os.path.dirname(CONFIG_PATH)

    def actions(rows):
        return [{"name": n, "label": lbl, "description": d} for n, lbl, d, _ in rows]

    manifests = {
        "tools.json": [
            {
                "name": t["name"],
                "icon": t.get("icon", ""),
                "description": t.get("description", ""),
                "default": t in DEFAULT_TOOLS,
                "works_here": works_here(t),
                "clicks": t.get("clicks", {}),  # the tool's own click defaults
                "replaces": sorted(k for k, v in TOOL_RENAMED.items() if v == t["name"]),
            }
            for t in TOOL_LIBRARY
        ],
        # The picker lists click gestures from here, never hardcodes them.
        "clicks.json": {"defaults": CLICK_DEFAULTS, "actions": actions(CLICK_ACTIONS)},
        # Same for the pen's two configurable buttons.
        "pen_clicks.json": {
            "tail": {"defaults": PEN_TAIL_DEFAULTS, "actions": actions(PEN_TAIL_ACTIONS)},
            "barrel": {
                "default": PEN_BARREL_DEFAULT,
                "actions": actions(PEN_BARREL_ACTIONS),
                "hold_default": PEN_BARREL_HOLD_DEFAULT,
                "hold_actions": actions(PEN_BARREL_HOLD_ACTIONS),
            },
            "eraser": {"defaults": PEN_ERASER_DEFAULTS, "actions": actions(PEN_ERASER_ACTIONS)},
        },
    }
    for name, doc in manifests.items():
        try:
            write_json_atomic(os.path.join(here, name), doc, indent=2)
        except OSError as exc:
            log(f"could not write {name} ({exc})")


def load_tools():
    """Tools from config if present, otherwise the built-in library.

    Called at startup and again by Dial.maybe_reload_tools() when the config
    file changes. The swap only happens while the dial is idle, because the
    state machine holds a tool index that must not shift mid-gesture.

    Two ways a config can choose tools, checked in this order:
      "tools"        - a full replacement tool list (specs, not names) -- for
                       hand-authored custom tools. Wins if present.
      "active_tools" - a list of TOOL_LIBRARY names, in the order to use them.
                       This is what the Quickshell tool picker writes: pick
                       and reorder from the built-in set without needing to
                       know the action vocabulary at all. Unknown names are
                       skipped with a log line rather than failing closed.
    With neither key, the default tools are active in their defined order: every library tool
    except those marked "default": False (the later additions), so the ring stays as it was.
    """
    doc = load_config()
    specs = doc.get("tools")
    if isinstance(specs, list) and specs:
        tools = build_tools(specs)
        log(f"loaded {len(tools)} tools from {CONFIG_PATH} (full override)")
        return tools

    active = doc.get("active_tools")
    if isinstance(active, list) and active:
        by_name = {t["name"]: t for t in TOOL_LIBRARY}
        specs = []
        for name in active:
            t = by_name.get(TOOL_RENAMED.get(str(name), str(name)))
            if t is None:
                log(f"active_tools: unknown tool {name!r}; skipped")
                continue
            if t not in specs:  # Word Nav and Select both became Text
                specs.append(t)
        if specs:
            tools = build_tools(specs)
            log(f"loaded {len(tools)} tools from {CONFIG_PATH} (active_tools)")
            return tools
        log("active_tools matched nothing; falling back to the default tools")

    return build_tools(DEFAULT_TOOLS)


write_tool_manifest()
TOOLS = load_tools()
IDLE_TOOL = 0
_tools_state = {"mtime": None}
try:
    _tools_state["mtime"] = os.stat(CONFIG_PATH).st_mtime_ns
except OSError:
    pass


class Dial:
    def __init__(self):
        self.tool = IDLE_TOOL
        self.accum = 0.0
        self.speed = 0.0
        self.last_action = 0.0
        self.menu = False
        self.menu_accum = 0.0
        self.menu_pick = IDLE_TOOL
        self.dz_accum = 0.0  # turning since the last pause, while inside the dead zone
        self.dz_last = -1e9  # time of the previous raw turn event
        self.dz_open = False  # the dead zone has been crossed for this burst of turning
        self.menu_latched = False  # menu stayed open after the opening press was released
        self.menu_moved = False  # the highlight left the starting tool since the menu opened
        self.menu_last = 0.0
        self.raw_rot_at = None  # time of the last turn event of any size (before the dead zone)
        self.stall_kick_at = -math.inf
        self.down_at = None
        self.pending_click = None
        self.pending_double = None  # second press seen; waiting to see if a third follows
        self.double_down = False  # second press is still physically down
        self.rot_events = 0
        self.rot_at_attach = None  # rot_events when the dial last attached, until the next press
        self.last_rot_log = 0.0
        self.rot_hist = deque()
        self.last_ack = -1e9  # last counted turn; the first after a quiet spell is acknowledged
        self.scroll_accum = 0.0
        self.arrow_horizontal = False

    def _arm(self, idx, now):
        """Switch the active tool, pressing/releasing any held modifier.

        Every place that changes self.tool goes through here so a tool that
        holds a modifier (Zoom -> ctrl, for Ctrl+scroll) can't get stuck
        pressed when the dial disarms or the menu picks something else.
        """
        old_mod = TOOLS[self.tool].get("hold_mod")
        new_mod = TOOLS[idx].get("hold_mod")
        if old_mod and old_mod != new_mod:
            release_mod()
        if new_mod and new_mod != old_mod:
            press_mod(new_mod)
        changed = idx != self.tool
        self.tool = idx
        if changed:
            GUIDE.armed(TOOLS[idx]["name"], idx == IDLE_TOOL)
            if TOOLS[idx].get("on_arm"):
                ACTIONS.submit(TOOLS[idx]["on_arm"], 1)
        # Always starts vertical on a fresh arm -- a toggle left over from
        # the last time Arrow Keys was armed would be a silent surprise,
        # same reasoning as nothing else staying armed across a tool switch.
        self.arrow_horizontal = False

    def detent(self):
        return max(1, round(TOOLS[self.tool]["detent"] / sensitivity()))

    def magnitude(self):
        """Units per detent, from rotation speed. Discrete tools stay at 1."""
        if not TOOLS[self.tool].get("mag"):
            return 1
        return max(1, min(MAG_MAX, 1 + int(self.speed / MAG_FALLOFF)))

    def show_tool(self, prefix=""):
        t = TOOLS[self.tool]
        speak(t["name"])
        notify(f"{t['icon']}  {t['name']}", prefix or f"click: {t['click_label']}")

    def show_connected(self):
        """Say the dial is ready, and what turning it does, when it connects or wakes."""
        t = TOOLS[self.tool]
        notify(f"{t['icon']}  re:dial ready", f"Turn to change {t['name'].lower()}")

    def show_menu(self):
        MENU_UI.highlight(self.menu_pick)
        speak(TOOLS[self.menu_pick]["name"])
        if not omarchy_shell() and not MENU_UI.overlay:
            # No overlay on this desktop: name the highlighted tool, or the ring is invisible.
            t = TOOLS[self.menu_pick]
            notify(f"{t['icon']}  {t['name']}", "release to pick it")

    def detach(self):
        """The dial went away: disarm the tool and forget half-made gestures.

        Disarming matters because Zoom holds Ctrl for as long as it is armed; the auto-return timer
        runs only while the dial is being read, so without this a dropped link mid-zoom would leave
        every key on the desktop pressed with Ctrl until the dial came back.
        """
        self._arm(IDLE_TOOL, time.monotonic())
        self.reset_gestures()

    def reset_gestures(self):
        """Forget any half-finished click or hold.

        Called on attach and detach: a dial that sleeps mid-gesture never delivers
        the release, so a stale `double_down`, `down_at` or open menu would garble
        the first gesture after it wakes (the same daemon object lives across
        reconnects).
        """
        if self.menu:
            MENU_STREAM.close()
            MENU_UI.close()
        self.menu = False
        self.menu_latched = False
        self.down_at = None
        self.pending_click = None
        self.pending_double = None
        self.double_down = False
        self.accum = 0.0
        self.last_ack = -1e9  # the first turn after a connect or wake is always acknowledged

    def disarm(self, now):
        MENU_STREAM.close()
        MENU_UI.close()
        self._arm(IDLE_TOOL, now)
        self.accum = 0.0
        self.last_action = now
        if return_buzz():
            HAPTIC.fire(PAT_IDLE, rate_limit=False)
        self.show_tool("idle")

    def through_deadzone(self, value, now):
        """The turn to act on, or 0 while it is still inside the dead zone.

        After a pause the first few counts are held back (a bump or a tremor is rarely more than
        a few); once they add up past the threshold they are released together and turning is
        unfiltered until the next pause. A deliberate turn costs only that initial lead-in.
        """
        zone = deadzone()
        if not zone:
            return value
        rested = now - self.dz_last > DEADZONE_REST_S
        self.dz_last = now
        if rested:
            self.dz_accum, self.dz_open = 0.0, False
        if self.dz_open:
            return value
        self.dz_accum += value
        if abs(self.dz_accum) < zone:
            return 0
        self.dz_open = True
        value, self.dz_accum = self.dz_accum, 0.0
        return value

    def on_rotate(self, value, now):
        self.raw_rot_at = now
        value = self.through_deadzone(value, now)
        if not value:
            return  # inside the dead zone: not activity, so a twitch cannot hold a tool armed
        self._acknowledge(now)
        self._track_speed(value, now)
        if self.menu:
            self._rotate_menu(value, now)
        elif TOOLS[self.tool].get("continuous"):
            self._rotate_continuous(value, now)
        else:
            self._rotate_discrete(value, now)

    def _acknowledge(self, now):
        """Show the active tool when turning starts after a quiet spell.

        A gentle first turn may not complete a step, and a dial that answers nothing reads as
        broken. The overlay appears on the first counted movement, then stays out of the way.
        """
        quiet = now - self.last_ack >= ACK_QUIET_S
        self.last_ack = now
        if quiet and not self.menu and osd_enabled():
            ACTIONS.submit(self.show_ack)

    def show_ack(self):
        t = TOOLS[self.tool]
        if t["name"] == "Volume":
            _show_level("volume")
        elif t["name"] == "Brightness":
            _show_level("brightness")
        elif not turn_note(t["name"]):
            osd(message=f"{t['icon']}  {t['name']}")

    def _track_speed(self, value, now):
        """Count the event and update `speed` (counts per second over SPEED_WINDOW)."""
        self.rot_events += 1
        if now - self.last_rot_log > 2.0:
            self.last_rot_log = now
            log(
                f"rotation alive: {self.rot_events} events, accum={self.accum:.0f}, "
                f"tool={TOOLS[self.tool]['name']}, detent={self.detent()}"
            )
        self.rot_hist.append((now, abs(value)))
        cutoff = now - SPEED_WINDOW
        while self.rot_hist and self.rot_hist[0][0] < cutoff:
            self.rot_hist.popleft()
        self.speed = sum(c for _, c in self.rot_hist) / SPEED_WINDOW

    def _rotate_menu(self, value, now):
        self.menu_accum += value
        self.menu_last = now
        step = menu_step()
        while abs(self.menu_accum) >= step:
            d = 1 if self.menu_accum > 0 else -1
            self.menu_accum -= d * step
            self.menu_pick = (self.menu_pick + d) % len(TOOLS)
            self.menu_moved = self.menu_moved or self.menu_pick != self.tool
            HAPTIC.fire(PAT_TICK)
            self.show_menu()
        # Continuous position in tool units. The divisor 2*step keeps the
        # fraction within +-0.5 of menu_pick so the QML highlight and the real pick
        # flip together. See docs/DESIGN.md#menu-highlight-alignment.
        MENU_STREAM.pos(self.menu_pick + self.menu_accum / (2 * step), now)

    def _rotate_pointer(self, value, now):
        """Move the mouse pointer along the current axis, faster the faster the dial turns."""
        t = TOOLS[self.tool]
        accel = 1 + min(self.speed / POINTER_ACCEL_COUNTS, POINTER_ACCEL_MAX)
        step = value * t.get("gain", POINTER_GAIN) * sensitivity() * accel
        if self.arrow_horizontal:  # flipped by a click: the vertical axis
            POINTER.move(0, step)
        else:
            POINTER.move(step, 0)
        self._tick_feedback(value)
        self.last_action = now

    def _tick_feedback(self, value):
        """A haptic tick every SCROLL_TICK counts of continuous turning."""
        self.scroll_accum += value
        while abs(self.scroll_accum) >= SCROLL_TICK:
            d = 1 if self.scroll_accum > 0 else -1
            self.scroll_accum -= d * SCROLL_TICK
            HAPTIC.fire(PAT_TICK)
            GUIDE.event("step")

    def _rotate_continuous(self, value, now):
        t = TOOLS[self.tool]
        if t.get("pointer"):
            self._rotate_pointer(value, now)
            return
        gain = t.get("gain", SCROLL_GAIN) * sensitivity()
        sign = 1 if t.get("invert") else -1
        if t.get("terminal_aware") and scroll_mode() == "suppress":
            return
        if t.get("horizontal") or (t.get("axis_toggle") and self.arrow_horizontal):
            POINTER.scroll(-sign * value * gain, horizontal=True)  # cw = scroll right
        else:
            POINTER.scroll(sign * value * gain)  # default: cw = scroll down
        self._tick_feedback(value)
        self.last_action = now

    def _rotate_discrete(self, value, now):
        self.accum += value
        step = self.detent()
        while abs(self.accum) >= step:
            d = 1 if self.accum > 0 else -1
            self.accum -= d * step
            self._fire_detent(d)
            HAPTIC.fire(PAT_TICK)
            self.last_action = now

    def _fire_detent(self, d):
        """Run the armed tool's action for one detent in direction d (+1 clockwise)."""
        mag = self.magnitude()
        t = TOOLS[self.tool]
        debug(f"detent {t['name']} {'cw' if d > 0 else 'ccw'} mag={mag} speed={self.speed:.0f}")
        side = "cw" if d > 0 else "ccw"
        GUIDE.event("step")
        if t.get("axis_toggle") and self.arrow_horizontal:
            alt = t.get("alt")
            if not alt:
                ACTIONS.submit(key, "Right" if d > 0 else "Left")
            elif alt[side]:
                ACTIONS.submit(alt[side], mag)
        else:
            ACTIONS.submit(t[side], mag)

    def on_press(self, now):
        debug("button down")
        if self.rot_at_attach is not None:
            # Clicks working while turns don't (a dial that wakes half-connected) shows up here.
            log(f"first press after attach: {self.rot_events - self.rot_at_attach} rotation events")
            self.rot_at_attach = None
        if self.pending_double is not None:
            # Third press inside the window: the triple-click action, and NOT the
            # double-click one.
            self.pending_double = None
            self.down_at = None
            self._fire_gesture("triple", now)
            return
        if self.pending_click is not None:
            self.pending_click = None
            self.down_at = None
            if click_choice("triple", TOOLS[self.tool]) != "none":
                # Hold the double-click action back until we know this isn't a
                # triple; the window opens when this second press is released.
                self.double_down = True
            else:
                self._fire_gesture("double", now)
            return
        self.down_at = now

    def _fire_gesture(self, kind, now):
        """Run the configured action for a "double" or "triple" click."""
        name = click_choice(kind, TOOLS[self.tool])
        if name == "tool":
            self._native_click(now)
            return
        fn = click_fn(name)
        if not fn:
            return
        ACTIONS.submit(fn, 1)
        if name == "dictation":
            HAPTIC.fire(
                PAT_DICTATION, rate_limit=False
            )  # dictation_toggle notifies once voxtype answers
        else:
            HAPTIC.fire(PAT_SELECT, rate_limit=False)
            notify(_CLICK_BY_NAME[name][1], f"{kind} click")
        self.last_action = now

    def on_release(self, now):
        if self.double_down:
            self.double_down = False
            self.pending_double = now + double_window()
            return
        if self.down_at is None:
            return
        held = now - self.down_at
        self.down_at = None
        if self.menu:
            if menu_latch() and not self.menu_latched and not self.menu_moved:
                # Let go without having turned: keep the menu open for a tap-to-choose.
                self.menu_latched = True
                self.menu_last = now
                HAPTIC.fire(PAT_TICK, rate_limit=False)
                return
            self.menu = False
            self.menu_latched = False
            MENU_STREAM.close()
            MENU_UI.close()
            GUIDE.event("pick" if self.menu_pick != self.tool else "menu_same")
            self._arm(self.menu_pick, now)
            self.accum = 0.0
            self.last_action = now
            HAPTIC.fire(PAT_SELECT, rate_limit=False)
            self.show_tool("armed" if self.tool != IDLE_TOOL else "idle")
            return
        if held >= hold_time():
            return
        self.pending_click = now + double_window()

    def _stalled(self, now, held):
        """Menu held with no turn at all: the dial's firmware stall (turns stop, presses don't).

        Close the menu, keep the armed tool, and drop the link; the dial reconnects on the next
        touch with turning back. Nothing on this side can see a stall otherwise: a stalled dial
        and an untouched one are equally silent, so the hold is the user saying "it isn't turning".
        """
        self.menu = self.menu_latched = False
        MENU_STREAM.close()
        MENU_UI.close()
        self.last_action = now
        HAPTIC.fire(PAT_SELECT, rate_limit=False)  # felt while still holding: let go
        if now - self.stall_kick_at < STALL_KICK_GAP_S:
            return
        self.stall_kick_at = now
        turn = (
            "none since start" if self.raw_rot_at is None else f"{now - self.raw_rot_at:.0f}s ago"
        )
        w = getattr(HAPTIC, "last_write", None)
        haptic = "never" if w is None else f"{time.monotonic() - w:.0f}s ago"
        log(
            f"stall: menu held {held:.1f}s with no turns; "
            f"last turn {turn}, last haptic write {haptic}"
        )
        notify("Reconnecting the dial", "No turns arrived while you held it. Press once it's back.")
        kick_dial_async("stall self-heal")

    def maybe_reload_tools(self, now):
        """Apply an edited tool list without a restart, only while idle."""
        if self.menu or self.down_at is not None or self.double_down:
            return
        if self.pending_click is not None or self.pending_double is not None:
            return
        try:
            mtime = os.stat(CONFIG_PATH).st_mtime_ns
        except OSError:
            mtime = None
        if mtime == _tools_state["mtime"]:
            return
        _tools_state["mtime"] = mtime
        new = load_tools()
        if [t["name"] for t in new] == [t["name"] for t in TOOLS]:
            return
        self._arm(IDLE_TOOL, now)  # release any held modifier before the swap
        TOOLS[:] = new
        self.tool = IDLE_TOOL
        log(f"tool list reloaded: {', '.join(t['name'] for t in TOOLS)}")

    def tick(self, now):
        """Advance every timed gesture; returns seconds until the next one is due, or None."""
        self.maybe_reload_tools(now)
        waits = [
            self._tick_hold(now),
            self._tick_stall(now),
            self._tick_latched_menu(now),
            self._tick_single_click(now),
            self._tick_double_click(now),
            self._tick_auto_return(now),
        ]
        waits = [w for w in waits if w is not None]
        return min(waits) if waits else None

    def _tick_stall(self, now):
        """Held STALL_HOLD_S with the menu open and not one turn since the press: reconnect.

        Fires while still held (a buzz says let go), so the release afterwards does nothing.
        """
        if self.down_at is None or not self.menu:
            return None
        if self.raw_rot_at is not None and self.raw_rot_at >= self.down_at:
            return None  # it turned during this hold: the dial is fine
        remain = (self.down_at + STALL_HOLD_S) - now
        if remain > 0:
            return remain
        held = now - self.down_at
        self.down_at = None
        self._stalled(now, held)
        return None

    def _tick_hold(self, now):
        """Open the tool menu once the button has been held long enough."""
        if self.down_at is None or self.menu:
            return None
        remain = (self.down_at + hold_time()) - now
        if remain > 0:
            return remain
        self.menu = True
        self.menu_pick = self.tool
        self.menu_accum = 0.0
        self.menu_moved = False
        self.menu_latched = False
        self.menu_last = now
        HAPTIC.fire(PAT_MENU, rate_limit=False)
        MENU_UI.open(self.menu_pick)
        MENU_STREAM.connect()
        GUIDE.event("menu")
        return None

    def _tick_latched_menu(self, now):
        """Close a tap-menu that nobody touched, keeping whatever tool was armed."""
        if not (self.menu and self.menu_latched and self.down_at is None):
            return None
        remain = (self.menu_last + menu_idle_timeout()) - now
        if remain > 0:
            return remain
        self.menu = False
        self.menu_latched = False
        MENU_STREAM.close()
        MENU_UI.close()
        self.last_action = now
        return None

    def _tick_single_click(self, now):
        """Run the single-click action once the double-click window has passed."""
        if self.pending_click is None:
            return None
        remain = self.pending_click - now
        if remain > 0:
            return remain
        self.pending_click = None
        GUIDE.event("click")
        single = click_choice("single", TOOLS[self.tool])
        if single != "tool":
            self._run_click(click_fn(single), now)
        else:
            self._native_click(now)
        return None

    def _native_click(self, now):
        """The armed tool's own click: flip its axis, or its click action."""
        if TOOLS[self.tool].get("axis_toggle"):
            self._toggle_axis(now)
        else:
            self._run_click(TOOLS[self.tool]["click"], now)

    def _run_click(self, fn, now):
        """Submit a compiled click action (one step) with a tick of feedback."""
        if fn:
            ACTIONS.submit(fn, 1)
            HAPTIC.fire(PAT_TICK, rate_limit=False)
            self.last_action = now

    def _toggle_axis(self, now):
        """Click on Arrow Keys (or any axis_toggle tool): flip vertical / horizontal."""
        self.arrow_horizontal = not self.arrow_horizontal
        HAPTIC.fire(PAT_TICK, rate_limit=False)
        alt = TOOLS[self.tool].get("alt")
        if alt:
            notify(
                alt["title"] if self.arrow_horizontal else alt["base_title"],
                alt["subtitle"] if self.arrow_horizontal else alt["base_subtitle"],
            )
        else:
            notify(
                "↔  Arrow Keys" if self.arrow_horizontal else "↕  Arrow Keys",
                "horizontal (Left/Right)" if self.arrow_horizontal else "vertical (Up/Down)",
            )
        self.last_action = now

    def _tick_double_click(self, now):
        if self.pending_double is None:
            return None
        remain = self.pending_double - now
        if remain > 0:
            return remain
        self.pending_double = None
        self._fire_gesture("double", now)
        return None

    def _tick_auto_return(self, now):
        """Nothing stays armed: fall back to the safe tool when left alone."""
        if self.tool == IDLE_TOOL or self.menu or self.down_at is not None:
            return None
        remain = (self.last_action + disarm_after(TOOLS[self.tool])) - now
        if remain > 0:
            return remain
        self.disarm(now)
        return None


def pump(fh, dial):
    fd = fh.fileno()
    os.set_blocking(fd, False)
    kernel_clock = use_monotonic_event_clock(fd)
    try:
        while True:
            timeout = dial.tick(time.monotonic())
            r, _, _ = select.select([fd], [], [], timeout if timeout else 0.25)
            if not r:
                continue
            while True:
                try:
                    data = os.read(fd, EV_SIZE)
                except BlockingIOError:
                    break
                if not data or len(data) < EV_SIZE:
                    return
                sec, usec, etype, code, value = struct.unpack(EV_FORMAT, data)
                now = time.monotonic()
                _status["last_use"] = now  # the keep-awake idle window counts from here
                if kernel_clock:
                    now = event_time(sec, usec, now)
                if etype == EV_REL and code == REL_DIAL:
                    dial.on_rotate(value, now)
                elif etype == EV_KEY and code == BTN_0:
                    if value == 1:
                        dial.on_press(now)
                    elif value == 0:
                        dial.on_release(now)
    finally:
        fh.close()


def main():
    if not single_instance():
        log("another redial-hypr is already running; this one exits")
        return
    make_private()
    # Surface Pen support is a separate feature that happens to live in the
    # same daemon. It stays on by default so existing setups are unchanged, and
    # it costs nothing where no pen exists (the watchers simply find no device),
    # but it can be turned off for a dial-only install.
    if bool(_pen_section(load_config()).get("enabled", True)):
        # Create the virtual pointer now: made on first use, its first events landed
        # before the compositor had added the device, so the first scroll started late.
        POINTER._ensure()
        threading.Thread(target=eraser_watcher, daemon=True).start()
        threading.Thread(target=pen_button_watcher, daemon=True).start()
    else:
        log("pen support disabled by config")
    if uinput_keys():
        KEYBOARD._ensure()  # made now so the compositor has added it before the first key
    threading.Thread(target=status_loop, daemon=True).start()
    global GUIDE
    GUIDE = Guide(
        guide_path(), guide_say, enabled=guide_enabled, mode=guide_mode, describe=tool_lines
    )
    atexit.register(GUIDE.flush)
    dial = Dial()
    waiting = False
    retries = 0
    lost_at = time.monotonic()
    watch = DeviceWatch()
    while True:
        fh, path = open_input(DEVICE_NAME, quiet=retries < OPEN_RETRY_MAX)
        if fh is None:
            if not waiting:
                log("waiting for device")
                waiting = True
                retries = 0
            if path and retries < OPEN_RETRY_MAX:
                retries += 1
                time.sleep(OPEN_RETRY_S)
            else:
                watch.wait(WATCH_SAFETY_S)
            continue
        waiting = False
        retries = 0
        log(f"attached to {path} (away {time.monotonic() - lost_at:.1f}s)")
        dial.rot_at_attach = dial.rot_events
        _status["attached"] = True
        _status["last_use"] = time.monotonic()  # a press woke it, so someone is here
        dial.reset_gestures()
        dial._arm(IDLE_TOOL, time.monotonic())
        dial.last_action = time.monotonic()
        dial.show_connected()
        GUIDE.attached()
        attached_at = time.monotonic()
        try:
            pump(fh, dial)
        except OSError as exc:
            log(f"detached ({exc})")
        _status["attached"] = False
        # Dropped while in use: say so, or the next turn just does nothing. A dial that sleeps
        # on its own while idle says nothing; nobody is looking.
        dropped_by_us = (
            time.monotonic() - dial.stall_kick_at < DROP_IN_USE_S
        )  # stall reconnect said so
        if attached_at < dial.last_action > time.monotonic() - DROP_IN_USE_S and not dropped_by_us:
            cant_note("asleep", "Dial went to sleep", "Press it to wake it")
        dial.detach()
        lost_at = time.monotonic()
        time.sleep(REATTACH_PAUSE_S)
