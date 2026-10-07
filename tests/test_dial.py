#!/usr/bin/env python3
"""Regression tests for the Surface Dial daemon's logic -- no dial, no display needed.

    python3 test_dial.py                      # tests ../bin/surface-dial-hypr (the kit's copy)
    DIAL_DAEMON=~/.local/bin/surface-dial-hypr python3 test_dial.py   # the live install

Every side effect (keys, hyprctl, playerctl, brightnessctl, notifications, haptics) is
replaced with a recorder, and the click gestures are driven through a real temporary
config file, so this checks decisions, not hardware. What it deliberately cannot check
is feel on the physical dial, and real media/window behaviour.
"""

import sys

sys.dont_write_bytecode = True  # importing the daemon must not leave .pyc files in the kit
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import time
import types
import unittest

# Importing the daemon writes manifests into its config dir; keep that off the real one.
os.environ["DIAL_CONFIG_DIR"] = tempfile.mkdtemp()

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
    m.ACTIONS.inline = True  # assert straight after a gesture, not after a worker thread
    m.TOOLS = m.build_tools(m.TOOL_LIBRARY)
    m._click_cache.update(mtime=object())
    m._disarm_cache.update(mtime=object())


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
        real = m.hypr_json
        m.hypr_json = lambda what: win if what == "activewindow" else [self.MON]
        self.addCleanup(lambda: setattr(m, "hypr_json", real))
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
        self.addCleanup(lambda: m.TOOLS.__setitem__(slice(None), self.saved))

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


class LayoutPayload(Base):
    def payload_layout(self, layout):
        with open(self.cfg, "w") as f:
            json.dump({"layout": layout}, f)
        ui = m.MenuUI()
        ui._volume = lambda: None
        saved = m.read_brightness
        m.read_brightness = lambda: None
        try:
            return json.loads(ui._payload(0))["layout"]
        finally:
            m.read_brightness = saved

    def test_every_shipped_layout_is_accepted(self):
        for layout in ("dial", "deck", "carousel", "toast", "omarchy"):
            self.assertEqual(self.payload_layout(layout), layout)

    def test_unknown_layout_falls_back(self):
        self.assertEqual(self.payload_layout("nonsense"), m.MENU_LAYOUT)


class HyprIpc(unittest.TestCase):
    """hypr_json() asks Hyprland's own socket, and falls back to hyprctl without one."""

    def setUp(self):
        self.rt = tempfile.mkdtemp()
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in self._set])
        self._set = ("XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE")

        # hyprctl would talk to the same fake socket, so a fallback would look identical.
        # Make any process spawn a failure so these tests can only pass via the socket.
        def no_spawn(cmd, **kw):
            raise AssertionError(f"spawned {cmd}; expected the socket path")

        real = m.subprocess
        m.subprocess = types.SimpleNamespace(run=no_spawn, Popen=real.Popen)
        self.addCleanup(lambda: setattr(m, "subprocess", real))

    def serve(self, reply):
        import socket as _s
        import threading

        d = os.path.join(self.rt, "hypr", "sig")
        os.makedirs(d)
        path = os.path.join(d, ".socket.sock")
        srv = _s.socket(_s.AF_UNIX, _s.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)
        seen = []

        def once():
            c, _ = srv.accept()
            seen.append(c.recv(256))
            c.sendall(reply)
            c.close()
            srv.close()

        threading.Thread(target=once, daemon=True).start()
        os.environ["XDG_RUNTIME_DIR"] = self.rt
        os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "sig"
        return seen

    def test_reads_through_the_socket(self):
        seen = self.serve(b'{"class": "foot"}')
        self.assertEqual(m.hypr_json("activewindow"), {"class": "foot"})
        self.assertEqual(seen, [b"j/activewindow"])

    def test_focused_class_uses_it(self):
        self.serve(b'{"class": "obsidian"}')
        self.assertEqual(m.focused_class(), "obsidian")

    def test_no_window_is_an_empty_class(self):
        self.serve(b"{}")
        self.assertEqual(m.focused_class(), "")

    def test_falls_back_to_hyprctl_without_a_socket(self):
        os.environ["XDG_RUNTIME_DIR"] = self.rt  # no socket file there
        os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "missing"
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd)
            return types.SimpleNamespace(stdout='{"class": "via-hyprctl"}', stderr="", returncode=0)

        m.subprocess = types.SimpleNamespace(run=fake)
        self.assertEqual(m.focused_class(), "via-hyprctl")
        self.assertEqual(calls, [["hyprctl", "activewindow", "-j"]])


