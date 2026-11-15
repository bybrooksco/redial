"""The Surface Pen: the tail button, the barrel button, and the eraser (tap, hold, drag-scroll)."""

import struct
import threading
import time

from .actions import mouse_button, scroll_mode
from .devices import (
    ABS_X,
    ABS_Y,
    BTN_STYLUS,
    BTN_TOOL_RUBBER,
    BTN_TOUCH,
    EV_ABS,
    EV_FORMAT,
    EV_KEY,
    EV_SIZE,
    PEN_KBD_NAME,
    STYLUS_NAME,
    open_input,
)
from .gestures import (
    _PEN_BARREL_BY_NAME,
    pen_barrel_config,
    pen_barrel_fn,
    pen_barrel_hold,
    pen_eraser_config,
    pen_eraser_fn,
    pen_tail_fn,
)
from .keys import key
from .log import log
from .system import ACTIONS
from .uinput import POINTER
from .wm import focused_class

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
