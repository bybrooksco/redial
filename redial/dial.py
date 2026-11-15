"""The dial: rotation, presses, the tool menu, and which tool is armed."""

import math
import os
import time
from collections import deque

from . import guide
from .actions import kick_dial_async, scroll_mode
from .config import (
    ACK_QUIET_S,
    DEADZONE_REST_S,
    MAG_FALLOFF,
    MAG_MAX,
    PAT_DICTATION,
    PAT_IDLE,
    PAT_MENU,
    PAT_SELECT,
    PAT_TICK,
    POINTER_ACCEL_COUNTS,
    POINTER_ACCEL_MAX,
    POINTER_GAIN,
    SCROLL_GAIN,
    SCROLL_TICK,
    SPEED_WINDOW,
    STALL_HOLD_S,
    STALL_KICK_GAP_S,
    deadzone,
    disarm_after,
    double_window,
    hold_time,
    menu_idle_timeout,
    menu_latch,
    menu_step,
    osd_enabled,
    return_buzz,
    sensitivity,
)
from .controls import show_level_now
from .feedback import MENU_STREAM, MENU_UI, notify, omarchy_shell, osd, speak, turn_note
from .gestures import CLICK_BY_NAME, click_choice, click_fn
from .haptics import HAPTIC
from .keys import key, press_mod, release_mod
from .log import debug, log
from .paths import CONFIG_PATH
from .system import ACTIONS
from .tools import IDLE_TOOL, TOOLS, TOOLS_STATE, load_tools
from .uinput import POINTER


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
            guide.GUIDE.armed(TOOLS[idx]["name"], idx == IDLE_TOOL)
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
            show_level_now("volume")
        elif t["name"] == "Brightness":
            show_level_now("brightness")
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
            guide.GUIDE.event("step")

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
        guide.GUIDE.event("step")
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
            notify(CLICK_BY_NAME[name][1], f"{kind} click")
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
            guide.GUIDE.event("pick" if self.menu_pick != self.tool else "menu_same")
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
        if mtime == TOOLS_STATE["mtime"]:
            return
        TOOLS_STATE["mtime"] = mtime
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
        guide.GUIDE.event("menu")
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
        guide.GUIDE.event("click")
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