class ActionWorker(unittest.TestCase):
    def setUp(self):
        self.a = m.Actions()

    def drain(self):
        done = threading.Event()
        self.a.submit(done.set)
        self.assertTrue(done.wait(2), "worker never reached the sentinel")

    def test_submit_does_not_block_on_a_slow_action(self):
        t0 = time.perf_counter()
        self.a.submit(time.sleep, 0.2)
        self.assertLess(time.perf_counter() - t0, 0.05)
        self.drain()

    def test_actions_run_in_order(self):
        out = []
        for i in range(20):
            self.a.submit(out.append, i)
        self.drain()
        self.assertEqual(out, list(range(20)))

    def test_a_raising_action_does_not_stop_the_worker(self):
        out = []
        self.a.submit(lambda: 1 / 0)
        self.a.submit(out.append, "after")
        self.drain()
        self.assertEqual(out, ["after"])

    def test_a_full_queue_drops_instead_of_blocking(self):
        gate = threading.Event()
        self.a.submit(gate.wait)  # occupies the worker
        time.sleep(0.05)
        t0 = time.perf_counter()
        for _ in range(200):
            self.a.submit(lambda: None)
        self.assertLess(time.perf_counter() - t0, 0.5)
        self.assertEqual(self.a.q.qsize(), 64)  # full: the rest were dropped, not queued
        gate.set()
        deadline = time.time() + 2
        while not self.a.q.empty() and time.time() < deadline:
            time.sleep(0.01)
        self.drain()

    def test_inline_mode_runs_on_the_callers_thread(self):
        self.a.inline = True
        out = []
        self.a.submit(out.append, 1)
        self.assertEqual(out, [1])


class EventClock(unittest.TestCase):
    def test_a_sane_kernel_timestamp_is_used(self):
        self.assertAlmostEqual(m.event_time(100, 500_000, 100.6), 100.5)

    def test_a_timestamp_in_another_clock_falls_back_to_now(self):
        self.assertEqual(m.event_time(1_790_000_000, 0, 100.0), 100.0)  # wall-clock seconds

    def test_a_timestamp_from_the_future_falls_back_to_now(self):
        self.assertEqual(m.event_time(105, 0, 100.0), 100.0)

    def test_a_stale_timestamp_falls_back_to_now(self):
        self.assertEqual(m.event_time(10, 0, 100.0), 100.0)


class Notify(unittest.TestCase):
    """notify() prefers Omarchy's notifier, replaces in place, and falls back to notify-send."""

    def setUp(self):
        self.calls = []
        self.real_sub, self.real_shutil, self.real_run = m.subprocess, m.shutil, m.run
        self.addCleanup(self.restore)
        m._notify_id = None
        m.run = lambda cmd: self.calls.append(("run", cmd))

    def restore(self):
        m.subprocess, m.shutil, m.run, m._notify_id = (
            self.real_sub,
            self.real_shutil,
            self.real_run,
            None,
        )

    def stub(self, have_omarchy, reply="45\n"):
        def fake(cmd, **kw):
            self.calls.append(("sub", cmd))
            return types.SimpleNamespace(stdout=reply, stderr="", returncode=0)

        m.subprocess = types.SimpleNamespace(run=fake)
        m.shutil = types.SimpleNamespace(which=lambda n: "/x" if have_omarchy else None)

    def test_uses_omarchys_notifier(self):
        self.stub(True)
        m._notify_sync("Title", "Body")
        kind, cmd = self.calls[0]
        self.assertEqual((kind, cmd[0]), ("sub", "omarchy-notification-send"))
        self.assertEqual(cmd[-2:], ["Title", "Body"])
        self.assertNotIn("-r", cmd)

    def test_second_message_replaces_the_first(self):
        self.stub(True)
        m._notify_sync("One")
        m._notify_sync("Two")
        first, second = self.calls[0][1], self.calls[1][1]
        self.assertNotIn("-r", first)
        self.assertEqual(second[second.index("-r") + 1], "45")

    def test_falls_back_to_notify_send(self):
        self.stub(False)
        m._notify_sync("Title", "Body")
        kind, cmd = self.calls[0]
        self.assertEqual((kind, cmd[0]), ("run", "notify-send"))

    def test_a_non_numeric_reply_is_not_kept_as_an_id(self):
        self.stub(True, reply="oops\n")
        m._notify_sync("One")
        m._notify_sync("Two")
        self.assertNotIn("-r", self.calls[1][1])


