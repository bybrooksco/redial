#!/usr/bin/env python3
"""Regression tests for the Surface Dial daemon's logic -- no dial, no display needed.

    python3 test_dial.py                      # tests ../bin/surface-dial-hypr (the kit's copy)
    DIAL_DAEMON=~/.local/bin/surface-dial-hypr python3 test_dial.py   # the live install

Every side effect (keys, hyprctl, playerctl, brightnessctl, notifications, haptics) is
replaced with a recorder, and the click gestures are driven through a real temporary
config file, so this checks decisions, not hardware. What it deliberately cannot check
is feel on the physical dial, and real media/window behaviour -- see the Process Book.
"""

import sys

sys.dont_write_bytecode = True  # importing the daemon must not leave .pyc files in the kit
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.environ.get("DIAL_DAEMON") or os.path.join(HERE, "..", "bin", "surface-dial-hypr")


def load_daemon():
    loader = importlib.machinery.SourceFileLoader(
        "dialmod", os.path.abspath(os.path.expanduser(DAEMON))
    )
    spec = importlib.util.spec_from_loader("dialmod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


m = load_daemon()
EVENTS = []
POSITIONS = []


class Haptics:
    def fire(self, *a, **k):
        pass


class Recorder:
    """Stands in for MENU_UI / MENU_STREAM."""

    def close(self):
        EVENTS.append("menu-closed")

    def open(self, i):
        EVENTS.append("MENU-OPENED")

    def connect(self):
        pass

    def highlight(self, i):
        pass

    def pos(self, p, now):
        POSITIONS.append(p)


def install_stubs(cfg_path):
    m.HAPTIC = Haptics()
    m.MENU_UI = m.MENU_STREAM = Recorder()
    m.key = lambda *k: EVENTS.append("KEY:" + "+".join(k))
    m.dictation_toggle = lambda: EVENTS.append("DICTATION")
    m.notify = lambda *a, **k: None
    m.run = lambda cmd: EVENTS.append("EXEC:" + " ".join(cmd[:2]))
    m.hypr = lambda lua: EVENTS.append("HYPR:" + lua)
    m.CONFIG_PATH = cfg_path
    m.TOOLS = m.build_tools(m.TOOL_LIBRARY)
    m._click_cache.update(mtime=object())


def tool_index(name):
    return [t["name"] for t in m.TOOLS].index(name)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfg = os.path.join(self.tmp, "config.json")
        install_stubs(self.cfg)
        EVENTS.clear()

    def set_clicks(self, clicks):
        time.sleep(0.005)  # distinct mtime
        with open(self.cfg, "w") as f:
            json.dump({} if clicks is None else {"clicks": clicks}, f)

    def gesture(self, presses, tool=0):
        """`presses` quick presses, then let the clock run out; returns what fired."""
        EVENTS.clear()
        d = m.Dial()
        d.tool = tool
        t = 0.0
        for _ in range(presses):
            d.on_press(t)
            t += 0.05
            d.on_release(t)
            t += 0.10
        end = t + 1.0
        while t <= end:
            d.tick(t)
            t += 0.01
        return list(EVENTS)


class ToolLibrary(unittest.TestCase):
    def test_every_tool_compiles(self):
        tools = m.build_tools(m.TOOL_LIBRARY)
        self.assertEqual(len(tools), len(m.TOOL_LIBRARY))
        for t in tools:
            if not t["continuous"]:
                self.assertTrue(callable(t["cw"]) and callable(t["ccw"]), t["name"])

    def test_expected_tools_present(self):
        names = [t["name"] for t in m.TOOL_LIBRARY]
        for n in (
            "Volume",
            "Windows",
            "Workspaces",
            "Scroll",
            "Undo",
            "Zoom",
            "Media",
            "Word Nav",
            "Arrow Keys",
            "Window Size",
            "Brightness",
        ):
            self.assertIn(n, names)

    def test_media_scrubs_and_has_magnitude(self):
        media = next(t for t in m.build_tools(m.TOOL_LIBRARY) if t["name"] == "Media")
        self.assertTrue(media["mag"])
        self.assertEqual(media["detent"], 60)
        self.assertEqual(media["click_label"], "play/pause")

    def test_arrow_keys_keeps_its_own_axis_path(self):
        ak = next(t for t in m.build_tools(m.TOOL_LIBRARY) if t["name"] == "Arrow Keys")
        self.assertTrue(ak["axis_toggle"])
        self.assertIsNone(ak["alt"])

    def test_unknown_verb_is_a_noop_not_a_crash(self):
        self.assertIsNone(m.make_action({"do": "no-such-verb"}))


class ClickGestures(Base):
    def test_defaults(self):
        self.set_clicks(None)
        vol = tool_index("Volume")
        self.assertEqual(self.gesture(1, vol), ["EXEC:wpctl set-mute"])
        self.assertEqual(self.gesture(2, vol), ["DICTATION"])
        self.assertEqual(self.gesture(3, vol), ["KEY:Return"])

    def test_custom_mapping(self):
        self.set_clicks({"double": "play_pause", "triple": "escape"})
        self.assertEqual(self.gesture(2), ["EXEC:playerctl play-pause"])
        self.assertEqual(self.gesture(3), ["KEY:Escape"])

    def test_triple_none_makes_double_instant(self):
        self.set_clicks({"triple": "none"})
        EVENTS.clear()
        d = m.Dial()
        d.on_press(0)
        d.on_release(0.05)
        d.on_press(0.15)  # second press only, no tick
        self.assertEqual(EVENTS, ["DICTATION"])

    def test_double_waits_when_triple_is_set(self):
        self.set_clicks(None)
        EVENTS.clear()
        d = m.Dial()
        d.on_press(0)
        d.on_release(0.05)
        d.on_press(0.15)
        self.assertEqual(EVENTS, [], "double click must wait for a possible third press")

    def test_late_third_press_is_dictation_then_a_single(self):
        self.set_clicks(None)
        EVENTS.clear()
        d = m.Dial()
        d.on_press(0)
        d.on_release(0.05)
        d.on_press(0.15)
        d.on_release(0.20)
        t = 0.20
        while t < 0.6:
            d.tick(t)
            t += 0.01
        d.on_press(0.7)
        d.on_release(0.75)
        while t < 1.3:
            d.tick(t)
            t += 0.01
        self.assertEqual(EVENTS, ["DICTATION", "EXEC:wpctl set-mute"])

    def test_single_override_and_none(self):
        self.set_clicks({"single": "enter"})
        self.assertEqual(self.gesture(1), ["KEY:Return"])
        self.set_clicks({"single": "none"})
        self.assertEqual(self.gesture(1), [])

    def test_single_override_disables_axis_toggle(self):
        self.set_clicks({"single": "enter"})
        self.assertEqual(self.gesture(1, tool_index("Arrow Keys")), ["KEY:Return"])

    def test_invalid_values_fall_back(self):
        self.set_clicks({"double": "bogus", "triple": "tool", "single": 5})
        self.assertEqual(self.gesture(2), ["DICTATION"])
        self.assertEqual(self.gesture(3), ["KEY:Return"])

    def test_live_edit_needs_no_restart(self):
        self.set_clicks(None)
        self.assertEqual(self.gesture(3), ["KEY:Return"])
        self.set_clicks({"triple": "space"})
        self.assertEqual(self.gesture(3), ["KEY:space"])

    def test_overlay_hint_follows_single_override(self):
        win = m.TOOLS[tool_index("Windows")]
        self.set_clicks(None)
        self.assertEqual(m.click_hint(win), win["click_label"])
        self.set_clicks({"single": "mute"})
        self.assertEqual(m.click_hint(win), "Mute")

    def test_every_offered_action_compiles(self):
        for name, label, desc, spec in m.CLICK_ACTIONS:
            self.assertTrue(label and desc, name)
            if spec:
                self.assertTrue(callable(m.make_action(spec)), name)


class GestureReset(Base):
    def half_finished(self):
        d = m.Dial()
        d.on_press(0)
        d.on_release(0.05)
        d.on_press(0.15)  # dial sleeps, 2nd press down
        return d

    def test_stale_state_is_cleared(self):
        d = self.half_finished()
        d.reset_gestures()
        EVENTS.clear()
        d.on_press(5)
        d.on_release(5.05)
        t = 5.05
        while t < 7:
            d.tick(t)
            t += 0.01
        self.assertEqual(
            EVENTS, ["EXEC:wpctl set-mute"], "next gesture after a reconnect must be clean"
        )

    def test_open_menu_is_closed_on_detach(self):
        d = m.Dial()
        d.menu = True
        EVENTS.clear()
        d.reset_gestures()
        self.assertFalse(d.menu)
        self.assertIn("menu-closed", EVENTS)


class Seek(unittest.TestCase):
    def setUp(self):
        self.calls, self.players, self.rc = [], "", 0

        def fake(cmd, **kw):
            self.calls.append(cmd)
            if cmd[:3] == ["playerctl", "-a", "metadata"]:
                return types.SimpleNamespace(stdout=self.players, stderr="", returncode=0)
            return types.SimpleNamespace(
                stdout="", stderr="No player" if self.rc else "", returncode=self.rc
            )

        m.subprocess = types.SimpleNamespace(run=fake, Popen=subprocess.Popen)
        m._seek_cache.update(at=0.0, args=[])
        self.addCleanup(lambda: setattr(m, "subprocess", subprocess))
        self.logs = []
        m.log = self.logs.append

    def seeks(self):
        return [" ".join(c[1:]) for c in self.calls if "position" in c]

    def test_step_doubles_per_speed_step(self):
        self.players = "jelly\tPlaying\n"
        for mag, secs in ((1, 5), (2, 10), (3, 20), (4, 40)):
            self.calls.clear()
            m._seek_cache.update(at=0.0, args=[])
            m.seek_media(True, mag)
            self.assertEqual(self.seeks(), [f"-p jelly position {secs}+"])
        self.calls.clear()
        m.seek_media(False, 1)
        self.assertTrue(self.seeks()[0].endswith("position 5-"))

    def test_prefers_playing_over_paused(self):
        self.players = "firefox\tPaused\nmpv\tPlaying\n"
        m.seek_media(True, 1)
        self.assertIn("-p mpv", self.seeks()[0])

    def test_falls_back_to_plain_playerctl(self):
        self.players = ""
        m.seek_media(True, 1)
        self.assertEqual(self.seeks(), ["position 5+"])

    def test_player_lookup_is_cached(self):
        self.players = "mpv\tPlaying\n"
        for _ in range(6):
            m.seek_media(True, 1)
        self.assertEqual(sum(1 for c in self.calls if c[:3] == ["playerctl", "-a", "metadata"]), 1)

    def test_failures_are_rate_limited(self):
        self.rc = 1
        m._seek_warned = 0.0
        for _ in range(10):
            m.seek_media(True, 1)
        self.assertEqual(len(self.logs), 1)


class Brightness(unittest.TestCase):
    def setUp(self):
        self.sent, self.pct = [], 60
        m.read_brightness = lambda d=None: self.pct
        m.backlight_device = lambda: "intel_backlight"
        m.run = lambda cmd: self.sent.append(cmd)

    def test_step_and_magnitude(self):
        for mag in (1, 2, 3, 4):
            self.sent.clear()
            m.set_brightness(mag, False)
            self.assertEqual(self.sent[0][-1], f"{60 - 2 * mag}%")

    def test_device_is_always_named(self):
        m.set_brightness(1, True)
        self.assertEqual(self.sent[0][:4], ["brightnessctl", "-q", "-d", "intel_backlight"])

    def test_floor_and_ceiling(self):
        self.pct = 3
        m.set_brightness(4, False)
        self.assertEqual(self.sent[-1][-1], "1%")
        self.sent.clear()
        self.pct = 1
        m.set_brightness(1, False)
        self.assertEqual(self.sent, [])
        self.pct = 99
        m.set_brightness(4, True)
        self.assertEqual(self.sent[-1][-1], "100%")
        self.sent.clear()
        self.pct = 100
        m.set_brightness(1, True)
        self.assertEqual(self.sent, [])

    def test_no_backlight_does_nothing(self):
        m.read_brightness = lambda d=None: None
        m._bright_warned = False
        m.set_brightness(1, True)
        self.assertEqual(self.sent, [])


class Resize(unittest.TestCase):
    """resize_active() must make clockwise GROW wherever the window sits."""

    MON = {"id": 0, "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.25}

    def run_resize(self, win, axis="x", grow=True):
        sent = []
        m.hypr = sent.append

        def fake(cmd, **kw):
            data = win if "activewindow" in cmd else [self.MON]
            return types.SimpleNamespace(stdout=json.dumps(data), stderr="", returncode=0)

        m.subprocess = types.SimpleNamespace(run=fake, Popen=subprocess.Popen)
        self.addCleanup(lambda: setattr(m, "subprocess", subprocess))
        m.resize_active(axis, grow)
        return sent

    def win(self, x, w, y=36, h=800, **kw):
        return dict(
            {"floating": False, "fullscreen": False, "monitor": 0, "at": [x, y], "size": [w, h]},
            **kw,
        )

    def test_pinned_right_grows_with_negative_delta(self):
        # right edge at 1531 of a 1536-wide logical monitor -> pinned to the right edge
        self.assertIn("x = -40", self.run_resize(self.win(771, 760))[0])

    def test_not_pinned_grows_with_positive_delta(self):
        self.assertIn("x = 40", self.run_resize(self.win(5, 760))[0])

    def test_shrink_is_the_opposite(self):
        self.assertIn("x = 40", self.run_resize(self.win(771, 760), grow=False)[0])

    def test_pinned_bottom_uses_the_y_axis(self):
        self.assertIn("y = -40", self.run_resize(self.win(5, 700, y=36, h=810), axis="y")[0])

    def test_floating_always_positive(self):
        self.assertIn("x = 40", self.run_resize(self.win(771, 760, floating=True))[0])

    def test_fullscreen_is_left_alone(self):
        self.assertEqual(self.run_resize(self.win(0, 1536, fullscreen=True)), [])


class MenuPositionAlignment(unittest.TestCase):
    """The overlay's highlighted tool -- round(position), on the QML side --
    must flip to the next tool at the exact same rotation count as
    menu_pick itself (the real value a release/click arms). Regression for
    a 2026-09-30 bug: the position sent over the socket divided menu_accum
    by MENU_STEP, which ranges up to +-1.0 within one detent, so round()
    flipped the visual highlight a half-detent early -- a click right after
    the highlight changed could still arm the OLD tool. Fixed by dividing
    by 2*MENU_STEP instead, keeping the fraction within +-0.5."""

    def test_visual_highlight_never_leads_the_real_pick(self):
        install_stubs(os.path.join(tempfile.mkdtemp(), "config.json"))
        POSITIONS.clear()
        d = m.Dial()
        d.menu = True
        d.menu_pick = 0
        d.menu_accum = 0.0
        t = 0.0
        # A few full laps, one count per rotate event -- MENU_STEP counts is
        # one detent, so this crosses many tool boundaries in both directions.
        for value in [1] * (m.MENU_STEP * len(m.TOOLS) * 2) + [-1] * (
            m.MENU_STEP * len(m.TOOLS) * 2
        ):
            d.on_rotate(value, t)
            t += 0.002
            if POSITIONS:
                visual = round(POSITIONS[-1]) % len(m.TOOLS)
                self.assertEqual(
                    visual,
                    d.menu_pick,
                    f"visual highlight={visual} but the real pick is still "
                    f"{d.menu_pick} (position={POSITIONS[-1]!r})",
                )


class LiveToolReload(Base):
    def setUp(self):
        super().setUp()
        self.saved = list(m.TOOLS)
        m._tools_state["mtime"] = None
        self.addCleanup(lambda: (m.TOOLS.__setitem__(slice(None), self.saved)))

    def write_active(self, names):
        time.sleep(0.005)  # distinct mtime
        with open(self.cfg, "w") as f:
            json.dump({"active_tools": names}, f)

    def test_idle_dial_picks_up_new_tool_list(self):
        self.write_active(["Volume", "Zoom"])
        d = m.Dial()
        d.tool = 1
        d.tick(0.0)
        self.assertEqual([t["name"] for t in m.TOOLS], ["Volume", "Zoom"])
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_no_swap_while_a_gesture_is_in_flight(self):
        self.write_active(["Volume", "Zoom"])
        before = [t["name"] for t in m.TOOLS]
        d = m.Dial()
        d.on_press(0.0)  # finger down, menu not open yet
        d.maybe_reload_tools(0.01)
        self.assertEqual([t["name"] for t in m.TOOLS], before)
        d.on_release(0.05)

    def test_unchanged_tool_list_does_not_disturb_the_armed_tool(self):
        self.write_active([t["name"] for t in m.TOOLS])
        d = m.Dial()
        d.tool = 2
        d.tick(0.0)
        self.assertEqual(d.tool, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