class MenuEntry(unittest.TestCase):
    """scripts/add-menu-entry.py edits the user's JSONC menu file without breaking it."""

    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader(
            "addmenu", os.path.join(HERE, "..", "scripts", "add-menu-entry.py")
        )
        cls.am = importlib.util.module_from_spec(importlib.util.spec_from_loader("addmenu", loader))
        loader.exec_module(cls.am)

    def inserted(self, text):
        new = self.am.add_row(text)
        self.assertIsNotNone(new)
        return new, self.am.parse_jsonc(new)

    def test_comment_only_file_like_the_stock_extension(self):
        text = '{\n  // Extend the menu.\n  // "personal": {"icon":"x"},\n}\n'
        new, doc = self.inserted(text)
        self.assertEqual(list(doc), [self.am.ID])
        self.assertIn("// Extend the menu.", new)  # the user's comments survive

    def test_empty_object(self):
        _, doc = self.inserted("{}")
        self.assertIn(self.am.ID, doc)

    def test_existing_entries_without_a_trailing_comma(self):
        _, doc = self.inserted('{\n  "a": {"label":"A"}\n}\n')
        self.assertEqual(sorted(doc), sorted(["a", self.am.ID]))

    def test_existing_entries_with_a_trailing_comma(self):
        _, doc = self.inserted('{\n  "a": {"label":"A"},\n}\n')
        self.assertEqual(sorted(doc), sorted(["a", self.am.ID]))

    def test_comma_goes_after_the_value_not_after_a_trailing_comment(self):
        new, doc = self.inserted('{\n  "a": {"label":"A"} // keep me\n}\n')
        self.assertEqual(sorted(doc), sorted(["a", self.am.ID]))
        self.assertIn("// keep me", new)

    def test_slashes_and_braces_inside_strings_are_not_comments_or_structure(self):
        text = '{\n  "a": {"action":"open https://example.com/x } // not a comment"}\n}\n'
        _, doc = self.inserted(text)
        self.assertEqual(doc["a"]["action"], "open https://example.com/x } // not a comment")

    def test_block_comment_before_the_closing_brace(self):
        _, doc = self.inserted('{\n  "a": {"label":"A"}\n  /* later */\n}\n')
        self.assertEqual(sorted(doc), sorted(["a", self.am.ID]))

    def test_second_run_changes_nothing(self):
        new, _ = self.inserted("{}")
        self.assertIsNone(self.am.add_row(new))

    def test_main_leaves_an_unparseable_file_untouched(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "menu.jsonc")
        open(path, "w").write("[1, 2, 3]")
        self.assertEqual(self.am.main(["x", path]), 1)
        self.assertEqual(open(path).read(), "[1, 2, 3]")

    def test_main_writes_a_valid_file_and_is_idempotent(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "ext", "menu.jsonc")  # parent dir does not exist yet
        self.assertEqual(self.am.main(["x", path]), 0)
        first = open(path).read()
        self.assertIn(self.am.ID, self.am.parse_jsonc(first))
        self.assertEqual(self.am.main(["x", path]), 0)
        self.assertEqual(open(path).read(), first)


class PluginManifest(unittest.TestCase):
    """`omarchy plugin add <git-url>` needs a valid manifest.json at the repo root.

    Mirrors the checks in Omarchy's own `omarchy-plugin-validate`, which CI can't run.
    """

    ROOT = os.path.abspath(os.path.join(HERE, ".."))

    def manifest(self, *parts):
        with open(os.path.join(self.ROOT, *parts, "manifest.json")) as fh:
            return json.load(fh)

    def test_root_manifest_satisfies_the_validator_rules(self):
        mf = self.manifest()
        self.assertEqual(mf["schemaVersion"], 1)
        for field in ("id", "name", "version", "kinds", "entryPoints"):
            self.assertIn(field, mf)
        self.assertRegex(mf["id"], r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
        self.assertFalse(mf["id"].startswith("omarchy."))
        self.assertTrue(mf["kinds"])
        self.assertIn("panel", mf["entryPoints"])  # a "panel" kind needs a panel entry point
        for ep in mf["entryPoints"].values():
            self.assertFalse(ep.startswith("/") or ".." in ep, ep)
            self.assertTrue(os.path.isfile(os.path.join(self.ROOT, ep)), f"missing {ep}")

    def test_no_symlinks_anywhere_a_plugin_folder_would_have_them(self):
        links = []
        for base, dirs, files in os.walk(self.ROOT):
            dirs[:] = [d for d in dirs if d != ".git"]
            links += [f for f in dirs + files if os.path.islink(os.path.join(base, f))]
        self.assertEqual(links, [])

    def test_both_manifests_and_the_daemon_agree_on_identity_and_version(self):
        root, nested = self.manifest(), self.manifest("plugin", "dial.radial")
        self.assertEqual(root["id"], nested["id"])
        self.assertEqual(root["version"], nested["version"])
        self.assertEqual(root["version"], m.__version__)
        self.assertTrue(
            root["entryPoints"]["panel"].endswith(nested["entryPoints"]["panel"]),
            "root entry point should point at the same QML file as the nested manifest",
        )


class AutoReturn(Base):
    """config "auto_return_s": how long an armed tool stays armed, read live."""

    def write(self, value):
        time.sleep(0.005)  # distinct mtime
        with open(self.cfg, "w") as f:
            json.dump({} if value is None else {"auto_return_s": value}, f)

    def after(self, tool_name):
        return m.disarm_after(m.TOOLS[tool_index(tool_name)])

    def test_default_is_the_original_six_seconds(self):
        self.write(None)
        self.assertEqual(self.after("Scroll"), 6.0)

    def test_a_configured_value_is_used_and_changes_apply_without_a_restart(self):
        self.write(15)
        self.assertEqual(self.after("Scroll"), 15.0)
        self.write(30)
        self.assertEqual(self.after("Scroll"), 30.0)

    def test_out_of_range_numbers_are_clamped(self):
        self.write(0.5)
        self.assertEqual(self.after("Scroll"), m.DISARM_MIN_S)
        self.write(100000)
        self.assertEqual(self.after("Scroll"), m.DISARM_MAX_S)

    def test_junk_means_the_default(self):
        for junk in ("long", True, None, [5], {"s": 5}, float("nan"), float("inf")):
            self.write(junk)
            self.assertEqual(self.after("Scroll"), 6.0, repr(junk))

    def test_a_tool_that_holds_a_modifier_is_capped(self):
        self.write(60)
        self.assertTrue(m.TOOLS[tool_index("Zoom")].get("hold_mod"))
        self.assertEqual(self.after("Zoom"), m.HOLD_MOD_DISARM_CAP_S)
        self.assertEqual(self.after("Scroll"), 60.0)

    def test_the_cap_never_lengthens_a_short_setting(self):
        self.write(4)
        self.assertEqual(self.after("Zoom"), 4.0)

    def armed_dial(self, tool_name):
        d = m.Dial()
        d.tool = tool_index(tool_name)
        d.last_action = 0.0
        return d

    def test_tick_returns_to_the_rest_tool_only_after_the_configured_time(self):
        self.write(15)
        d = self.armed_dial("Scroll")
        d.tick(7.0)  # past the old six seconds: still armed
        self.assertEqual(d.tool, tool_index("Scroll"))
        d.tick(16.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_tick_with_no_config_still_returns_after_six_seconds(self):
        self.write(None)
        d = self.armed_dial("Scroll")
        d.tick(5.0)
        self.assertEqual(d.tool, tool_index("Scroll"))
        d.tick(7.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_a_long_setting_does_not_keep_zoom_armed(self):
        self.write(60)
        d = self.armed_dial("Zoom")
        d.tick(11.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
