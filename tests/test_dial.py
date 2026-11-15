#!/usr/bin/env python3
"""Regression tests for the re:dial daemon's logic -- no dial, no display needed.

    python3 test_dial.py                      # tests ../bin/redial-hypr (the kit's copy)
    DIAL_DAEMON=~/.local/bin/redial-hypr python3 test_dial.py   # the live install

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
import re
import struct
import subprocess
import tempfile
import threading
import time
import types
import unittest
import unittest.mock

# Importing the daemon writes manifests into its config dir; keep that off the real one.
os.environ["DIAL_CONFIG_DIR"] = tempfile.mkdtemp()
os.environ["DIAL_LOG_PATH"] = os.path.join(tempfile.mkdtemp(), "daemon.log")  # likewise for its log

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.environ.get("DIAL_DAEMON") or os.path.join(HERE, "..", "bin", "redial-hypr")


def load_daemon():
    loader = importlib.machinery.SourceFileLoader(
        "dialmod", os.path.abspath(os.path.expanduser(DAEMON))
    )
    spec = importlib.util.spec_from_loader("dialmod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


m = load_daemon()
m.MENU_NOTES.PATH = None  # no test may reach the overlay running on this machine
m.DEFAULT_TOOLS = m.default_tools(has_backlight=True)  # the same ring on a laptop and a desktop
# What the daemon module looked like before any test touched it. Base restores every attribute a
# test changed, so one test's stub can never leak into the next (one did: read_brightness).
PRISTINE = dict(vars(m))


def restore_pristine():
    for name, value in PRISTINE.items():
        if vars(m).get(name) is not value:
            setattr(m, name, value)


_run_test = unittest.TestCase.run


def _run_isolated(self, result=None):
    """Every test, whatever its base class, leaves the daemon module as it found it."""
    try:
        return _run_test(self, result)
    finally:
        restore_pristine()


unittest.TestCase.run = _run_isolated


EVENTS = []
OSDS = []  # what the on-screen display was asked to show
SHOWN = []  # which level overlays (volume, brightness) were asked for


def _level_reset():
    OSDS.clear()
    SHOWN.clear()
    m._level_pending.clear()


POSITIONS = []


class Haptics:
    def fire(self, *a, **k):
        pass


class Recorder:
    """Stands in for MENU_UI / MENU_STREAM."""

    overlay = False

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


class Notes:
    """Stands in for MENU_NOTES: records each note; `listening` says whether the overlay took it."""

    def __init__(self, listening=False):
        self.listening = listening
        self.sent = []

    def note(self, kind, doc):
        if self.listening:
            self.sent.append((kind, doc))
        return self.listening

    def turn_wait(self):
        return 0.0


def install_stubs(cfg_path):
    m.HAPTIC = Haptics()
    m.MENU_UI = m.MENU_STREAM = Recorder()
    m.omarchy_shell = lambda: True  # the suite describes Omarchy; CI has no omarchy-shell
    m.MENU_NOTES = Notes()
    m.key = lambda *k: EVENTS.append("KEY:" + "+".join(k))
    m.dictation_toggle = lambda: EVENTS.append("DICTATION")
    m.notify = lambda *a, **k: None
    m.osd = lambda **k: OSDS.append(k)
    m._show_level = lambda kind: SHOWN.append(kind)
    _level_reset()
    m.run = m.launch = lambda cmd: EVENTS.append("EXEC:" + " ".join(cmd[:2]))
    m.hypr = lambda lua: EVENTS.append("HYPR:" + lua)
    m.media_command = lambda op: EVENTS.append("MEDIA:" + op)  # never the real players here
    m.settings_window_focused = lambda: True
    m.focused_runs_suppressed_program = lambda: None  # never the real desktop's windows
    m.CONFIG_PATH = cfg_path
    m.ACTIONS.inline = True  # assert straight after a gesture, not after a worker thread
    m.TOOLS = m.build_tools(m.DEFAULT_TOOLS)  # what the daemon runs with and no config
    for cache in (m._click_cache, m._pen_tail_cache, m._pen_barrel_cache):
        cache.clear()
    m._live.update(mtime=object())


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
            "Text",
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
        self.assertEqual(self.gesture(2), ["MEDIA:play-pause"])
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
        m.TOOLS = m.build_tools(m.TOOL_LIBRARY)  # Arrow Keys is off the default ring
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

        m.subprocess = types.SimpleNamespace(
            run=fake, Popen=subprocess.Popen, SubprocessError=subprocess.SubprocessError
        )
        m._media.update(at=0.0, pick=None, last=None)
        m._seek_warned = 0.0
        self.addCleanup(lambda: setattr(m, "subprocess", subprocess))
        self.logs, self.cants = [], []
        m.log = self.logs.append
        m.cant_note = lambda *a: self.cants.append(a)
        m.show_level = lambda kind: None

    def seeks(self):
        return [" ".join(c[1:]) for c in self.calls if "position" in c]

    def test_step_doubles_per_speed_step(self):
        self.players = "jelly\tPlaying\n"
        for mag, secs in ((1, 5), (2, 10), (3, 20), (4, 40)):
            self.calls.clear()
            m._media["at"] = 0.0
            m.seek_media(True, mag)
            self.assertEqual(self.seeks(), [f"-p jelly position {secs}+"])
        self.calls.clear()
        m.seek_media(False, 1)
        self.assertTrue(self.seeks()[0].endswith("position 5-"))

    def test_prefers_playing_over_paused(self):
        self.players = "firefox.instance_1_2\tPaused\nmpv\tPlaying\n"
        m.seek_media(True, 1)
        self.assertIn("-p mpv", self.seeks()[0])

    def test_two_tabs_of_one_browser_are_told_apart(self):
        # YouTube in one tab, Jellyfin in another: both "firefox", different instances.
        self.players = "firefox.instance_1_2\tPaused\nfirefox.instance_1_9\tPlaying\n"
        m.seek_media(True, 1)
        self.assertIn("-p firefox.instance_1_9 ", self.seeks()[0] + " ")
        ask = next(c for c in self.calls if c[:3] == ["playerctl", "-a", "metadata"])
        self.assertIn("{{playerInstance}}", ask[-1])  # the instance, never the app name

    def test_the_click_works_the_player_the_turn_scrubbed(self):
        self.players = "vlc\tPaused\nchromium.instance9\tPlaying\n"
        m.seek_media(True, 1)
        PRISTINE["media_command"]("play-pause")  # pauses it
        self.players = "vlc\tPaused\nchromium.instance9\tPaused\n"
        PRISTINE["media_command"]("play-pause")  # and resumes the same one, not VLC
        pp = [c for c in self.calls if "play-pause" in c]
        self.assertEqual([c[2] for c in pp], ["chromium.instance9", "chromium.instance9"])

    def test_with_two_playing_the_last_one_worked_stays(self):
        self.assertEqual(m.pick_player([("a", "Playing"), ("b", "Playing")], "b"), "b")
        self.assertEqual(m.pick_player([("a", "Playing"), ("b", "Playing")], None), "a")
        self.assertEqual(m.pick_player([("a", "Stopped"), ("b", "Paused")], None), "b")
        self.assertEqual(m.pick_player([("a", "Stopped")], None), "a")
        self.assertIsNone(m.pick_player([], "gone"))

    def test_nothing_playing_says_so_instead_of_guessing(self):
        self.players = ""
        m.seek_media(True, 1)
        self.assertEqual(self.seeks(), [])
        self.assertEqual(self.cants[0][1], "Media can't act")

    def test_player_lookup_is_cached(self):
        self.players = "mpv\tPlaying\n"
        for _ in range(6):
            m.seek_media(True, 1)
        self.assertEqual(sum(1 for c in self.calls if c[:3] == ["playerctl", "-a", "metadata"]), 1)

    def test_failures_are_rate_limited(self):
        self.players = "mpv\tPlaying\n"
        self.rc = 1
        for _ in range(10):
            m.seek_media(True, 1)
        self.assertEqual(len(self.logs), 1)
        self.assertEqual(len(self.cants), 1)

    def test_the_readout_is_position_and_title(self):
        self.calls.clear()

        def fake(cmd, **kw):
            return types.SimpleNamespace(
                stdout="83000000\t166000000\tA song\n", stderr="", returncode=0
            )

        m.subprocess.run = fake
        self.assertEqual(m.media_reading("vlc"), (50, "1:23 / 2:46  A song"))
        m.subprocess.run = lambda cmd, **kw: types.SimpleNamespace(
            stdout="0\t\tLive\n", stderr="", returncode=0
        )
        self.assertEqual(m.media_reading("vlc"), (None, "Live"))
        self.assertIsNone(m.media_reading(None))


class DictationNotice(unittest.TestCase):
    """The notice must say whether voxtype actually answered, not just that we asked."""

    def notice(self, rc, out):
        shown = []
        m.notify = lambda title, body="": shown.append(title)

        def fake(cmd, **kw):
            return types.SimpleNamespace(stdout=out, stderr="", returncode=rc)

        with unittest.mock.patch.object(
            m.subprocess, "run", fake
        ):  # the real module; must not leak
            m.dictation_toggle()
        return shown

    def test_running_voxtype_says_toggled(self):
        self.assertEqual(self.notice(0, ""), ["\U0001f399  Dictation"])

    def test_dead_voxtype_says_unavailable(self):
        self.assertEqual(
            self.notice(1, "Error: Voxtype daemon is not running"),
            ["\U0001f399  Dictation unavailable"],
        )


class Brightness(unittest.TestCase):
    def setUp(self):
        self.sent, self.pct = [], 60
        m.read_brightness = lambda d=None: self.pct
        m.backlight_device = lambda: "intel_backlight"
        m.run = lambda cmd: self.sent.append(cmd)
        m.show_level = lambda kind: None  # the on-screen display has its own tests

    def test_step_and_magnitude(self):
        for mag in (1, 2, 3, 4):
            self.sent.clear()
            m.set_brightness(mag, False)
            self.assertEqual(self.sent[0][-1], f"{60 - 2 * mag}%")

    def test_with_no_backlight_it_says_so_instead_of_staying_silent(self):
        said = []
        m.osd = lambda **k: said.append(k)
        m._bright_said[0] = -1e9
        self.pct = None
        m.set_brightness(1, True)
        m.set_brightness(1, True)  # a second turn right away does not repeat it
        self.assertEqual(said, [{"message": "No screen backlight on this machine"}])
        self.assertEqual(self.sent, [])

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

    def test_no_backlight_changes_nothing(self):
        m.read_brightness = lambda d=None: None
        m.osd = lambda **k: None  # the message has its own test
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

        real = m.subprocess
        m.subprocess = types.SimpleNamespace(run=fake)
        self.addCleanup(lambda: setattr(m, "subprocess", real))
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
        m.shutil = types.SimpleNamespace(
            which=lambda n: "/x" if have_omarchy or n == "notify-send" else None
        )

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

    def test_falls_back_to_notify_send_and_still_replaces(self):
        self.stub(False)
        m._notify_sync("One")
        m._notify_sync("Two")
        kind, cmd = self.calls[1]
        self.assertEqual((kind, cmd[0]), ("sub", "notify-send"))
        self.assertEqual(cmd[cmd.index("-r") + 1], "45")

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
        root, nested = self.manifest(), self.manifest("plugin", "redial")
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
        self.assertEqual(self.after("Undo"), 6.0)

    def test_a_configured_value_is_used_and_changes_apply_without_a_restart(self):
        self.write(15)
        self.assertEqual(self.after("Undo"), 15.0)
        self.write(30)
        self.assertEqual(self.after("Undo"), 30.0)

    def test_out_of_range_numbers_are_clamped(self):
        self.write(0.5)
        self.assertEqual(self.after("Undo"), m.DISARM_MIN_S)
        self.write(100000)
        self.assertEqual(self.after("Undo"), m.DISARM_MAX_S)

    def test_junk_means_the_default(self):
        for junk in ("long", True, None, [5], {"s": 5}, float("nan"), float("inf")):
            self.write(junk)
            self.assertEqual(self.after("Undo"), 6.0, repr(junk))

    def test_a_tool_that_holds_a_modifier_is_capped(self):
        self.write(60)
        self.assertTrue(m.TOOLS[tool_index("Zoom")].get("hold_mod"))
        self.assertEqual(self.after("Zoom"), m.HOLD_MOD_DISARM_CAP_S)
        self.assertEqual(self.after("Undo"), 60.0)

    def test_reading_tools_stay_a_minute_but_never_shorter_than_yours(self):
        self.write(None)
        for name in ("Scroll", "Settings"):
            self.assertEqual(self.after(name), m.READING_RETURN_S)
        self.assertEqual(self.after("Undo"), 6.0)
        self.write(200)
        self.assertEqual(self.after("Scroll"), 200.0)

    def test_tool_return_s_sets_one_tool_and_is_clamped(self):
        for value, want in ((10, 10.0), (1, m.DISARM_MIN_S), (9999, m.DISARM_MAX_S)):
            time.sleep(0.005)
            with open(self.cfg, "w") as f:
                json.dump({"auto_return_s": 20, "tool_return_s": {"Scroll": value}}, f)
            self.assertEqual(self.after("Scroll"), want)
            self.assertEqual(self.after("Undo"), 20.0)
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"tool_return_s": {"Scroll": "long", "Undo": True}}, f)
        self.assertEqual(self.after("Scroll"), m.READING_RETURN_S)
        self.assertEqual(self.after("Undo"), 6.0)

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
        d = self.armed_dial("Undo")
        d.tick(7.0)  # past the old six seconds: still armed
        self.assertEqual(d.tool, tool_index("Undo"))
        d.tick(16.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_tick_with_no_config_still_returns_after_six_seconds(self):
        self.write(None)
        d = self.armed_dial("Undo")
        d.tick(5.0)
        self.assertEqual(d.tool, tool_index("Undo"))
        d.tick(7.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_a_long_setting_does_not_keep_zoom_armed(self):
        self.write(60)
        d = self.armed_dial("Zoom")
        d.tick(11.0)
        self.assertEqual(d.tool, m.IDLE_TOOL)


class FeelSettings(Base):
    """sensitivity, double_click_ms, hold_ms and return_buzz: read live, validated, and used."""

    def write(self, **kv):
        time.sleep(0.005)  # distinct mtime
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    # --- reading and validating
    def test_defaults_are_the_original_behaviour(self):
        self.write()
        self.assertEqual(m.sensitivity(), 1.0)
        self.assertEqual(m.double_window(), 0.25)
        self.assertEqual(m.hold_time(), 0.4)
        self.assertTrue(m.return_buzz())

    def test_values_are_used_and_changes_apply_without_a_restart(self):
        self.write(sensitivity=1.5, double_click_ms=400, hold_ms=700, return_buzz=False)
        self.assertEqual(
            (m.sensitivity(), m.double_window(), m.hold_time(), m.return_buzz()),
            (1.5, 0.4, 0.7, False),
        )
        self.write(sensitivity=0.6)
        self.assertEqual(m.sensitivity(), 0.6)

    def test_out_of_range_numbers_are_clamped(self):
        self.write(sensitivity=99, double_click_ms=1, hold_ms=99999)
        self.assertEqual(m.sensitivity(), 2.0)
        self.assertEqual(m.double_window(), 0.15)
        self.assertEqual(m.hold_time(), 1.5)
        self.write(sensitivity=0)
        self.assertEqual(m.sensitivity(), 0.5)

    def test_junk_means_the_default(self):
        for junk in ("fast", True, None, [1], float("nan"), float("inf")):
            self.write(sensitivity=junk, double_click_ms=junk, hold_ms=junk, return_buzz=junk)
            self.assertEqual(
                (m.sensitivity(), m.double_window(), m.hold_time(), m.return_buzz()),
                (1.0, 0.25, 0.4, True),
                repr(junk),
            )

    # --- sensitivity changes how far you turn
    def test_higher_sensitivity_means_a_shorter_step(self):
        base = m.TOOLS[tool_index("Volume")]["detent"]
        d = m.Dial()
        for sens, want in ((1.0, base), (2.0, round(base / 2)), (0.5, base * 2)):
            self.write(sensitivity=sens)
            self.assertEqual(d.detent(), want, sens)

    def test_a_step_is_never_less_than_one_count(self):
        self.write(sensitivity=2.0)
        d = m.Dial()
        for t in m.TOOLS:
            d.tool = m.TOOLS.index(t)
            self.assertGreaterEqual(d.detent(), 1)

    def test_scroll_gain_scales_with_sensitivity(self):
        sent = []
        real_pointer, real_focus = m.POINTER, m.focused_class
        m.POINTER = types.SimpleNamespace(scroll=sent.append)
        m.focused_class = lambda: ""  # never ask the real compositor in a test
        self.addCleanup(
            lambda: (setattr(m, "POINTER", real_pointer), setattr(m, "focused_class", real_focus))
        )
        out = {}
        for sens in (1.0, 2.0):
            self.write(sensitivity=sens)
            d = m.Dial()
            d.tool = tool_index("Scroll")
            sent.clear()
            d.on_rotate(10, 0.0)
            out[sens] = sent[0]
        self.assertAlmostEqual(out[2.0], out[1.0] * 2)

    def test_the_menu_needs_less_turning_at_higher_sensitivity(self):
        def picks(sens):
            self.write(sensitivity=sens)
            d = m.Dial()
            d.menu, d.menu_pick, d.menu_accum = True, 0, 0.0
            d.on_rotate(m.MENU_STEP // 2, 0.0)
            return d.menu_pick

        self.assertEqual(picks(1.0), 0)  # half a step: not yet
        self.assertEqual(picks(2.0), 1)  # the same turn is a whole step now

    # --- click timing
    def test_holding_to_open_the_menu_uses_the_configured_time(self):
        def opened_at(hold_ms, t):
            self.write(hold_ms=hold_ms)
            d = m.Dial()
            d.on_press(0.0)
            d.tick(t)
            return d.menu

        self.assertTrue(opened_at(400, 0.5))
        self.assertFalse(opened_at(1000, 0.5))
        self.assertTrue(opened_at(1000, 1.1))

    def test_a_single_click_waits_for_the_configured_double_click_window(self):
        def fired_by(window_ms, t):
            self.write(double_click_ms=window_ms)
            EVENTS.clear()
            d = m.Dial()
            d.on_press(0.0)
            d.on_release(0.05)
            d.tick(t)
            return bool(EVENTS)

        self.assertTrue(fired_by(250, 0.4))  # default: past the window, the click fires
        self.assertFalse(fired_by(600, 0.4))  # relaxed: still waiting for a second press
        self.assertTrue(fired_by(600, 0.8))

    def test_a_press_shorter_than_the_hold_time_is_still_a_click(self):
        # Held 0.6 s with a 1 s hold setting: too short to open the menu, so it must count as
        # a click, not be dropped as a (never-completed) hold.
        self.write(hold_ms=1000)
        EVENTS.clear()
        d = m.Dial()
        d.on_press(0.0)
        d.tick(0.6)
        d.on_release(0.6)
        d.tick(1.2)
        self.assertFalse(d.menu)
        self.assertTrue(EVENTS, "the click was swallowed")

    def test_a_second_press_inside_a_widened_window_is_a_double_click(self):
        def run(window_ms):
            self.write(double_click_ms=window_ms)
            EVENTS.clear()
            d = m.Dial()
            d.on_press(0.0)
            d.on_release(0.05)
            d.tick(0.3)  # the default window has expired by now; a wider one has not
            d.on_press(0.45)
            d.on_release(0.5)
            d.tick(1.6)
            return list(EVENTS)

        self.assertNotIn("DICTATION", run(250))  # two separate single clicks
        self.assertIn("DICTATION", run(600))  # one double click

    def test_a_third_press_inside_a_widened_window_is_a_triple_click(self):
        def run(window_ms):
            self.write(double_click_ms=window_ms)
            EVENTS.clear()
            d = m.Dial()
            d.on_press(0.0)
            d.on_release(0.05)
            d.on_press(0.2)
            d.on_release(0.25)  # second press done: now waiting for a possible third
            d.tick(0.6)  # the default window has expired by now; a wider one has not
            d.on_press(0.65)
            d.tick(2.0)
            return list(EVENTS)

        self.assertNotIn(
            "KEY:Return", run(250)
        )  # double fired first; the third press is a new click
        self.assertIn("KEY:Return", run(600))  # a real triple click (default action: Enter)

    # --- the on-screen display
    def test_the_on_screen_display_is_on_by_default_and_can_be_turned_off(self):
        self.write()
        self.assertTrue(m.osd_enabled())
        self.write(osd=False)
        self.assertFalse(m.osd_enabled())
        self.write(osd="junk")
        self.assertTrue(m.osd_enabled())  # not a true/false means the default

    def test_with_the_display_off_nothing_is_shown_or_queued(self):
        self.write(osd=False)
        jobs, cmds = [], []
        m.ACTIONS = types.SimpleNamespace(submit=lambda fn, *a: jobs.append(fn))
        m.shutil = types.SimpleNamespace(which=lambda name: f"/x/{name}")
        m.run = cmds.append
        m.show_level("volume")
        PRISTINE["osd"](icon="volume", progress=40)
        m.Dial().on_rotate(1, 1.0)  # a first turn would normally be acknowledged
        self.assertEqual((jobs, cmds), ([], []))

    def test_turning_the_display_back_on_applies_without_a_restart(self):
        self.write(osd=False)
        m.ACTIONS = types.SimpleNamespace(submit=lambda fn, *a: None)
        m.show_level("volume")
        self.assertEqual(m._level_pending, set())
        self.write(osd=True)
        m.show_level("volume")
        self.assertEqual(m._level_pending, {"volume"})

    # --- the return buzz
    def test_the_return_buzz_can_be_turned_off(self):
        buzzed = []
        m.HAPTIC = types.SimpleNamespace(fire=lambda pattern, **k: buzzed.append(pattern))
        for on, want in ((True, [m.PAT_IDLE]), (False, [])):
            self.write(return_buzz=on)
            buzzed.clear()
            d = m.Dial()
            d.tool = tool_index("Scroll")
            d.disarm(1.0)
            self.assertEqual(buzzed, want, on)


class DaemonLog(unittest.TestCase):
    """log() also writes a small rotating file; stderr is /dev/null when started the Omarchy way."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "sub", "daemon.log")  # parent does not exist yet
        self.real = (m.LOG_PATH, m.LOG_MAX_BYTES)
        m.LOG_PATH = self.path
        self.addCleanup(
            lambda: (
                setattr(m, "LOG_PATH", self.real[0]),
                setattr(m, "LOG_MAX_BYTES", self.real[1]),
            )
        )
        self.quiet = types.SimpleNamespace(write=lambda s: None, flush=lambda: None)
        real_stderr = sys.stderr
        sys.stderr = self.quiet
        self.addCleanup(lambda: setattr(sys, "stderr", real_stderr))

    def lines(self, path=None):
        with open(path or self.path) as fh:
            return fh.read().splitlines()

    def test_a_line_is_written_with_a_timestamp(self):
        m.log("attached to /dev/input/event9")
        (line,) = self.lines()
        self.assertRegex(line, r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d attached to /dev/input/event9$")

    def test_lines_accumulate(self):
        for i in range(3):
            m.log(f"line {i}")
        self.assertEqual([x.split(" ", 2)[2] for x in self.lines()], ["line 0", "line 1", "line 2"])

    def test_it_rotates_once_it_grows_past_the_cap(self):
        m.LOG_MAX_BYTES = 200
        for i in range(30):
            m.log(f"a reasonably long log line number {i}")
        self.assertTrue(os.path.exists(self.path + ".1"), "no rotation happened")
        self.assertLess(os.path.getsize(self.path), 200 + 100)
        self.assertEqual(self.lines()[-1].split(" ", 2)[2], "a reasonably long log line number 29")

    def test_an_unwritable_location_never_raises(self):
        m.LOG_PATH = "/proc/this/cannot/be/created/daemon.log"
        m.log("must not raise")

    def test_concurrent_writers_never_split_a_line(self):
        def spam(tag):
            for i in range(40):
                m.log(f"{tag} message {i}")

        threads = [threading.Thread(target=spam, args=(f"T{n}",)) for n in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        lines = self.lines()
        self.assertEqual(len(lines), 160)
        self.assertTrue(all(re.search(r" T\d message \d+$", x) for x in lines))


class LatchedMenu(Base):
    """menu_latch: a quick hold-and-release leaves the menu open for turn-then-click."""

    def write(self, **kv):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    def opened(self):
        d = m.Dial()
        d.on_press(0.0)
        d.tick(0.5)
        self.assertTrue(d.menu)
        return d

    def test_off_by_default_release_selects_as_before(self):
        self.write()
        d = self.opened()
        d.on_release(0.6)
        self.assertFalse(d.menu)

    def test_release_without_turning_keeps_the_menu_open(self):
        self.write(menu_latch=True)
        d = self.opened()
        d.on_release(0.6)
        self.assertTrue(d.menu)
        self.assertTrue(d.menu_latched)

    def test_turn_then_click_chooses_the_highlighted_tool(self):
        self.write(menu_latch=True)
        d = self.opened()
        d.on_release(0.6)
        d.on_rotate(m.MENU_STEP, 1.0)
        want = d.menu_pick
        self.assertNotEqual(want, m.IDLE_TOOL)
        d.on_press(1.5)
        d.on_release(1.6)
        self.assertFalse(d.menu)
        self.assertEqual(d.tool, want)

    def test_turning_while_still_holding_keeps_the_classic_release_to_select(self):
        self.write(menu_latch=True)
        d = self.opened()
        d.on_rotate(m.MENU_STEP, 0.6)
        d.on_release(0.8)
        self.assertFalse(d.menu)
        self.assertNotEqual(d.tool, m.IDLE_TOOL)

    def test_tiny_tremor_turn_does_not_count_as_moving(self):
        self.write(menu_latch=True)
        d = self.opened()
        d.on_rotate(m.MENU_STEP // 4, 0.6)
        d.on_release(0.8)
        self.assertTrue(d.menu, "a twitch under one step must not defeat the latch")

    def test_untouched_latched_menu_closes_without_changing_the_tool(self):
        self.write(menu_latch=True, menu_timeout_ms=5000)
        d = self.opened()
        d.on_release(0.6)
        d.tick(4.0)
        self.assertTrue(d.menu)
        d.tick(6.0)
        self.assertFalse(d.menu)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_turning_extends_the_timeout(self):
        self.write(menu_latch=True, menu_timeout_ms=5000)
        d = self.opened()
        d.on_release(0.6)
        d.on_rotate(m.MENU_STEP // 4, 4.0)
        d.tick(8.0)
        self.assertTrue(d.menu)

    def test_the_timeout_is_clamped(self):
        self.write(menu_timeout_ms=10)
        self.assertEqual(m.menu_idle_timeout(), 3.0)
        self.write(menu_timeout_ms=10**6)
        self.assertEqual(m.menu_idle_timeout(), 12.0)

    def test_a_latched_menu_is_closed_on_detach(self):
        self.write(menu_latch=True)
        d = self.opened()
        d.on_release(0.6)
        d.reset_gestures()
        self.assertFalse(d.menu)
        self.assertFalse(d.menu_latched)


class DeadZone(Base):
    """deadzone: small turns after a pause are held back; a real turn passes whole."""

    def write(self, **kv):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    def test_off_by_default_nothing_is_held_back(self):
        self.write()
        d = m.Dial()
        self.assertEqual(d.through_deadzone(1, 0.0), 1)

    def test_a_twitch_inside_the_zone_is_ignored(self):
        self.write(deadzone=20)
        d = m.Dial()
        self.assertEqual(d.through_deadzone(5, 0.0), 0)
        self.assertEqual(d.through_deadzone(-4, 0.01), 0)
        self.assertEqual(d.dz_accum, 1)

    def test_back_and_forth_tremor_never_gets_through(self):
        self.write(deadzone=20)
        d = m.Dial()
        out = [d.through_deadzone(v, 0.01 * i) for i, v in enumerate([6, -6] * 30)]
        self.assertEqual(sum(abs(v) for v in out), 0)

    def test_a_real_turn_is_released_whole_then_unfiltered(self):
        self.write(deadzone=20)
        d = m.Dial()
        got = [d.through_deadzone(8, 0.01 * i) for i in range(5)]
        self.assertEqual(got, [0, 0, 24, 8, 8])  # nothing is lost: 8+8+8 released together

    def test_a_pause_brings_the_zone_back(self):
        self.write(deadzone=20)
        d = m.Dial()
        for i in range(4):
            d.through_deadzone(8, 0.01 * i)
        self.assertEqual(d.through_deadzone(8, 1.0), 0)  # after a pause: filtered again

    def test_a_slow_deliberate_turn_still_gets_through(self):
        # Events 50 ms apart (slower than the rest gap check would punish if it used the
        # last *passed* event): 1 count each, 25 events -> crosses 20.
        self.write(deadzone=20)
        d = m.Dial()
        out = [d.through_deadzone(1, 0.05 * i) for i in range(25)]
        self.assertEqual(sum(out), 25)

    def test_filtered_turns_do_not_keep_the_tool_armed_or_reach_the_tool(self):
        self.write(deadzone=50)
        d = m.Dial()
        d.last_action = 0.0
        EVENTS.clear()
        d.on_rotate(10, 1.0)
        self.assertEqual(d.last_action, 0.0)
        self.assertFalse(EVENTS)

    def test_it_also_filters_the_tool_menu(self):
        self.write(deadzone=50)
        d = m.Dial()
        d.menu, d.menu_pick, d.menu_accum = True, 0, 0.0
        d.on_rotate(m.MENU_STEP, 0.0)  # 60 >= 50: crosses the zone, moves one step
        self.assertEqual(d.menu_pick, 1)
        d2 = m.Dial()
        d2.menu, d2.menu_pick, d2.menu_accum = True, 0, 0.0
        d2.on_rotate(m.MENU_STEP // 2, 0.0)
        self.assertEqual(d2.menu_pick, 0)

    def test_range_is_clamped(self):
        self.write(deadzone=10**6)
        self.assertEqual(m.deadzone(), 100)
        self.write(deadzone=-5)
        self.assertEqual(m.deadzone(), 0)


class Status(Base):
    """status.json: what the settings window shows about the dial."""

    def test_parses_connected_and_battery(self):
        text = "Device AA (public)\n\tConnected: yes\n\tBattery Percentage: 0x60 (96)\n"
        self.assertEqual(m.parse_bluetooth_info(text), (True, 96))

    def test_parses_disconnected_without_battery(self):
        self.assertEqual(m.parse_bluetooth_info("\tConnected: no\n"), (False, None))

    def test_unknown_when_the_output_is_empty(self):
        self.assertEqual(m.parse_bluetooth_info(""), (None, None))

    def test_battery_is_clamped(self):
        self.assertEqual(m.parse_bluetooth_info("Battery Percentage: 0xff (255)")[1], 100)

    def test_state_is_ready_when_attached(self):
        self.assertEqual(m.build_status(True, False, None)["state"], "ready")

    def test_state_is_asleep_when_bluetooth_says_disconnected(self):
        self.assertEqual(m.build_status(False, False, None)["state"], "asleep")

    def test_state_is_waiting_when_the_reason_is_unknown(self):
        self.assertEqual(m.build_status(False, None, None)["state"], "waiting")
        self.assertEqual(m.build_status(False, True, 50)["state"], "waiting")

    def test_status_carries_version_pid_and_time(self):
        doc = m.build_status(True, True, 80, now=1234.56)
        self.assertEqual(doc["version"], m.__version__)
        self.assertEqual(doc["pid"], os.getpid())
        self.assertEqual(doc["updated"], 1234.6)
        self.assertEqual(doc["battery"], 80)
        self.assertFalse(doc["keeping_awake"])
        self.assertTrue(m.build_status(True, True, 80, keeping_awake=True)["keeping_awake"])

    def test_write_is_atomic_and_readable(self):
        old = m.STATUS_PATH
        m.STATUS_PATH = os.path.join(self.tmp, "sub", "status.json")
        try:
            m.write_status(m.build_status(True, True, 70))
            with open(m.STATUS_PATH) as f:
                self.assertEqual(json.load(f)["battery"], 70)
            self.assertEqual(os.listdir(os.path.dirname(m.STATUS_PATH)), ["status.json"])
        finally:
            m.STATUS_PATH = old

    def test_a_missing_bluetooth_tool_gives_unknown_not_a_crash(self):
        real = m.subprocess.run

        def boom(*a, **k):
            raise FileNotFoundError("bluetoothctl")

        m.subprocess.run = boom
        try:
            self.assertEqual(m.dial_bluetooth(), (None, None))
        finally:
            m.subprocess.run = real


class FakePointer:
    def __init__(self):
        self.scrolls, self.clicks, self.moves, self.h_scrolls = [], [], [], []

    def scroll(self, v, horizontal=False):
        (self.h_scrolls if horizontal else self.scrolls).append(v)

    def move(self, dx, dy):
        self.moves.append((dx, dy))

    def click(self, btn, down):
        self.clicks.append((btn, down))


class PenConfig(Base):
    """The pen's click settings: read live, validated, unusable values fall back."""

    def write(self, pen):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"pen": pen}, f)

    def test_tail_defaults(self):
        self.write({})
        self.assertEqual(
            [m.pen_tail_choice(k) for k in ("single", "double", "hold")],
            ["space", "enter", "dictation"],
        )

    def test_tail_choices_are_used_live(self):
        self.write({"tail_clicks": {"single": "escape"}})
        self.assertEqual(m.pen_tail_choice("single"), "escape")
        self.write({"tail_clicks": {"single": "enter"}})
        self.assertEqual(m.pen_tail_choice("single"), "enter")

    def test_tail_unknown_action_falls_back_to_the_default(self):
        self.write({"tail_clicks": {"double": "launch-missiles", "hold": 7}})
        self.assertEqual(m.pen_tail_choice("double"), "enter")
        self.assertEqual(m.pen_tail_choice("hold"), "dictation")

    def test_tail_junk_section_is_ignored(self):
        self.write({"tail_clicks": "nonsense"})
        self.assertEqual(m.pen_tail_choice("single"), "space")

    def test_tail_unbound_action_compiles_to_none_not_an_error(self):
        self.write({"tail_clicks": {"single": "none"}})
        self.assertIsNone(m.pen_tail_fn("single"))

    def test_a_pen_section_that_is_not_an_object_is_ignored(self):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"pen": "oops"}, f)
        self.assertEqual(m.pen_tail_choice("single"), "space")
        self.assertEqual(m.pen_barrel_config(), (True, "right_click"))

    def test_barrel_defaults_to_right_click_enabled(self):
        self.write({})
        self.assertEqual(m.pen_barrel_config(), (True, "right_click"))

    def test_barrel_can_be_disabled_and_remapped(self):
        self.write({"barrel": {"enabled": False, "action": "middle_click"}})
        self.assertEqual(m.pen_barrel_config(), (False, "middle_click"))

    def test_barrel_unknown_action_falls_back(self):
        self.write({"barrel": {"action": "bogus"}})
        self.assertEqual(m.pen_barrel_config(), (True, "right_click"))


class Eraser(Base):
    """EraserState: tap = Escape, hold = delete word, drag = scroll or cursor, allowlist only."""

    def setUp(self):
        super().setUp()
        self.ptr = FakePointer()
        self._saved = (m.POINTER, m.focused_class, m.scroll_mode)
        m.POINTER = self.ptr
        self.cls = "firefox"
        m.focused_class = lambda: self.cls
        m.scroll_mode = lambda: "wheel"
        with open(self.cfg, "w") as f:
            json.dump({}, f)
        self.e = m.EraserState()

    def tearDown(self):
        m.POINTER, m.focused_class, m.scroll_mode = self._saved

    def ev(self, code, value, now=0.0, etype=None):
        self.e.handle(m.EV_KEY if etype is None else etype, code, value, now)

    def down(self, now=0.0):
        self.ev(m.BTN_TOOL_RUBBER, 1)
        self.ev(m.BTN_TOUCH, 1, now)

    def up(self, now):
        self.ev(m.BTN_TOUCH, 0, now)

    def abs(self, code, v):
        self.e.handle(m.EV_ABS, code, v, 0.0)

    def test_a_quick_tap_sends_escape(self):
        self.down(0.0)
        self.up(0.1)
        self.assertEqual(EVENTS, ["KEY:Escape"])

    def configure(self, **pen):
        with open(self.cfg, "w") as f:
            json.dump({"pen": pen}, f)
        m._live.update(mtime=object())  # force a re-read

    def test_a_brief_brush_is_not_a_tap(self):
        # The log showed scrolls starting with a 30-60 ms bounce of contact that fired Escape.
        self.down(0.0)
        self.up(0.04)
        self.assertEqual(EVENTS, [])

    def test_the_brush_threshold_is_adjustable_and_can_be_switched_off(self):
        self.configure(eraser_tap_min_ms=250)
        self.down(0.0)
        self.up(0.2)
        self.assertEqual(EVENTS, [])
        self.configure(eraser_tap_min_ms=0)
        self.down(0.0)
        self.up(0.01)
        self.assertEqual(EVENTS, ["KEY:Escape"])

    def test_nonsense_thresholds_fall_back_to_the_default(self):
        for bad in ("fast", -5, 99999, True, None):
            self.configure(eraser_tap_min_ms=bad)
            self.assertEqual(m.pen_eraser_config()[2], m.ERASER_TAP_MIN_MS_DEFAULT / 1000.0, bad)

    def test_the_tap_can_be_set_to_nothing(self):
        self.configure(eraser={"tap": "none"})
        self.down(0.0)
        self.up(0.2)
        self.assertEqual(EVENTS, [])

    def test_the_tap_can_be_another_action(self):
        self.configure(eraser={"tap": "enter"})
        self.down(0.0)
        self.up(0.2)
        self.assertEqual(EVENTS, ["KEY:Return"])

    def test_the_hold_can_be_set_to_nothing_and_an_unknown_name_falls_back(self):
        self.configure(eraser={"hold": "none"})
        self.down(0.0)
        self.up(m.ERASER_HOLD_S + 0.1)
        self.assertEqual(EVENTS, [])
        self.configure(eraser={"tap": "teleport"})
        self.assertEqual(m.pen_eraser_config()[0], "escape")

    def test_the_settings_window_is_told_about_the_eraser_options(self):
        cfg = os.path.join(tempfile.mkdtemp(), "config.json")
        real = m.CONFIG_PATH
        m.CONFIG_PATH = cfg
        self.addCleanup(lambda: setattr(m, "CONFIG_PATH", real))
        m.write_tool_manifest()
        with open(os.path.join(os.path.dirname(cfg), "pen_clicks.json")) as f:
            doc = json.load(f)
        names = [a["name"] for a in doc["eraser"]["actions"]]
        self.assertEqual(doc["eraser"]["defaults"], {"tap": "escape", "hold": "delete_word"})
        self.assertIn("none", names)
        self.assertEqual(len(names), len(set(names)))

    def test_a_long_press_deletes_a_word(self):
        self.down(0.0)
        self.up(m.ERASER_HOLD_S + 0.1)
        self.assertEqual(EVENTS, ["KEY:ctrl+BackSpace"])

    def test_nothing_happens_outside_the_allowlist(self):
        self.cls = "some-editor"
        self.down(0.0)
        self.abs(m.ABS_Y, 0)
        self.abs(m.ABS_Y, 500)
        self.up(0.1)
        self.assertEqual(EVENTS, [])
        self.assertEqual(self.ptr.scrolls, [])

    def test_vertical_drag_scrolls_and_is_not_a_tap(self):
        self.down(0.0)
        for y in range(0, 400, 20):
            self.abs(m.ABS_Y, y)
        self.up(0.5)
        self.assertTrue(self.ptr.scrolls)
        self.assertNotIn("KEY:Escape", EVENTS)

    def test_scroll_starts_within_two_mm_and_replays_the_travel_before_it(self):
        # A ~5mm dead zone made every scroll start late; nothing before the lock is dropped.
        self.down(0.0)
        for y in range(0, 41, 4):  # 40 units, ~2.2mm
            self.abs(m.ABS_Y, y)
        self.assertTrue(self.ptr.scrolls)
        self.assertAlmostEqual(sum(self.ptr.scrolls), 40 * m.ERASER_SCROLL_GAIN["firefox"])

    def test_a_short_scroll_is_not_a_tap(self):
        self.down(0.0)
        for y in range(0, 60, 4):
            self.abs(m.ABS_Y, y)
        self.up(0.2)
        self.assertNotIn("KEY:Escape", EVENTS)

    def test_scroll_speed_scales_the_class_gain(self):
        self.configure(eraser_scroll_speed=2)
        self.down(0.0)
        for y in range(0, 101, 4):
            self.abs(m.ABS_Y, y)
        self.assertAlmostEqual(sum(self.ptr.scrolls), 100 * m.ERASER_SCROLL_GAIN["firefox"] * 2)

    def test_a_bad_scroll_speed_falls_back_to_normal(self):
        for bad in (0, 10, True, "fast"):
            self.configure(eraser_scroll_speed=bad)
            self.assertEqual(m.pen_eraser_config()[3], 1.0, bad)

    def test_scroll_is_suppressed_when_the_class_routes_to_keys(self):
        m.scroll_mode = lambda: "suppress"
        self.down(0.0)
        for y in range(0, 400, 20):
            self.abs(m.ABS_Y, y)
        self.assertEqual(self.ptr.scrolls, [])

    def test_horizontal_drag_moves_the_cursor_by_keys(self):
        self.down(0.0)
        for x in range(0, 600, 20):
            self.abs(m.ABS_X, x)
        self.assertIn("KEY:Right", EVENTS)
        self.assertNotIn("KEY:Left", EVENTS)
        self.assertEqual(self.ptr.scrolls, [])

    def test_leftward_drag_moves_the_cursor_left(self):
        self.down(0.0)
        for x in range(600, 0, -20):
            self.abs(m.ABS_X, x)
        self.assertIn("KEY:Left", EVENTS)

    def test_hovering_with_the_eraser_does_nothing(self):
        self.ev(m.BTN_TOOL_RUBBER, 1)
        self.abs(m.ABS_Y, 0)
        self.abs(m.ABS_Y, 900)
        self.assertEqual(self.ptr.scrolls, [])
        self.assertEqual(EVENTS, [])

    def test_touch_without_the_eraser_end_is_ignored(self):
        self.ev(m.BTN_TOUCH, 1, 0.0)
        self.up(0.1)
        self.assertEqual(EVENTS, [])

    def test_lifting_the_eraser_mid_drag_ends_it(self):
        self.down(0.0)
        self.ev(m.BTN_TOOL_RUBBER, 0)
        self.abs(m.ABS_Y, 0)
        self.abs(m.ABS_Y, 900)
        self.assertEqual(self.ptr.scrolls, [])

    def test_barrel_mouse_action_passes_press_and_release(self):
        with open(self.cfg, "w") as f:
            json.dump({"pen": {"barrel": {"action": "right_click"}}}, f)
        self.ev(m.BTN_STYLUS, 1)
        self.ev(m.BTN_STYLUS, 0)
        self.assertEqual([d for _, d in self.ptr.clicks], [True, False])

    def test_barrel_key_action_fires_once_on_press_only(self):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"pen": {"barrel": {"action": "enter"}}}, f)
        self.ev(m.BTN_STYLUS, 1)
        self.ev(m.BTN_STYLUS, 0)
        self.assertEqual(EVENTS, ["KEY:Return"])

    def barrel_hold_setup(self, **barrel):
        """Pen config + a fake Timer and action worker: returns (timers, ran)."""
        self.configure(barrel=barrel)
        timers, ran = [], []

        class FakeTimer:
            def __init__(self, secs, fn, args=()):
                self.secs, self.fn, self.args, self.cancelled = secs, fn, args, False
                self.daemon = False
                timers.append(self)

            def start(self):
                pass

            def cancel(self):
                self.cancelled = True

        fx = Fixture(self)
        fx.set(m.threading, "Timer", FakeTimer)
        fx.set(m, "ACTIONS", types.SimpleNamespace(submit=lambda fn, *a: (ran.append(fn), fn(*a))))
        return timers, ran

    def test_barrel_hold_is_off_by_default_so_press_is_unchanged(self):
        timers, _ = self.barrel_hold_setup(action="enter")
        self.ev(m.BTN_STYLUS, 1)
        self.assertEqual(EVENTS, ["KEY:Return"])  # still fires on press
        self.ev(m.BTN_STYLUS, 0)
        self.assertEqual(timers, [])

    def test_barrel_hold_fires_after_the_hold_time_and_skips_the_press_action(self):
        timers, ran = self.barrel_hold_setup(action="enter", hold="escape", hold_ms=600)
        self.ev(m.BTN_STYLUS, 1)
        self.assertEqual(EVENTS, [])  # the press action waits for release
        self.assertAlmostEqual(timers[0].secs, 0.6)
        timers[0].fn(*timers[0].args)  # held long enough
        self.assertEqual(EVENTS, ["KEY:Escape"])
        self.assertEqual(len(ran), 1)  # ran on the action worker, not the pen thread
        self.ev(m.BTN_STYLUS, 0)
        self.assertEqual(EVENTS, ["KEY:Escape"])  # no press action after a hold

    def test_a_short_barrel_press_fires_the_press_action_on_release(self):
        timers, _ = self.barrel_hold_setup(action="enter", hold="escape")
        self.ev(m.BTN_STYLUS, 1)
        self.ev(m.BTN_STYLUS, 0)
        self.assertTrue(timers[0].cancelled)
        self.assertEqual(EVENTS, ["KEY:Return"])
        timers[0].fn(*timers[0].args)  # a stale timer that fires anyway does nothing
        self.assertEqual(EVENTS, ["KEY:Return"])

    def test_barrel_right_click_still_passes_through_with_a_hold_set(self):
        timers, _ = self.barrel_hold_setup(action="right_click", hold="escape")
        self.ev(m.BTN_STYLUS, 1)
        timers[0].fn(*timers[0].args)
        self.ev(m.BTN_STYLUS, 0)
        self.assertEqual([d for _, d in self.ptr.clicks], [True, False])
        self.assertEqual(EVENTS, ["KEY:Escape"])

    def test_barrel_hold_time_is_clamped_and_bad_hold_falls_back_to_nothing(self):
        timers, _ = self.barrel_hold_setup(hold="escape", hold_ms=5)
        self.ev(m.BTN_STYLUS, 1)
        self.assertAlmostEqual(timers[0].secs, 0.25)
        self.ev(m.BTN_STYLUS, 0)
        self.configure(barrel={"hold": "right_click"})  # mouse buttons can't be a hold
        self.assertEqual(m.pen_barrel_hold(), ("none", 0.5))

    def test_disabled_barrel_does_nothing(self):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"pen": {"barrel": {"enabled": False}}}, f)
        self.ev(m.BTN_STYLUS, 1)
        self.assertEqual(EVENTS, [])
        self.assertEqual(self.ptr.clicks, [])


class Announce(Base):
    """announce_tool: the armed or highlighted tool is spoken, only when asked for."""

    def setUp(self):
        super().setUp()
        self.spoken = []
        self._saved = (m.speech_command, m.subprocess.Popen)
        m.speech_command = lambda: ["say"]

        class P:
            def __init__(p, cmd, **k):
                self.spoken.append(cmd[-1])

            def poll(p):
                return 0

        m.subprocess.Popen = P
        m._live.update(mtime=object())

    def tearDown(self):
        m.speech_command, m.subprocess.Popen = self._saved

    def write(self, **kv):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    def test_silent_by_default(self):
        self.write()
        d = m.Dial()
        d.show_tool("armed")
        self.assertEqual(self.spoken, [])

    def test_speaks_the_tool_name_when_armed(self):
        self.write(announce_tool=True)
        d = m.Dial()
        d._arm(tool_index("Scroll"), 0.0)
        d.show_tool("armed")
        self.assertEqual(self.spoken, ["Scroll"])

    def test_speaks_each_highlighted_tool_in_the_menu(self):
        self.write(announce_tool=True)
        d = m.Dial()
        d.menu, d.menu_pick, d.menu_accum = True, 0, 0.0
        d.on_rotate(m.MENU_STEP, 0.0)
        self.assertEqual(self.spoken, [m.TOOLS[1]["name"]])

    def test_missing_speech_tool_is_logged_once_not_raised(self):
        self.write(announce_tool=True)
        m.speech_command = lambda: None
        m._speech["warned"] = False
        m.speak("a")
        m.speak("b")
        self.assertTrue(m._speech["warned"])
        self.assertEqual(self.spoken, [])


class ActionSpecs(Base):
    """make_action: every verb compiles good specs and refuses bad ones without raising."""

    GOOD = [
        {"do": "exec", "cmd": ["true"]},
        {"do": "hypr", "lua": "x()"},
        {"do": "key", "keys": ["a"]},
        {"do": "key", "keys": ["a"], "terminal_keys": []},
        {"do": "brightness", "direction": "down", "step": 3},
        {"do": "seek", "direction": "back", "step": 2.5},
        {"do": "resize", "axis": "y", "direction": "shrink"},
        {"do": "volume", "direction": "down"},
        {"do": "dictation"},
        {"do": "mouse", "button": "left"},
        {"do": "mouse"},  # defaults to a right click, as the pen barrel does
        {"do": "wheel"},
    ]
    BAD = [
        {"do": "exec"},
        {"do": "exec", "cmd": "ls"},
        {"do": "exec", "cmd": ["ls", 1]},
        {"do": "hypr"},
        {"do": "hypr", "lua": ""},
        {"do": "key"},
        {"do": "key", "keys": []},
        {"do": "key", "keys": "a"},
        {"do": "key", "keys": ["a", 2]},
        {"do": "resize", "axis": "z"},
        {"do": "mouse", "button": "side"},
        {"do": "teleport"},
    ]

    def test_good_specs_compile_to_callables(self):
        for spec in self.GOOD:
            self.assertTrue(callable(m.make_action(spec)), spec)

    def test_bad_specs_are_refused_not_raised(self):
        for spec in self.BAD:
            self.assertIsNone(m.make_action(spec), spec)

    def test_non_objects_and_empty_are_refused(self):
        for spec in (None, {}, "exec", 5, [], {"do": "none"}, {"do": ""}):
            self.assertIsNone(m.make_action(spec), spec)

    def test_key_terminal_keys_junk_falls_back_to_plain_keys(self):
        fn = m.make_action({"do": "key", "keys": ["a"], "terminal_keys": "oops"})
        EVENTS.clear()
        fn(1)
        self.assertEqual(EVENTS, ["KEY:a"])

    def test_bad_numbers_use_the_defaults(self):
        calls = []
        real = m.set_brightness
        m.set_brightness = lambda mag, up, step, dev: calls.append((up, step))
        try:
            m.make_action({"do": "brightness", "step": "lots"})(1)
            m.make_action({"do": "brightness", "direction": "down", "step": 4})(1)
        finally:
            m.set_brightness = real
        self.assertEqual(calls, [(True, m.BRIGHT_STEP), (False, 4)])

    def test_direction_words(self):
        seen = []
        real = m.seek_media
        m.seek_media = lambda fwd, mag, step: seen.append(fwd)
        try:
            m.make_action({"do": "seek"})(1)
            m.make_action({"do": "seek", "direction": "back"})(1)
            m.make_action({"do": "seek", "direction": "BACK"})(1)
        finally:
            m.seek_media = real
        self.assertEqual(seen, [True, False, False])


class AxisToggle(Base):
    """Tools with axis_toggle (Arrow Keys, Tile Focus): a click flips vertical/horizontal."""

    def armed(self, name):
        m.TOOLS = m.build_tools(m.TOOL_LIBRARY)
        d = m.Dial()
        d._arm(tool_index(name), 0.0)
        return d

    def turn(self, d, counts):
        EVENTS.clear()
        d.on_rotate(counts, 0.0)
        return list(EVENTS)

    def flip(self, d):
        m.click_choice = lambda kind, tool=None: "tool"
        d.on_press(1.0)
        d.on_release(1.05)
        d.tick(3.0)

    def setUp(self):
        super().setUp()
        self._cc = m.click_choice
        with open(self.cfg, "w") as f:
            json.dump({}, f)

    def tearDown(self):
        m.click_choice = self._cc

    def test_arrow_keys_vertical_then_horizontal(self):
        d = self.armed("Arrow Keys")
        self.assertEqual(self.turn(d, 60), ["KEY:Down"])
        self.assertEqual(self.turn(d, -60), ["KEY:Up"])
        self.flip(d)
        self.assertTrue(d.arrow_horizontal)
        self.assertEqual(self.turn(d, 60), ["KEY:Right"])
        self.assertEqual(self.turn(d, -60), ["KEY:Left"])

    def test_tile_focus_uses_its_own_alt_actions_both_ways(self):
        def direction(events):
            self.assertEqual(len(events), 1, events)
            return events[0].split('direction = "')[1][0]

        d = self.armed("Tile Focus")
        self.assertEqual((direction(self.turn(d, 60)), direction(self.turn(d, -60))), ("r", "l"))
        self.flip(d)
        self.assertTrue(d.arrow_horizontal)
        self.assertEqual((direction(self.turn(d, 60)), direction(self.turn(d, -60))), ("d", "u"))

    def test_move_window_goes_across_workspaces_then_around_the_positions_of_this_one(self):
        d = self.armed("Move Window")
        self.assertEqual(self.turn(d, 60), ['HYPR:hl.dsp.window.move({ workspace = "+1" })'])
        self.assertEqual(self.turn(d, -60), ['HYPR:hl.dsp.window.move({ workspace = "-1" })'])
        self.flip(d)
        self.assertTrue(d.arrow_horizontal)
        self.assertEqual(self.turn(d, 60), ["HYPR:hl.dsp.window.swap({ next = true })"])
        self.assertEqual(self.turn(d, -60), ["HYPR:hl.dsp.window.swap({ prev = true })"])
        self.flip(d)  # and back
        self.assertEqual(self.turn(d, 60), ['HYPR:hl.dsp.window.move({ workspace = "+1" })'])

    def test_move_window_says_which_mode_a_click_chose(self):
        seen = []
        m.notify = lambda title, body="": seen.append((title, body))
        d = self.armed("Move Window")
        self.flip(d)
        self.flip(d)
        self.assertEqual([b for _, b in seen], ["around this workspace", "to another workspace"])

    def test_a_fresh_arm_always_starts_vertical(self):
        d = self.armed("Tile Focus")
        self.flip(d)
        d._arm(tool_index("Volume"), 5.0)
        d._arm(tool_index("Tile Focus"), 6.0)
        self.assertFalse(d.arrow_horizontal)


class RestartScript(unittest.TestCase):
    """bin/redial-restart: stop the old daemon, start a new one through Hyprland."""

    SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "redial-restart")

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.stubs = tempfile.mkdtemp()
        self.log = os.path.join(self.stubs, "calls.log")
        os.makedirs(os.path.join(self.home, ".local", "bin"))

    def stub(self, name, body=""):
        path = os.path.join(self.stubs, name)
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n{body}\n')
        os.chmod(path, 0o755)

    def run_script(self, daemon=True, running=True):
        if daemon:
            d = os.path.join(self.home, ".local", "bin", "redial-hypr")
            open(d, "w").write("#!/bin/sh\n")
            os.chmod(d, 0o755)
        self.stub("pgrep", "exit 0" if running else "exit 1")
        self.stub("pkill")
        self.stub("hyprctl")
        self.stub("sleep")
        env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin"}
        r = subprocess.run(["bash", self.SCRIPT], env=env, capture_output=True, text=True)
        calls = open(self.log).read().splitlines() if os.path.exists(self.log) else []
        return r, calls

    def test_stops_the_old_daemon_then_starts_through_hyprland(self):
        r, calls = self.run_script(running=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any(c.startswith("pkill -TERM") for c in calls), calls)
        start = [c for c in calls if c.startswith("hyprctl dispatch")]
        self.assertEqual(len(start), 1, calls)
        self.assertIn("uwsm-app -- " + self.home + "/.local/bin/redial-hypr", start[0])
        self.assertLess(
            next(i for i, c in enumerate(calls) if c.startswith("pkill")),
            next(i for i, c in enumerate(calls) if c.startswith("hyprctl")),
        )

    def test_when_nothing_is_running_it_just_starts_one(self):
        r, calls = self.run_script(running=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any(c.startswith("pkill") for c in calls), calls)
        self.assertTrue(any(c.startswith("hyprctl dispatch") for c in calls), calls)

    def test_without_an_installed_daemon_it_says_so_and_fails(self):
        r, calls = self.run_script(daemon=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("install.sh", r.stderr)
        self.assertEqual(calls, [])


def ev_bytes(etype, code, value):
    return struct.pack(m.EV_FORMAT, 0, 0, etype, code, value)


class StopLoop(Exception):
    """Raised from a stubbed sleep to end one of the daemon's endless reconnect loops."""


class Fixture:
    """Temporarily replace attributes on a module and put them back."""

    def __init__(self, test):
        self.test, self.saved = test, []

    def set(self, obj, name, value):
        self.saved.append((obj, name, getattr(obj, name)))
        setattr(obj, name, value)
        self.test.addCleanup(setattr, obj, name, self.saved[-1][2])


def pipe_with(*events):
    """A read-side file object holding the given events, then end-of-file."""
    r, w = os.pipe()
    for e in events:
        os.write(w, ev_bytes(*e))
    os.close(w)
    return os.fdopen(r, "rb", buffering=0)


class Pump(Base):
    """pump: kernel events in, Dial calls out; returns at end of file and closes the device."""

    class Rec:
        def __init__(self):
            self.calls = []

        def tick(self, now):
            return None

        def on_rotate(self, v, now):
            self.calls.append(("rot", v))

        def on_press(self, now):
            self.calls.append("down")

        def on_release(self, now):
            self.calls.append("up")

    def test_events_become_dial_calls_in_order(self):
        rec = self.Rec()
        fh = pipe_with(
            (m.EV_REL, m.REL_DIAL, 12),
            (m.EV_KEY, m.BTN_0, 1),
            (m.EV_KEY, m.BTN_0, 0),
            (m.EV_REL, m.REL_DIAL, -3),
        )
        m.pump(fh, rec)
        self.assertEqual(rec.calls, [("rot", 12), "down", "up", ("rot", -3)])
        self.assertTrue(fh.closed)

    def test_unrelated_events_are_ignored(self):
        rec = self.Rec()
        fh = pipe_with((m.EV_REL, 0x09, 5), (m.EV_KEY, 0x999, 1), (m.EV_KEY, m.BTN_0, 2))
        m.pump(fh, rec)
        self.assertEqual(rec.calls, [])

    def test_a_short_read_ends_the_pump(self):
        r, w = os.pipe()
        os.write(w, b"abc")
        os.close(w)
        fh = os.fdopen(r, "rb", buffering=0)
        m.pump(fh, self.Rec())
        self.assertTrue(fh.closed)


class DeviceDiscovery(Base):
    DEVICES = (
        "I: Bus=0003 Vendor=045e Product=091b Version=0108\n"
        'N: Name="Surface Dial System Multi Axis"\n'
        "H: Handlers=event7 \n\n"
        "I: Bus=0003 Vendor=045e Product=0001 Version=0001\n"
        'N: Name="Surface Pen Keyboard"\n'
        "H: Handlers=sysrq kbd event9 leds \n\n"
    )

    def patch_devices(self, text):
        import builtins
        from unittest import mock

        real = builtins.open

        def fake(path, *a, **k):
            if path == "/proc/bus/input/devices":
                if text is None:
                    raise OSError("gone")
                import io

                return io.StringIO(text)
            return real(path, *a, **k)

        p = mock.patch.object(builtins, "open", fake)
        p.start()
        self.addCleanup(p.stop)

    def test_finds_each_device_by_its_own_block(self):
        self.patch_devices(self.DEVICES)
        self.assertEqual(m.find_input("Surface Dial System Multi Axis"), "/dev/input/event7")
        self.assertEqual(m.find_input("Surface Pen Keyboard"), "/dev/input/event9")

    def test_unknown_name_and_unreadable_file_give_none(self):
        self.patch_devices(self.DEVICES)
        self.assertIsNone(m.find_input("Nope"))
        self.patch_devices(None)
        self.assertIsNone(m.find_input("Surface Dial System Multi Axis"))

    def test_a_block_with_no_event_handler_is_skipped(self):
        self.patch_devices('I: Bus=1\nN: Name="X"\nH: Handlers=sysrq kbd\n')
        self.assertIsNone(m.find_input("X"))

    def test_open_input_refuses_a_device_that_names_itself_differently(self):
        fx = Fixture(self)
        r, w = os.pipe()
        os.close(w)
        path = f"/proc/self/fd/{r}"
        fx.set(m, "find_input", lambda name: path)
        fx.set(m, "device_name", lambda fd: "Something Else")
        self.assertEqual(m.open_input("Surface Dial System Multi Axis"), (None, None))
        os.close(r)

    def test_open_input_returns_the_device_when_the_name_matches(self):
        fx = Fixture(self)
        r, w = os.pipe()
        os.close(w)
        fx.set(m, "find_input", lambda name: f"/proc/self/fd/{r}")
        fx.set(m, "device_name", lambda fd: "Surface Dial System Multi Axis")
        fh, path = m.open_input("Surface Dial System Multi Axis")
        self.assertIsNotNone(fh)
        fh.close()
        os.close(r)

    def test_open_input_with_no_device_or_an_unopenable_path(self):
        fx = Fixture(self)
        fx.set(m, "find_input", lambda name: None)
        self.assertEqual(m.open_input("x"), (None, None))
        fx.set(m, "find_input", lambda name: "/nonexistent/event0")
        self.assertEqual(m.open_input("x"), (None, "/nonexistent/event0"))  # listed, not openable

    def test_a_failure_to_open_is_logged_once_not_on_every_retry(self):
        fx = Fixture(self)
        logs = []
        fx.set(m, "log", logs.append)
        fx.set(m, "find_input", lambda name: "/nonexistent/event0")
        m._open_failed.clear()
        for _ in range(5):
            m.open_input("x")
        self.assertEqual(len(logs), 1)
        r, w = os.pipe()
        os.close(w)
        fx.set(m, "find_input", lambda name: f"/proc/self/fd/{r}")
        fx.set(m, "device_name", lambda fd: "x")
        m.open_input("x")[0].close()  # it opens: the next failure is news again
        fx.set(m, "find_input", lambda name: "/nonexistent/event0")
        m.open_input("x")
        self.assertEqual(len(logs), 2)
        os.close(r)

    def test_a_quiet_open_logs_nothing(self):
        fx = Fixture(self)
        logs = []
        fx.set(m, "log", logs.append)
        fx.set(m, "find_input", lambda name: "/nonexistent/event0")
        m._open_failed.clear()
        self.assertEqual(m.open_input("x", quiet=True), (None, "/nonexistent/event0"))
        self.assertEqual(logs, [])
        m.open_input("x")  # the retries ran out: now it is worth a line
        self.assertEqual(len(logs), 1)

    def test_device_name_of_a_non_device_is_empty(self):
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        self.addCleanup(os.close, w)
        self.assertEqual(m.device_name(r), "")


class PenWatchers(Base):
    """pen_button_watcher and eraser_watcher: read loops that survive a device going away."""

    def one_pass(self, fx, fh, watcher):
        calls = []

        def sleep(secs):
            calls.append(secs)
            raise StopLoop

        fx.set(m, "open_input", lambda name: (fh, "/dev/test"))
        fx.set(m.time, "sleep", sleep)
        with self.assertRaises(StopLoop):
            watcher()
        return calls

    def test_tail_button_press_fires_the_configured_action_once(self):
        fx = Fixture(self)
        fired = []
        fx.set(m, "pen_tail_fn", lambda slot: lambda mag: fired.append(slot))
        code, (label, slot) = next(iter(m.PEN_BUTTON.items()))
        fh = pipe_with((m.EV_KEY, code, 1), (m.EV_KEY, code, 0))
        self.one_pass(fx, fh, m.pen_button_watcher)
        self.assertEqual(fired, [slot])  # release does nothing

    def test_an_unbound_tail_slot_fires_nothing(self):
        fx = Fixture(self)
        fx.set(m, "pen_tail_fn", lambda slot: None)
        code = next(iter(m.PEN_BUTTON))
        fh = pipe_with((m.EV_KEY, code, 1))
        self.one_pass(fx, fh, m.pen_button_watcher)  # must not raise

    def test_unknown_keys_on_the_pen_keyboard_are_ignored(self):
        fx = Fixture(self)
        fired = []
        fx.set(m, "pen_tail_fn", lambda slot: lambda mag: fired.append(slot))
        fh = pipe_with((m.EV_KEY, 0x7FF, 1), (m.EV_REL, 0, 1))
        self.one_pass(fx, fh, m.pen_button_watcher)
        self.assertEqual(fired, [])

    def test_no_pen_device_waits_and_retries(self):
        fx = Fixture(self)
        calls = []

        def sleep(secs):
            calls.append(secs)
            raise StopLoop

        fx.set(m, "open_input", lambda name: (None, None))
        fx.set(m.time, "sleep", sleep)
        with self.assertRaises(StopLoop):
            m.pen_button_watcher()
        with self.assertRaises(StopLoop):
            m.eraser_watcher()
        self.assertEqual(calls, [5, 5])

    def test_eraser_watcher_feeds_events_to_the_state_machine(self):
        fx = Fixture(self)
        with open(self.cfg, "w") as f:
            json.dump({"pen": {"eraser_tap_min_ms": 0}}, f)  # the pipe delivers events at once
        fx.set(m, "focused_class", lambda: "firefox")
        fh = pipe_with(
            (m.EV_KEY, m.BTN_TOOL_RUBBER, 1),
            (m.EV_KEY, m.BTN_TOUCH, 1),
            (m.EV_KEY, m.BTN_TOUCH, 0),
        )
        self.one_pass(fx, fh, m.eraser_watcher)
        self.assertEqual(EVENTS, ["KEY:Escape"])


class VirtualPointerWrites(Base):
    """VirtualPointer emits the right uinput events (on a pipe instead of /dev/uinput)."""

    def setUp(self):
        super().setUp()
        self.r, w = os.pipe()
        self.vp = m.VirtualPointer()
        self.vp.fd = w
        self.addCleanup(os.close, self.r)

    def events(self):
        os.set_blocking(self.r, False)
        out = []
        while True:
            try:
                data = os.read(self.r, m.EV_SIZE)
            except BlockingIOError:
                break
            if not data:
                break
            _, _, t, c, v = struct.unpack(m.EV_FORMAT, data)
            out.append((t, c, v))
        return out

    def test_click_is_a_key_event_then_a_sync(self):
        self.vp.click(m.VirtualPointer.BTN_LEFT, True)
        self.assertEqual(
            self.events(),
            [(m.VirtualPointer.EV_KEY, m.VirtualPointer.BTN_LEFT, 1), (0, 0, 0)],
        )

    def test_scroll_emits_hi_res_and_a_coarse_notch_per_120_units(self):
        self.vp.scroll(60)
        first = self.events()
        self.assertEqual(first[0], (2, m.VirtualPointer.REL_WHEEL_HI_RES, 60))
        self.assertNotIn(m.VirtualPointer.REL_WHEEL, [c for _, c, _ in first])
        self.vp.scroll(70)  # residual now 130 -> one coarse notch, 10 left over
        second = self.events()
        self.assertIn((2, m.VirtualPointer.REL_WHEEL, 1), second)
        self.assertAlmostEqual(self.vp.residual, 10)

    def test_negative_scroll_counts_notches_backwards(self):
        self.vp.scroll(-250)
        self.assertIn((2, m.VirtualPointer.REL_WHEEL, -2), self.events())

    def test_a_failed_write_drops_the_device_so_it_is_recreated(self):
        os.close(self.vp.fd)
        self.vp.scroll(10)
        self.assertIsNone(self.vp.fd)
        self.vp.fd = os.open(os.devnull, os.O_RDONLY)  # restore something closable
        self.addCleanup(os.close, self.vp.fd)

    def test_no_uinput_means_scroll_is_disabled_quietly_and_warned_once(self):
        fx = Fixture(self)
        vp = m.VirtualPointer()

        def deny(*a, **k):
            raise PermissionError("no uinput")

        fx.set(m.os, "open", deny)
        vp.scroll(10)
        vp.scroll(10)
        self.assertTrue(vp.warned)
        self.assertIsNone(vp.fd)


class MainLoop(Base):
    """main: attach, pump, detach, retry; with the pen and status threads switched off."""

    def run_main(self, fx, opens, sleeps=None, waits=None, stop_after_sleeps=1, quiets=None):
        """Run main over scripted opens; sleeps and device-list waits are recorded, not slept."""
        seq = iter(opens)
        sleeps = [] if sleeps is None else sleeps
        waits = [] if waits is None else waits
        quiets = [] if quiets is None else quiets

        def open_input(name, quiet=False):
            quiets.append(quiet)
            nxt = next(seq)
            return nxt if nxt is not None else (None, None)

        def sleep(secs):
            sleeps.append(secs)
            if len(sleeps) >= stop_after_sleeps:
                raise StopLoop

        class Watch:
            def wait(self, timeout):
                waits.append(timeout)
                raise StopLoop

        class NoThread:
            def __init__(self, *a, **k):
                pass

            def start(self):
                pass

        with open(self.cfg, "w") as f:
            json.dump({"pen": {"enabled": False}}, f)
        fx.set(m, "open_input", open_input)
        fx.set(m, "DeviceWatch", Watch)
        fx.set(m.time, "sleep", sleep)
        fx.set(m.threading, "Thread", NoThread)
        with self.assertRaises(StopLoop):
            m.main()

    def test_waiting_for_the_device_sets_nothing_attached(self):
        fx = Fixture(self)
        m._status["attached"] = False
        self.run_main(fx, [None])
        self.assertFalse(m._status["attached"])  # never claimed to be attached

    def test_an_absent_dial_is_waited_for_on_the_device_list_not_a_timer(self):
        fx = Fixture(self)
        waits, sleeps = [], []
        self.run_main(fx, [None], waits=waits, sleeps=sleeps)
        self.assertEqual(waits, [m.WATCH_SAFETY_S])
        self.assertEqual(sleeps, [])  # no polling sleep

    def test_a_listed_but_unopenable_dial_is_retried_quickly_then_waited_for(self):
        fx = Fixture(self)
        opens = [(None, "/dev/event7")] * (m.OPEN_RETRY_MAX + 1)
        sleeps, waits, quiets = [], [], []
        self.run_main(fx, opens, waits=waits, sleeps=sleeps, stop_after_sleeps=99, quiets=quiets)
        self.assertEqual(sleeps, [m.OPEN_RETRY_S] * m.OPEN_RETRY_MAX)
        self.assertEqual(waits, [m.WATCH_SAFETY_S])
        # the quick retries stay out of the log; only the open that outlasts them may log
        self.assertEqual(quiets, [True] * m.OPEN_RETRY_MAX + [False])

    def test_after_a_detach_it_pauses_briefly_before_looking_again(self):
        fx = Fixture(self)
        sleeps = []
        self.run_main(fx, [(pipe_with(), "/dev/event7")], sleeps=sleeps)
        self.assertEqual(sleeps, [m.REATTACH_PAUSE_S])

    def test_the_log_says_how_long_the_dial_was_away(self):
        fx = Fixture(self)
        logs = []
        fx.set(m, "log", logs.append)
        self.run_main(fx, [(pipe_with(), "/dev/event7")])
        self.assertTrue(any(line.startswith("attached to /dev/event7 (away ") for line in logs))

    def test_attach_pump_detach_marks_the_status_both_ways(self):
        fx = Fixture(self)
        seen = []
        real_pump = m.pump

        def pump(fh, dial):
            seen.append(m._status["attached"])
            real_pump(fh, dial)

        fx.set(m, "pump", pump)
        fh = pipe_with()
        m._status["attached"] = False
        self.run_main(fx, [(fh, "/dev/event7")])
        self.assertEqual(seen, [True])  # attached while pumping
        self.assertFalse(m._status["attached"])  # and cleared after

    def test_a_drop_mid_use_says_asleep_but_not_after_our_own_stall_reconnect(self):
        def notes(kicked):
            fx = Fixture(self)
            said = []
            fx.set(m, "cant_note", lambda reason, *a: said.append(reason))

            def pump(fh, dial):  # in use a moment ago, then the link drops
                dial.last_action = m.time.monotonic()
                if kicked:
                    dial.stall_kick_at = m.time.monotonic()
                raise OSError(19, "No such device")

            fx.set(m, "pump", pump)
            self.run_main(fx, [(pipe_with(), "/dev/event7")])
            return said

        self.assertEqual(notes(kicked=False), ["asleep"])
        self.assertEqual(notes(kicked=True), [])


class DeviceWatchTests(Base):
    def test_it_returns_as_soon_as_the_device_list_changes(self):
        import select as sel

        woke = []

        class FakePoll:
            def register(self, fd, ev):
                pass

            def poll(self, ms):
                woke.append(ms)
                return []

        fx = Fixture(self)
        fx.set(m.select, "poll", lambda: FakePoll())
        w = m.DeviceWatch()
        w.wait(2.0)
        self.assertEqual(woke, [0, 2000])  # the initial drain, then the real wait
        self.assertTrue(hasattr(sel, "poll"))

    def test_it_falls_back_to_a_plain_sleep_where_the_file_cannot_be_polled(self):
        fx = Fixture(self)
        slept = []
        fx.set(m.time, "sleep", slept.append)
        w = m.DeviceWatch("/nonexistent/devices")
        w.wait(1.5)
        self.assertEqual(slept, [1.5])

    def test_on_this_machine_a_change_is_not_lost_and_quiet_means_quiet(self):
        w = m.DeviceWatch()
        if w._poll is None:
            self.skipTest("no pollable /proc/bus/input/devices here")
        t = time.monotonic()
        w.wait(0.05)
        self.assertGreaterEqual(time.monotonic() - t, 0.04)  # nothing changed, so it waited


class StatusLoop(Base):
    def test_writes_on_first_pass_and_not_again_while_unchanged(self):
        fx = Fixture(self)
        writes, sleeps = [], []
        fx.set(m, "dial_bluetooth", lambda: (True, 80))
        fx.set(m, "write_status", lambda doc: writes.append(doc))

        def sleep(secs):
            sleeps.append(secs)
            if len(sleeps) >= 3:
                raise StopLoop

        fx.set(m.time, "sleep", sleep)
        with self.assertRaises(StopLoop):
            m.status_loop(interval=0)
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["battery"], 80)

    def test_a_change_is_written_straight_away(self):
        fx = Fixture(self)
        writes, answers = [], iter([(True, 80), (True, 79), (True, 79)])
        fx.set(m, "dial_bluetooth", lambda: next(answers))
        fx.set(m, "write_status", lambda doc: writes.append(doc["battery"]))
        n = []

        def sleep(secs):
            n.append(1)
            if len(n) >= 3:
                raise StopLoop

        fx.set(m.time, "sleep", sleep)
        with self.assertRaises(StopLoop):
            m.status_loop(interval=0)
        self.assertEqual(writes, [80, 79])

    def test_keep_awake_pokes_once_a_minute_only_when_on_and_attached(self):
        fx = Fixture(self)
        fx.set(m, "dial_bluetooth", lambda: (True, 80))
        fx.set(m, "write_status", lambda doc: None)
        fx.set(m, "kick_dial", lambda *a: None)  # never touch the real Bluetooth link

        def pokes(cfg, attached, last_use=0.0, locked=False, until=60, docs=None):
            now, sent = [0.0], []
            fx.set(m.time, "monotonic", lambda: now[0])
            fx.set(m, "HAPTIC", types.SimpleNamespace(keep_awake=lambda: sent.append(now[0])))
            fx.set(m, "live_config", lambda: cfg)
            fx.set(m, "screen_locked", lambda: locked)
            fx.set(m, "_status", {"attached": attached, "last_use": last_use})
            if docs is not None:
                fx.set(m, "write_status", docs.append)

            def sleep(secs):  # each pass is 30 s; stop after t=until
                now[0] += 30
                if now[0] > until:
                    raise StopLoop

            fx.set(m.time, "sleep", sleep)
            with self.assertRaises(StopLoop):
                m.status_loop(interval=0)
            return sent

        self.assertEqual(pokes({}, True), [])  # off by default
        self.assertEqual(pokes({"keep_awake": True}, False), [])  # asleep: nothing to keep up
        self.assertEqual(pokes({"keep_awake": True}, True), [0.0, 60.0])
        # Locked screen: nobody is at the desk, let the dial sleep.
        self.assertEqual(pokes({"keep_awake": True}, True, locked=True), [])
        # Idle window: default 30 min after the last touch, then the dial may sleep.
        self.assertEqual(pokes({"keep_awake": True}, True, last_use=-1800.0, until=0), [0.0])
        self.assertEqual(pokes({"keep_awake": True}, True, last_use=-1801.0, until=0), [])
        cfg = {"keep_awake": True, "keep_awake_minutes": 5}
        self.assertEqual(pokes(cfg, True, last_use=-301.0, until=0), [])
        self.assertEqual(pokes(cfg, True, last_use=-299.0, until=0), [0.0])
        # status.json says whether pokes are actually being sent (battery study column).
        docs = []
        pokes({"keep_awake": True}, True, docs=docs, until=0)
        self.assertTrue(docs[-1]["keeping_awake"])
        docs = []
        pokes({"keep_awake": True}, True, locked=True, docs=docs, until=0)
        self.assertFalse(docs[-1]["keeping_awake"])

    def test_screen_locked_sees_a_locker_process(self):
        proc = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, proc)
        for pid, comm in (("1", "systemd"), ("42", "hyprlock"), ("self", "x")):
            os.makedirs(os.path.join(proc, pid))
            with open(os.path.join(proc, pid, "comm"), "w") as f:
                f.write(comm + "\n")
        os.makedirs(os.path.join(proc, "77"))  # a process that exited mid-scan: no comm
        self.assertTrue(m.screen_locked(proc))
        os.remove(os.path.join(proc, "42", "comm"))
        self.assertFalse(m.screen_locked(proc))

    def test_haptics_worker_turns_the_sentinel_into_a_silent_read(self):
        h = m.Haptics.__new__(m.Haptics)  # no worker thread
        calls, items = [], [None, (3, 120)]
        h.q = types.SimpleNamespace(
            put_nowait=items.append,
            get=lambda: items.pop(0) if items else (_ for _ in ()).throw(StopLoop),
        )
        items.clear()
        h._open = lambda: True
        h._fire = lambda *p: calls.append(p)
        h._poke = lambda: calls.append("poke")
        h.keep_awake()
        items.append((3, 120))
        with self.assertRaises(StopLoop):
            h._worker()
        self.assertEqual(calls, ["poke", (3, 120)])

    def test_keep_awake_poke_is_a_none_waveform_write_logged_once(self):
        # A read did not reset the dial's sleep timer (2026-11-06); a NONE-waveform write did.
        fx = Fixture(self)
        logs, wrote = [], []
        fx.set(m, "log", logs.append)
        h = m.Haptics.__new__(m.Haptics)
        h.poke_ok, h.last_write = False, None
        h.fd = types.SimpleNamespace(write=wrote.append)
        h._poke()
        h._poke()
        self.assertEqual(wrote, [bytes([0x01, 0, m.HAPTIC_NONE, 0, 0])] * 2)
        self.assertEqual(m.HAPTIC_NONE, 1)  # ordinal 1 is NONE; 3 would click the motor
        self.assertEqual(
            [x for x in logs if "keep-awake" in x], ["keep-awake: first silent haptic sent"]
        )
        self.assertIsNotNone(h.last_write)


class RotationStall(Base):
    """A menu held STALL_HOLD_S with no turn at all reconnects the dial (firmware stall)."""

    def setUp(self):
        super().setUp()
        self.kicks = []
        fx = Fixture(self)
        fx.set(m, "kick_dial_async", self.kicks.append)
        fx.set(m, "log", lambda msg: None)

    def hold(self, d, start, secs, turn_at=None):
        d.on_press(start)
        d.tick(start + 0.5)  # the menu opens
        self.assertTrue(d.menu)
        if turn_at is not None:
            d.on_rotate(1, start + turn_at)  # even one count, under the dead zone, is a turn
        d.tick(start + secs)  # still held
        d.on_release(start + secs + 0.05)

    def test_long_hold_without_turning_reconnects_and_keeps_the_tool(self):
        d = m.Dial()
        d.tool = 1
        self.hold(d, 0.0, m.STALL_HOLD_S + 0.1)
        self.assertEqual(self.kicks, ["stall self-heal"])
        self.assertFalse(d.menu)
        self.assertEqual(d.tool, 1)

    def test_it_fires_at_the_mark_while_still_held(self):
        self.assertEqual(m.STALL_HOLD_S, 3.0)
        d = m.Dial()
        d.on_press(0.0)
        d.tick(0.5)
        self.assertAlmostEqual(d.tick(1.0), m.STALL_HOLD_S - 1.0)  # the loop wakes for it
        d.tick(m.STALL_HOLD_S - 0.01)
        self.assertEqual(self.kicks, [])
        d.tick(m.STALL_HOLD_S)
        self.assertEqual(self.kicks, ["stall self-heal"])
        d.on_release(m.STALL_HOLD_S + 1)  # letting go afterwards does nothing more
        self.assertFalse(d.menu)
        self.assertEqual(d.tool, m.IDLE_TOOL)

    def test_any_turn_during_the_hold_is_not_a_stall(self):
        d = m.Dial()
        self.hold(d, 0.0, m.STALL_HOLD_S + 1, turn_at=1.0)
        self.assertEqual(self.kicks, [])

    def test_a_turn_before_the_press_does_not_count(self):
        d = m.Dial()
        d.on_rotate(1, 0.0)
        self.hold(d, 5.0, m.STALL_HOLD_S + 0.1)
        self.assertEqual(self.kicks, ["stall self-heal"])

    def test_a_short_hold_is_the_normal_menu(self):
        d = m.Dial()
        self.hold(d, 0.0, m.STALL_HOLD_S - 0.5)
        self.assertEqual(self.kicks, [])

    def test_repeated_stall_holds_kick_at_most_once_per_gap(self):
        d = m.Dial()
        self.hold(d, 0.0, m.STALL_HOLD_S + 0.1)
        self.hold(d, 10.0, m.STALL_HOLD_S + 0.1)
        self.assertEqual(len(self.kicks), 1)
        self.assertFalse(d.menu, "the menu still closes when the kick is held back")
        self.hold(d, m.STALL_KICK_GAP_S + 5, m.STALL_HOLD_S + 0.1)
        self.assertEqual(len(self.kicks), 2)


class StuckWatchTest(Base):
    def test_kicks_only_after_stuck_window_then_backs_off_and_resets_on_attach(self):
        w = m.StuckWatch()
        self.assertFalse(w.feed(True, False, 0.0))
        self.assertFalse(w.feed(True, False, m.STUCK_S - 0.1))
        self.assertTrue(w.feed(True, False, m.STUCK_S))
        self.assertFalse(w.feed(True, False, m.STUCK_S + 1))  # backing off
        self.assertTrue(w.feed(True, False, m.STUCK_S + m.STUCK_BACKOFF_S[0]))
        self.assertFalse(w.feed(True, True, 100.0))  # attached: reset
        self.assertFalse(w.feed(False, False, 200.0))  # asleep is not stuck
        self.assertFalse(w.feed(None, False, 300.0))  # unknown is not stuck
        self.assertFalse(w.feed(True, False, 400.0))  # fresh window
        self.assertTrue(w.feed(True, False, 400.0 + m.STUCK_S))

    def test_reconnect_click_drops_the_link_off_the_read_loop(self):
        fx = Fixture(self)
        calls, threads = [], []

        class Now:  # runs the thread's work at once, and records that a thread was asked for
            def __init__(self, target, args, daemon):
                threads.append(daemon)
                self.run = lambda: target(*args)

            def start(self):
                self.run()

        fx.set(m.threading, "Thread", Now)
        fx.set(m, "dial_address", lambda: "BC:83:85:01:99:1A")
        fx.set(m, "log", lambda msg: calls.append(("log", msg)))
        fx.set(m.subprocess, "run", lambda cmd, **kw: calls.append(("run", cmd)))
        spec = dict((a[0], a[3]) for a in m.CLICK_ACTIONS)["reconnect_dial"]
        m.make_action(spec)(1)
        self.assertEqual(threads, [True])
        self.assertIn(("run", ["bluetoothctl", "disconnect", "BC:83:85:01:99:1A"]), calls)
        self.assertTrue(any(c[0] == "log" and "reconnect asked for" in c[1] for c in calls))

    def test_first_press_after_attach_logs_how_many_turns_arrived(self):
        fx = Fixture(self)
        logs = []
        fx.set(m, "log", logs.append)
        d = m.Dial()
        d.rot_events = 17901
        d.rot_at_attach = 17871
        d.on_press(0.0)
        d.on_release(0.05)
        d.on_press(1.0)
        d.on_release(1.05)
        self.assertEqual(
            [x for x in logs if x.startswith("first press")],
            ["first press after attach: 30 rotation events"],
        )


class NarrowedErrors(Base):
    """The failures that used to be swallowed by a bare `except Exception` still degrade quietly,
    and the ones that are bugs are no longer hidden."""

    def test_focus_queries_degrade_on_every_expected_failure(self):
        fx = Fixture(self)
        for raised in (OSError("sock"), ValueError("json"), subprocess.TimeoutExpired("x", 1)):

            def boom(what, _e=raised):
                raise _e

            fx.set(m, "hypr_json", boom)
            self.assertEqual(m.focused_class(), "")
            self.assertFalse(m.focused_is_terminal())

    def test_focus_queries_cope_with_a_reply_that_is_not_an_object(self):
        fx = Fixture(self)
        fx.set(m, "hypr_json", lambda what: [1, 2, 3])
        self.assertEqual(m.focused_class(), "")
        self.assertFalse(m.focused_is_terminal())

    def test_a_real_bug_in_the_query_is_not_swallowed(self):
        fx = Fixture(self)

        def bug(what):
            raise KeyError("a genuine programming error")

        fx.set(m, "hypr_json", bug)
        with self.assertRaises(KeyError):
            m.focused_class()

    def test_numbers_that_cannot_be_cast_fall_back(self):
        for bad in (float("inf"), "x", None, [1], {"a": 1}):
            self.assertEqual(m._spec_number({"n": bad}, "n", 7, int), 7, bad)
        self.assertEqual(m._spec_number({"n": "5"}, "n", 7, int), 5)

    def test_tool_with_unusable_detent_or_gain_uses_the_defaults(self):
        tools = m.build_tools(
            [{"name": "T", "detent": "fast", "gain": [], "cw": None, "ccw": None, "click": None}]
        )
        self.assertEqual(tools[0]["detent"], 60)
        self.assertEqual(tools[0]["gain"], m.SCROLL_GAIN)

    def test_missing_wpctl_and_brightnessctl_give_none(self):
        fx = Fixture(self)

        def gone(*a, **k):
            raise FileNotFoundError("no such tool")

        fx.set(m.subprocess, "run", gone)
        self.assertIsNone(m.read_brightness("intel_backlight"))
        self.assertIsNone(m.MenuUI._volume())


class PointerTools(Base):
    """Pointer, H Scroll, the mouse and launcher click actions, and user launchers."""

    def setUp(self):
        super().setUp()
        self.ptr = FakePointer()
        m.POINTER = self.ptr
        m.TOOLS = m.build_tools(m.TOOL_LIBRARY)
        with open(self.cfg, "w") as f:
            json.dump({}, f)

    def armed(self, name):
        d = m.Dial()
        d._arm(tool_index(name), 0.0)
        return d

    # --- Scroll sideways (H Scroll until 2026-10-23): a click flips it
    def sideways(self):
        d = self.armed("Scroll")
        d.on_press(0.5)
        d.on_release(0.55)
        d.tick(2.0)
        self.assertTrue(d.arrow_horizontal)
        return d

    def test_a_click_on_scroll_sends_the_horizontal_wheel_not_vertical(self):
        d = self.sideways()
        d.on_rotate(40, 3.0)
        self.assertEqual(self.ptr.scrolls, [])
        self.assertEqual(len(self.ptr.h_scrolls), 1)

    def test_sideways_scroll_clockwise_is_right_and_counter_is_left(self):
        d = self.sideways()
        d.on_rotate(40, 3.0)
        d.on_rotate(-40, 4.0)
        right, left = self.ptr.h_scrolls
        self.assertGreater(right, 0)
        self.assertLess(left, 0)

    def test_plain_scroll_is_still_vertical_and_unchanged(self):
        d = self.armed("Scroll")
        d.on_rotate(40, 0.0)
        self.assertEqual(len(self.ptr.scrolls), 1)
        self.assertEqual(self.ptr.h_scrolls, [])
        self.assertLess(self.ptr.scrolls[0], 0)  # cw scrolls down, as before

    def test_new_tools_are_not_in_the_default_ring(self):
        names = [t["name"] for t in m.build_tools(m.DEFAULT_TOOLS)]
        self.assertNotIn("Pointer", names)

    # --- Pointer
    def test_pointer_moves_sideways_until_flipped_then_up_and_down(self):
        d = self.armed("Pointer")
        d.on_rotate(40, 0.0)
        dx, dy = self.ptr.moves[-1]
        self.assertGreater(dx, 0)
        self.assertEqual(dy, 0)
        d.arrow_horizontal = True  # what a click does
        d.on_rotate(40, 5.0)
        dx, dy = self.ptr.moves[-1]
        self.assertEqual(dx, 0)
        self.assertGreater(dy, 0)

    def test_pointer_counter_clockwise_goes_the_other_way(self):
        d = self.armed("Pointer")
        d.on_rotate(-40, 0.0)
        self.assertLess(self.ptr.moves[-1][0], 0)

    def test_pointer_speeds_up_when_the_dial_spins_fast(self):
        slow = self.armed("Pointer")
        slow.on_rotate(5, 0.0)
        fast = self.armed("Pointer")
        for i in range(30):
            fast.on_rotate(40, 0.001 * i)
        self.assertGreater(self.ptr.moves[-1][0] / 40, self.ptr.moves[0][0] / 5)

    def test_pointer_acceleration_is_capped(self):
        d = self.armed("Pointer")
        for i in range(400):
            d.on_rotate(200, 0.0005 * i)
        per_count = self.ptr.moves[-1][0] / 200
        self.assertLessEqual(per_count, m.POINTER_GAIN * (1 + m.POINTER_ACCEL_MAX) + 1e-9)

    def test_pointer_respects_sensitivity(self):
        d = self.armed("Pointer")
        d.on_rotate(10, 0.0)
        base = self.ptr.moves[-1][0]
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"sensitivity": 2.0}, f)
        d2 = self.armed("Pointer")
        d2.on_rotate(10, 9.0)
        self.assertAlmostEqual(self.ptr.moves[-1][0], base * 2, places=6)

    def test_pointer_counts_as_activity_so_it_returns_to_volume_later(self):
        d = self.armed("Pointer")
        d.on_rotate(10, 3.0)
        self.assertEqual(d.last_action, 3.0)

    def test_pointer_clicks_left_flips_on_a_double_and_right_clicks_on_a_triple(self):
        with open(self.cfg, "w") as f:
            json.dump({"clicks": {"double": "dictation", "triple": "enter"}}, f)
        pointer = m.TOOLS[tool_index("Pointer")]
        self.assertEqual(
            [m.click_choice(k, pointer) for k in ("single", "double", "triple")],
            ["mouse_left", "tool", "mouse_right"],
        )
        d = self.armed("Pointer")
        for t in (1.0, 1.1):  # a double click: the tool's own click, the axis flip
            d.on_press(t)
            d.on_release(t + 0.05)
        d.tick(5.0)
        self.assertTrue(d.arrow_horizontal)

    def test_your_clicks_for_one_tool_beat_its_own_then_fall_back_to_every_tool(self):
        with open(self.cfg, "w") as f:
            json.dump(
                {
                    "clicks": {"double": "dictation", "triple": "enter"},
                    "tool_clicks": {
                        "Pointer": {"triple": "copy", "double": "bogus"},
                        "Scroll": {"double": "tool"},
                    },
                },
                f,
            )
        pointer, scroll, zoom = (m.TOOLS[tool_index(n)] for n in ("Pointer", "Scroll", "Zoom"))
        self.assertEqual(m.click_choice("triple", pointer), "copy")  # yours
        self.assertEqual(
            m.click_choice("double", pointer), "tool"
        )  # a bad value keeps the tool's own
        self.assertEqual(m.click_choice("double", scroll), "tool")  # "tool" is allowed per tool
        self.assertEqual(m.click_choice("triple", scroll), "enter")  # every tool's
        self.assertEqual(m.click_choice("double", zoom), "dictation")
        self.assertEqual(m.click_choice("double"), "dictation")  # no tool: every tool's

    # --- virtual pointer output
    def test_virtual_pointer_move_emits_x_and_y_and_keeps_the_fraction(self):
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        vp = m.VirtualPointer()
        vp.fd = w
        vp.move(0.6, 0)
        os.set_blocking(r, False)
        with self.assertRaises(BlockingIOError):
            os.read(r, 1)  # 0.6 px is not yet a whole pixel: nothing sent
        vp.move(0.6, -2.0)  # 1.2 -> 1 px right, 2 px up, 0.2 carried
        got = []
        while True:
            try:
                got.append(struct.unpack(m.EV_FORMAT, os.read(r, m.EV_SIZE))[2:])
            except BlockingIOError:
                break
        self.assertIn((2, m.VirtualPointer.REL_X, 1), got)
        self.assertIn((2, m.VirtualPointer.REL_Y, -2), got)
        self.assertAlmostEqual(vp.move_x, 0.2)

    def test_virtual_pointer_horizontal_wheel_uses_its_own_codes_and_residual(self):
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        vp = m.VirtualPointer()
        vp.fd = w
        vp.scroll(130, horizontal=True)
        os.set_blocking(r, False)
        got = []
        while True:
            try:
                got.append(struct.unpack(m.EV_FORMAT, os.read(r, m.EV_SIZE))[2:])
            except BlockingIOError:
                break
        self.assertIn((2, m.VirtualPointer.REL_HWHEEL_HI_RES, 130), got)
        self.assertIn((2, m.VirtualPointer.REL_HWHEEL, 1), got)
        self.assertAlmostEqual(vp.residual_h, 10)
        self.assertEqual(vp.residual, 0.0)

    # --- click actions
    def test_mouse_click_actions_press_and_release_that_button(self):
        for name, btn in (
            ("mouse_left", m.VirtualPointer.BTN_LEFT),
            ("mouse_right", m.VirtualPointer.BTN_RIGHT),
            ("mouse_middle", m.VirtualPointer.BTN_MIDDLE),
        ):
            self.ptr.clicks.clear()
            m.click_fn(name)(1)
            self.assertEqual(self.ptr.clicks, [(btn, True), (btn, False)], name)

    def test_launch_actions_run_the_omarchy_launchers(self):
        for name, first in (
            ("terminal", "omarchy-launch-terminal"),
            ("browser", "omarchy-launch-browser"),
            ("files", "omarchy-launch-nautilus"),
        ):
            EVENTS.clear()
            m.click_fn(name)(1)
            self.assertTrue(EVENTS and EVENTS[0].startswith("EXEC:" + first), (name, EVENTS))

    def test_the_shipped_example_config_is_valid_json_and_launchers_are_empty(self):
        path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..",
            "plugin",
            "redial",
            "config.example.json",
        )
        with open(path) as f:
            doc = json.load(f)
        self.assertEqual(doc["launchers"], [])
        self.assertEqual(doc["assistant"]["cmd"], [])

    def test_the_assistant_action_is_vendor_neutral(self):
        text = " ".join(a[0] + a[1] + a[2] for a in m.CLICK_ACTIONS).lower()
        self.assertIn("assistant", text)
        for brand in ("claude", "openai", "chatgpt", "gemini", "ollama"):
            self.assertNotIn(brand, text)

    def test_assistant_runs_the_configured_command(self):
        for cmd in (["omarchy-launch-or-focus-tui", "ollama", "run", "llama3"], ["firefox", "x"]):
            time.sleep(0.005)
            with open(self.cfg, "w") as f:
                json.dump({"assistant": {"cmd": cmd, "label": "mine"}}, f)
            EVENTS.clear()
            m.click_fn("assistant")(1)
            self.assertEqual(EVENTS, ["EXEC:" + " ".join(cmd[:2])])

    def test_assistant_without_a_command_says_how_to_set_one_and_runs_nothing(self):
        notes = []
        m.notify = lambda *a, **k: notes.append(a)
        for conf in (
            {},
            {"assistant": "claude"},
            {"assistant": {"cmd": []}},
            {"assistant": {"cmd": "x"}},
        ):
            time.sleep(0.005)
            with open(self.cfg, "w") as f:
                json.dump(conf, f)
            EVENTS.clear()
            notes.clear()
            m.click_fn("assistant")(1)
            self.assertEqual(EVENTS, [], conf)
            self.assertEqual(len(notes), 1, conf)
            self.assertIn("assistant", notes[0][1])

    def test_assistant_command_changes_apply_without_a_restart(self):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"assistant": {"cmd": ["one"]}}, f)
        fn = m.click_fn("assistant")
        EVENTS.clear()
        fn(1)
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump({"assistant": {"cmd": ["two"]}}, f)
        fn(1)
        self.assertEqual(EVENTS, ["EXEC:one", "EXEC:two"])

    def test_the_pen_barrel_list_has_no_duplicate_mouse_buttons(self):
        names = [a[0] for a in m.PEN_BARREL_ACTIONS]
        self.assertEqual(len(names), len(set(names)))
        self.assertFalse(any(n.startswith("mouse_") for n in names))

    def test_every_click_action_name_is_unique_and_none_is_last(self):
        names = [a[0] for a in m.CLICK_ACTIONS]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(names[-1], "none")

    # --- user launchers
    def test_a_launcher_becomes_a_click_action(self):
        out = m.custom_launcher_actions(
            {"launchers": [{"name": "Notes App", "label": "Open notes", "cmd": ["obsidian"]}]}
        )
        self.assertEqual(len(out), 1)
        key, label, desc, spec = out[0]
        self.assertEqual(key, "launch_notes_app")
        self.assertEqual(label, "Open notes")
        self.assertEqual(spec, {"do": "exec", "cmd": ["obsidian"]})

    def test_bad_launchers_are_skipped_and_good_ones_kept(self):
        out = m.custom_launcher_actions(
            {
                "launchers": [
                    {"name": "a", "cmd": "obsidian"},  # string, not a list
                    {"name": "b", "cmd": []},
                    {"name": "", "cmd": ["x"]},
                    "nonsense",
                    {"name": "ok", "cmd": ["true"]},
                    {"name": "ok", "cmd": ["false"]},  # duplicate name
                    {"name": "terminal", "cmd": ["x"]},  # would not clash: prefixed launch_
                ]
            }
        )
        self.assertEqual([a[0] for a in out], ["launch_ok", "launch_terminal"])

    def test_launchers_that_are_not_a_list_are_ignored(self):
        self.assertEqual(m.custom_launcher_actions({"launchers": "obsidian"}), [])
        self.assertEqual(m.custom_launcher_actions({}), [])

    def test_the_number_of_launchers_is_capped(self):
        many = [{"name": f"n{i}", "cmd": ["x"]} for i in range(m.MAX_LAUNCHERS + 5)]
        self.assertEqual(len(m.custom_launcher_actions({"launchers": many})), m.MAX_LAUNCHERS)


class MenuEntryRemoval(unittest.TestCase):
    """add-menu-entry.py --remove is the exact inverse of adding."""

    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader(
            "addmenu2", os.path.join(HERE, "..", "scripts", "add-menu-entry.py")
        )
        cls.am = importlib.util.module_from_spec(
            importlib.util.spec_from_loader("addmenu2", loader)
        )
        loader.exec_module(cls.am)

    def test_add_then_remove_gives_back_the_original_text(self):
        for text in (
            "{\n  // Extend the menu.\n}\n",
            "{}",
            '{\n  "a": {"label":"A"},\n}\n',
            '{\n  "a": {"label":"A"} // keep me\n}\n',
        ):
            added = self.am.add_row(text)
            back = self.am.remove_row(added)
            self.assertEqual(self.am.parse_jsonc(back).keys() - {"a"}, set(), text)
            self.assertNotIn(self.am.ID, self.am.parse_jsonc(back))
            self.assertIn("keep me" if "keep me" in text else "", back)

    def test_remove_refuses_an_edited_row(self):
        added = self.am.add_row("{\n}\n").replace("re:dial", "Mine")
        self.assertIsNone(self.am.remove_row(added))

    def test_remove_on_a_file_without_the_row_is_a_noop(self):
        self.assertIsNone(self.am.remove_row("{\n}\n"))

    def test_remove_through_the_command_line_entry_point(self):
        path = os.path.join(tempfile.mkdtemp(), "m.jsonc")
        with open(path, "w") as f:
            f.write('{\n  "a": {"label":"A"}\n}\n')
        self.assertEqual(self.am.main(["x", path]), 0)
        self.assertEqual(self.am.main(["x", "--remove", path]), 0)
        with open(path) as f:
            doc = self.am.parse_jsonc(f.read())
        self.assertEqual(list(doc), ["a"])
        self.assertEqual(self.am.main(["x", "--remove", path]), 0)  # again: nothing to do


def _load_add_menu_entry():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "scripts", "add-menu-entry.py")
    spec = importlib.util.spec_from_file_location("add_menu_entry", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class RiseWidgetUpgrade(unittest.TestCase):
    """An install under the old name is brought up to date, not left calling a removed command."""

    TOOL = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "bin", "redial-rise-widget"
    )
    TILE = (
        'WidgetStateTile { gid: "G19"; width: root.evenW((wwCol.width - 4) / 2); '
        'label: "Surface Dial"; shown: root.modDial }\n'
    )

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.root = os.path.join(self.home, "V2")
        files = {
            "BarSlot.qml": "compDial\n",
            "Theme.qml": "modDial\n",
            "panels/ControlPanel.qml": self.TILE,
            "modules/DialWidget.qml": "command: $HOME/.local/bin/surface-dial-bar\n",
        }
        for rel, text in files.items():
            path = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)

    def install(self):
        return subprocess.run(
            [sys.executable, self.TOOL, "--install", "--no-restart", "--root", self.root],
            env={"HOME": self.home, "PATH": os.environ["PATH"]},
            capture_output=True,
            text=True,
        )

    def read(self, rel):
        with open(os.path.join(self.root, rel)) as f:
            return f.read()

    def test_an_old_widget_is_renamed_and_points_at_the_new_command(self):
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("surface-dial", self.read("modules/DialWidget.qml"))
        self.assertIn("redial-bar", self.read("modules/DialWidget.qml"))
        self.assertIn('label: "re:dial"', self.read("panels/ControlPanel.qml"))

    def test_a_second_run_changes_nothing(self):
        self.install()
        again = self.install()
        self.assertIn("already installed", again.stdout)


class UninstallScript(unittest.TestCase):
    """uninstall.sh undoes install.sh in a scratch HOME, keeping settings and your own lines."""

    ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    AUTOSTART = 'o.launch_on_start("waybar")\n-- my own line\n'
    HYPRLAND = 'require("hypr.bindings")\n\n-- my own rule\no.window("qemu", { workspace = "5" })\n'
    MENU = "{\n  // Extend the menu.\n}\n"

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.stubs = tempfile.mkdtemp()
        self.log = os.path.join(self.stubs, "calls.log")
        for name, body in (
            ("sudo", "exit 0"),
            ("pkill", ""),
            ("pgrep", "exit 1"),
            ("sleep", ""),
            ("hyprctl", ""),
            ("omarchy-restart-shell", ""),
            ("omarchy-pkg-add", ""),
            ("omarchy-shell", 'case "$*" in *ping*) echo ok;; esac'),
        ):
            path = os.path.join(self.stubs, name)
            with open(path, "w") as f:
                f.write(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n{body}\n')
            os.chmod(path, 0o755)
        self.put(".config/hypr/autostart.lua", self.AUTOSTART)
        self.put(".config/hypr/hyprland.lua", self.HYPRLAND)
        self.put(".config/omarchy/extensions/omarchy-menu.jsonc", self.MENU)
        self.env = {
            "HOME": self.home,
            "PATH": self.stubs + ":/usr/bin:/bin",
            "USER": "tester",
            "DIAL_WAKE_RULE": os.path.join(self.home, "no-wake-rule"),  # never this machine's
        }

    def put(self, rel, text):
        path = os.path.join(self.home, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def read(self, rel):
        with open(os.path.join(self.home, rel)) as f:
            return f.read()

    def exists(self, rel):
        return os.path.exists(os.path.join(self.home, rel))

    def sh(self, script, *args):
        return subprocess.run(
            ["bash", os.path.join(self.ROOT, script), *args],
            env=self.env,
            capture_output=True,
            text=True,
            input="",
        )

    def install(self):
        r = self.sh("install.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def calls(self):
        return open(self.log).read().splitlines() if os.path.exists(self.log) else []

    def test_install_then_uninstall_leaves_your_files_as_they_were(self):
        self.install()
        self.assertTrue(self.exists(".local/bin/redial-hypr"))
        self.assertTrue(self.exists(".config/omarchy/plugins/redial/DialMenu.qml"))
        self.assertIn("redial-hypr", self.read(".config/hypr/autostart.lua"))
        self.assertEqual(self.read(".config/hypr/hyprland.lua").count("^re:dial settings$"), 1)
        self.install()  # a second install adds nothing twice
        self.assertEqual(self.read(".config/hypr/hyprland.lua").count("^re:dial settings$"), 1)
        r = self.sh("uninstall.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for f in (
            "redial-hypr",
            "redial-setup",
            "redial-restart",
            "redial-bar",
            "redial-rise-widget",
            "redial-language",
        ):
            self.assertFalse(self.exists(f".local/bin/{f}"), f)
        self.assertFalse(self.exists(".config/omarchy/plugins/redial"))
        self.assertEqual(self.read(".config/hypr/autostart.lua"), self.AUTOSTART)
        self.assertEqual(self.read(".config/hypr/hyprland.lua"), self.HYPRLAND)
        self.assertEqual(self.read(".config/omarchy/extensions/omarchy-menu.jsonc"), self.MENU)

    def test_upgrading_from_the_surface_dial_beta_moves_everything_to_the_new_name(self):
        am = _load_add_menu_entry()
        self.put(".local/bin/surface-dial-hypr", "#!/bin/sh\n")
        self.put(".local/bin/surface-dial-setup", "#!/bin/sh\n")
        self.put(".config/dial-radial/config.json", '{"sensitivity": 1.5}')
        self.put(".config/dial-radial/progress.json", '{"steps": 7}')
        self.put(".local/state/surface-dial/daemon.log", "log\n")
        self.put(".config/omarchy/plugins/dial.radial/DialMenu.qml", "old")
        self.put(
            ".config/hypr/autostart.lua",
            self.AUTOSTART
            + "\n-- Surface Dial control daemon. Source: ~/.local/bin/surface-dial-hypr\n"
            + 'o.launch_on_start("surface-dial-hypr")\n',
        )
        self.put(".config/omarchy/extensions/omarchy-menu.jsonc", "{\n" + am.LEGACY_ROW + "}\n")
        self.install()
        # settings and learning progress came across; the old names are gone
        self.assertEqual(self.read(".config/redial/config.json"), '{"sensitivity": 1.5}')
        self.assertEqual(self.read(".config/redial/progress.json"), '{"steps": 7}')
        self.assertTrue(self.exists(".local/state/redial/daemon.log"))
        for gone in (
            ".config/dial-radial",
            ".local/state/surface-dial",
            ".local/bin/surface-dial-hypr",
            ".local/bin/surface-dial-setup",
            ".config/omarchy/plugins/dial.radial",
        ):
            self.assertFalse(self.exists(gone), gone)
        self.assertTrue(self.exists(".local/bin/redial-hypr"))
        self.assertTrue(self.exists(".config/omarchy/plugins/redial/DialMenu.qml"))
        # exactly one autostart line, the new one, and your own lines untouched
        lua = self.read(".config/hypr/autostart.lua")
        self.assertNotIn("surface-dial", lua)
        self.assertEqual(lua.count('launch_on_start("redial-hypr")'), 1)
        self.assertIn("-- my own line", lua)
        menu = self.read(".config/omarchy/extensions/omarchy-menu.jsonc")
        self.assertNotIn("setup.surface-dial", menu)
        self.assertEqual(menu.count('"setup.redial"'), 1)
        # the old files were backed up, not deleted
        found = []
        for _, _, files in os.walk(os.path.join(self.home, ".local/share/redial-backups")):
            found += files
        for name in ("surface-dial-hypr", "DialMenu.qml"):
            self.assertIn(name, found, name)

    def test_a_clean_machine_has_nothing_to_migrate(self):
        r = self.sh("install.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("nothing from the old name found", r.stdout)

    def test_settings_are_kept_unless_purged(self):
        self.install()
        self.put(".config/redial/config.json", '{"sensitivity": 1.5}')
        self.put(".local/state/redial/daemon.log", "log\n")
        self.assertEqual(self.sh("uninstall.sh", "-y").returncode, 0)
        self.assertEqual(self.read(".config/redial/config.json"), '{"sensitivity": 1.5}')
        self.assertEqual(self.sh("uninstall.sh", "-y", "--purge").returncode, 0)
        self.assertFalse(self.exists(".config/redial"))
        self.assertFalse(self.exists(".local/state/redial"))

    def test_nothing_is_deleted_outright_it_all_goes_to_a_backup(self):
        self.install()
        self.put(".config/redial/config.json", "{}")
        self.assertEqual(self.sh("uninstall.sh", "-y", "--purge").returncode, 0)
        base = os.path.join(self.home, ".local/share/redial-backups")
        found = []
        for root, _, files in os.walk(base):
            if "uninstall-" in root:
                found += files
        for name in ("redial-hypr", "DialMenu.qml", "config.json", "autostart.lua"):
            self.assertIn(name, found, name)

    def test_a_second_run_is_harmless(self):
        self.install()
        self.assertEqual(self.sh("uninstall.sh", "-y").returncode, 0)
        r = self.sh("uninstall.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read(".config/hypr/autostart.lua"), self.AUTOSTART)

    def test_running_it_on_a_machine_without_the_dial_changes_nothing(self):
        r = self.sh("uninstall.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read(".config/hypr/autostart.lua"), self.AUTOSTART)
        self.assertEqual(self.read(".config/omarchy/extensions/omarchy-menu.jsonc"), self.MENU)

    def test_dash_y_never_uses_sudo_and_says_how_to_remove_the_udev_rule(self):
        self.install()
        udev = "/etc/udev/rules.d/70-redial.rules"
        r = self.sh("uninstall.sh", "-y")
        self.assertFalse(any(c.startswith("sudo") for c in self.calls() if "rm -f" in c), r.stdout)
        if os.path.exists(udev):  # only on a machine that really has the rule
            self.assertIn("sudo rm " + udev, r.stdout)

    def run_with_input(self, text, *args, udev=None):
        env = dict(self.env)
        if udev:
            env["DIAL_UDEV_RULE"] = udev
        return subprocess.run(
            ["bash", os.path.join(self.ROOT, "uninstall.sh"), *args],
            env=env,
            capture_output=True,
            text=True,
            input=text,
        )

    def test_answering_no_to_the_first_question_changes_nothing(self):
        self.install()
        r = self.run_with_input("n\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Nothing changed", r.stdout)
        self.assertTrue(self.exists(".local/bin/redial-hypr"))
        self.assertTrue(self.exists(".config/omarchy/plugins/redial"))

    def test_the_udev_rule_is_removed_with_sudo_only_when_you_say_yes(self):
        self.install()
        rule = os.path.join(self.home, "70-redial.rules")
        open(rule, "w").write("x\n")
        open(self.log, "w").close()
        r = self.run_with_input("y\nn\n", udev=rule)  # go ahead; but keep the udev rule
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(any("rm -f" in c for c in self.calls()), self.calls())
        self.install()
        open(self.log, "w").close()
        r = self.run_with_input("y\ny\n", udev=rule)  # go ahead; remove the udev rule too
        self.assertTrue(any(c.startswith("sudo rm -f " + rule) for c in self.calls()), self.calls())

    def test_the_daemon_is_stopped_first(self):
        self.install()
        open(self.log, "w").close()
        # pretend it is running for the first check, then gone
        flag = os.path.join(self.stubs, "pgrep-count")
        with open(os.path.join(self.stubs, "pgrep"), "w") as f:
            f.write(
                f'#!/bin/sh\nn=$(cat "{flag}" 2>/dev/null || echo 0)\necho $((n+1)) > "{flag}"\n'
                '[ "$n" -eq 0 ] && exit 0\nexit 1\n'
            )
        os.chmod(os.path.join(self.stubs, "pgrep"), 0o755)
        r = self.sh("uninstall.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(any(c.startswith("pkill -TERM") for c in self.calls()), self.calls())

    def test_a_hand_edited_menu_entry_is_left_alone_with_a_clear_message(self):
        self.install()
        path = ".config/omarchy/extensions/omarchy-menu.jsonc"
        text = self.read(path).replace("Tools, size, clicks and appearance", "my own words")
        self.put(path, text)
        r = self.sh("uninstall.sh", "-y")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read(path), text)
        self.assertIn("setup.redial", r.stdout)

    def test_unknown_options_are_refused(self):
        r = self.sh("uninstall.sh", "--nuke")
        self.assertEqual(r.returncode, 2)


class ToolDescriptions(Base):
    """Every tool explains itself: the settings window shows it when you hover or focus the tool."""

    def test_every_library_tool_has_a_plain_one_to_three_sentence_description(self):
        for t in m.TOOL_LIBRARY:
            d = t.get("description", "")
            self.assertTrue(20 <= len(d) <= 220, (t["name"], len(d)))
            self.assertTrue(d.endswith("."), t["name"])
            self.assertLessEqual(d.count(". ") + 1, 3, t["name"])

    def test_descriptions_are_unique(self):
        descs = [t["description"] for t in m.TOOL_LIBRARY]
        self.assertEqual(len(descs), len(set(descs)))

    def test_descriptions_name_no_vendor(self):
        text = " ".join(t["description"] for t in m.TOOL_LIBRARY).lower()
        for brand in ("claude", "openai", "chatgpt", "gemini"):
            self.assertNotIn(brand, text)

    def test_the_manifest_publishes_them_with_the_default_flag(self):
        m.write_tool_manifest()
        path = os.path.join(os.path.dirname(m.CONFIG_PATH), "tools.json")
        with open(path) as f:
            manifest = json.load(f)
        self.assertEqual([e["name"] for e in manifest], [t["name"] for t in m.TOOL_LIBRARY])
        for entry, tool in zip(manifest, m.TOOL_LIBRARY, strict=True):
            self.assertEqual(entry["description"], tool["description"])
            self.assertEqual(entry["default"], tool in m.DEFAULT_TOOLS)
        self.assertFalse(next(e for e in manifest if e["name"] == "Pointer")["default"])
        self.assertTrue(next(e for e in manifest if e["name"] == "Volume")["default"])


def _git_checkout_available():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    # exists, not isdir: in a git worktree .git is a file
    return os.path.exists(os.path.join(root, ".git")) and shutil_which("git") is not None


def shutil_which(name):
    import shutil

    return shutil.which(name)


class FirstTurnFeedback(Base):
    """R1: the dial answers the first movement, and says so when it connects."""

    def turn(self, d, times, value=1):
        for t in times:
            d.on_rotate(value, t)

    def test_the_first_turn_is_acknowledged_before_any_step_completes(self):
        d = m.Dial()
        d.on_rotate(1, 1.0)  # far too small to complete a step
        self.assertEqual(SHOWN, ["volume"])

    def test_steady_turning_is_acknowledged_once_not_every_event(self):
        d = m.Dial()
        self.turn(d, [1.0 + 0.5 * i for i in range(20)])
        self.assertEqual(SHOWN, ["volume"])

    def test_turning_again_after_a_quiet_spell_is_acknowledged_again(self):
        d = m.Dial()
        self.turn(d, [1.0, 1.2, 1.4])
        self.turn(d, [1.4 + m.ACK_QUIET_S + 0.1])
        self.assertEqual(SHOWN, ["volume", "volume"])

    def test_a_reconnect_resets_it(self):
        d = m.Dial()
        self.turn(d, [1.0])
        d.reset_gestures()
        self.turn(d, [1.5])
        self.assertEqual(SHOWN, ["volume", "volume"])

    def test_it_stays_quiet_while_the_tool_menu_is_open(self):
        d = m.Dial()
        d.menu = True
        self.turn(d, [1.0])
        self.assertEqual(SHOWN, [])

    def test_a_twitch_inside_the_dead_zone_is_not_acknowledged(self):
        with open(self.cfg, "w") as f:
            json.dump({"deadzone": 50}, f)
        m._live.update(mtime=object())
        d = m.Dial()
        self.turn(d, [1.0])
        self.assertEqual(SHOWN, [])

    def test_other_tools_show_their_name(self):
        d = m.Dial()
        d.tool = tool_index("Workspaces")
        self.turn(d, [1.0])
        self.assertEqual(SHOWN, [])
        self.assertEqual(len(OSDS), 1)
        self.assertIn("Workspaces", OSDS[0]["message"])

    def test_brightness_shows_the_brightness_level(self):
        d = m.Dial()
        d.tool = tool_index("Brightness")
        self.turn(d, [1.0])
        self.assertEqual(SHOWN, ["brightness"])

    def test_connecting_says_what_turning_does(self):
        seen = []
        m.notify = lambda title, body="": seen.append((title, body))
        m.Dial().show_connected()
        self.assertIn("ready", seen[0][0])
        self.assertEqual(seen[0][1], "Turn to change volume")


class LevelOverlay(Base):
    """The on-screen display that follows every volume or brightness step."""

    def setUp(self):
        super().setUp()
        self.cmds = []
        m.run = self.cmds.append
        m.shutil = types.SimpleNamespace(which=lambda name: f"/x/{name}")
        self.real_show_level = PRISTINE["_show_level"]

    def test_osd_builds_the_omarchy_command_for_a_level(self):
        PRISTINE["osd"](icon="volume", progress=40)
        self.assertEqual(self.cmds, [["/x/omarchy-osd", "-d", "900", "-i", "volume", "-p", "40"]])

    def test_osd_clamps_the_progress(self):
        PRISTINE["osd"](icon="volume", progress=150)
        PRISTINE["osd"](icon="volume", progress=-5)
        self.assertEqual([c[-1] for c in self.cmds], ["100", "0"])

    def test_osd_shows_a_message(self):
        PRISTINE["osd"](message="hello")
        self.assertEqual(self.cmds, [["/x/omarchy-osd", "-d", "900", "-m", "hello"]])

    def test_without_omarchy_osd_it_falls_back_to_a_notification(self):
        m.shutil = types.SimpleNamespace(which=lambda name: None)
        seen = []
        m.notify = lambda *a, **k: seen.append(a)
        PRISTINE["osd"](message="hello")
        self.assertEqual(seen, [("hello",)])
        self.assertEqual(self.cmds, [])

    def test_a_burst_of_steps_queues_one_overlay_that_shows_the_latest_level(self):
        jobs = []
        m.ACTIONS = types.SimpleNamespace(submit=lambda fn, *a: jobs.append((fn, a)))
        m._show_level = self.real_show_level
        level = {"v": (10, "10%")}
        m.MenuUI = types.SimpleNamespace(_volume=lambda: level["v"])
        for _ in range(5):
            m.show_level("volume")
        self.assertEqual(len(jobs), 1)
        level["v"] = (42, "42%")  # the dial kept turning while the job waited
        fn, args = jobs.pop()
        fn(*args)
        self.assertEqual(OSDS, [{"icon": "volume", "progress": 42}])
        m.show_level("volume")  # once it has run, the next step may queue another
        self.assertEqual(len(jobs), 1)

    def test_muted_volume_shows_the_muted_icon_at_zero(self):
        m.MenuUI = types.SimpleNamespace(_volume=lambda: (0, "muted"))
        self.real_show_level("volume")
        self.assertEqual(OSDS, [{"icon": "volume-muted", "progress": 0}])

    def test_unreadable_volume_shows_nothing(self):
        m.MenuUI = types.SimpleNamespace(_volume=lambda: None)
        self.real_show_level("volume")
        self.assertEqual(OSDS, [])

    def test_brightness_level_is_shown(self):
        m.read_brightness = lambda device=None: 70
        self.real_show_level("brightness")
        self.assertEqual(OSDS, [{"icon": "brightness", "progress": 70}])

    def test_a_volume_step_asks_for_the_overlay(self):
        m.run = lambda cmd: EVENTS.append("EXEC:" + " ".join(cmd[:2]))
        m.vol(2, True)
        self.assertEqual(SHOWN, ["volume"])
        self.assertIn("EXEC:wpctl set-volume", EVENTS)

    def test_a_brightness_step_asks_for_the_overlay(self):
        m.read_brightness = lambda device=None: 50
        m.set_brightness(1, True, device="x")
        self.assertEqual(SHOWN, ["brightness"])


class GuideTests(Base):
    """The adaptive introduction: hints come when behaviour shows readiness, never nag, persist."""

    def setUp(self):
        super().setUp()
        self.path = os.path.join(self.tmp, "progress.json")
        self.now = [1000.0]
        self.said = []
        self.metas = []

    def say(self, text, meta=None):
        self.said.append(text)
        self.metas.append(meta)

    def guide(self, enabled=lambda: True):
        return m.Guide(self.path, self.say, clock=lambda: self.now[0], enabled=enabled)

    def steps(self, g, n):
        for _ in range(n):
            g.event("step")

    def set_cfg(self, **kv):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    # --- when hints appear
    def test_no_hint_until_the_person_has_turned_a_while_without_pressing(self):
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT - 1)
        self.assertEqual(self.said, [])
        g.event("step")
        self.assertEqual(self.said, ["Press the dial: mute"])

    def test_pressing_early_completes_the_stage_and_no_press_hint_ever_shows(self):
        g = self.guide()
        self.steps(g, 3)
        g.event("click")
        self.steps(g, 40)
        self.assertNotIn("Press the dial: mute", self.said)
        self.assertIn("press", g.state["done"])

    def test_the_next_stage_follows_in_order(self):
        g = self.guide()
        g.event("click")
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, ["Hold the button to choose a tool"])

    def test_an_event_completes_its_stage_even_out_of_order(self):
        g = self.guide()
        g.event("menu")  # opened the tool menu before ever pressing
        self.assertEqual(g.state["done"], ["hold"])
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, ["Press the dial: mute"])  # press is still the next lesson

    def test_closing_the_menu_without_choosing_shows_how_to_choose(self):
        g = self.guide()
        g.event("click")
        g.event("menu")
        g.event("menu_same")
        self.assertEqual(self.said, ["Keep holding, turn to a tool, then let go"])

    def test_the_choosing_hint_follows_the_tap_menu_setting(self):
        self.set_cfg(menu_latch=True)
        g = self.guide()
        g.event("click")
        g.event("menu")
        g.event("menu_same")
        self.assertEqual(self.said, ["Turn to a tool, then click to choose it"])

    def test_the_choosing_hint_answers_at_once_even_right_after_another_hint(self):
        g = self.guide()
        g.event("click")
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)  # the hold hint
        self.assertEqual(self.said, ["Hold the button to choose a tool"])
        g.event("menu")
        g.event("menu_same")  # seconds later: they opened the menu and let go
        self.assertEqual(self.said[-1], "Keep holding, turn to a tool, then let go")

    def test_choosing_a_tool_completes_that_stage(self):
        g = self.guide()
        g.event("menu")
        g.event("pick")
        self.assertEqual(g.state["done"], ["hold", "pick"])
        g.event("menu_same")
        self.assertEqual(self.said, [])

    def test_the_last_stage_points_to_settings_once_and_only_after_the_others(self):
        g = self.guide()
        for kind in ("click", "menu", "pick"):
            g.event(kind)
        self.steps(g, 3 * m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, ["Make it yours: Menu > Setup > re:dial"])
        self.now[0] += 1000
        self.steps(g, 100)
        self.assertEqual(len(self.said), 1)  # showing it was the lesson

    # --- it never nags
    def test_a_hint_is_followed_by_a_cooldown(self):
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(len(self.said), 1)
        self.now[0] += m.GUIDE_COOLDOWN_S + 1
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(len(self.said), 2)

    def test_a_hint_that_has_not_worked_is_dropped_after_a_few_showings(self):
        g = self.guide()
        for _ in range(m.GUIDE_MAX_SHOWS + 3):
            self.now[0] += m.GUIDE_COOLDOWN_S + 1
            self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(len(self.said), m.GUIDE_MAX_SHOWS)

    def test_switched_off_it_stays_silent_but_still_counts(self):
        g = self.guide(enabled=lambda: False)
        self.steps(g, 50)
        g.event("click")
        self.assertEqual(self.said, [])
        self.assertEqual((g.state["counts"]["steps"], g.state["counts"]["clicks"]), (50, 1))

    def test_a_press_hint_is_skipped_when_the_click_does_nothing(self):
        m.TOOLS[m.IDLE_TOOL]["click_label"] = "\u2014"
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, [])

    def test_the_hints_follow_the_settings(self):
        self.set_cfg(guide=False)
        self.assertFalse(m.guide_enabled())
        self.set_cfg(osd=False)
        self.assertFalse(m.guide_enabled())  # a screen with no display has nowhere to show them
        self.set_cfg()
        self.assertTrue(m.guide_enabled())

    # --- progress is kept
    def test_progress_survives_a_restart(self):
        g = self.guide()
        g.event("click")
        self.steps(g, 12)
        g.event("menu")
        g.flush()
        again = self.guide()
        self.assertEqual(again.state["done"], ["press", "hold"])
        self.assertEqual(again.state["counts"]["steps"], 12)

    def test_counters_are_written_at_most_every_half_minute(self):
        g = self.guide()
        self.steps(g, 3)
        self.assertFalse(os.path.exists(self.path))
        self.now[0] += m.GUIDE_FLUSH_S + 1
        g.event("step")
        self.assertTrue(os.path.exists(self.path))

    def test_a_damaged_or_odd_file_starts_fresh_without_crashing(self):
        for junk in ("not json", "[1, 2]", json.dumps({"done": "x", "shown": [], "counts": 5})):
            with open(self.path, "w") as f:
                f.write(junk)
            g = self.guide()
            self.assertEqual(g.state["done"], [])
            self.assertEqual(g.state["counts"]["steps"], 0)

    def test_odd_values_inside_a_good_file_are_ignored(self):
        with open(self.path, "w") as f:
            json.dump(
                {
                    "done": ["press", 7],
                    "shown": {"press": "x", "hold": 2},
                    "counts": {"steps": -4, "clicks": 9},
                },
                f,
            )
        g = self.guide()
        self.assertEqual(g.state["done"], ["press"])
        self.assertEqual(g.state["shown"], {"hold": 2})
        self.assertEqual((g.state["counts"]["steps"], g.state["counts"]["clicks"]), (0, 9))

    def test_reset_starts_the_introduction_again(self):
        g = self.guide()
        g.event("click")
        g.reset()
        self.assertEqual(g.state["done"], [])
        self.assertEqual(self.guide().state["done"], [])

    def test_an_unwritable_place_does_not_stop_the_dial(self):
        self.path = "/proc/nope/progress.json"
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)  # writes (and fails) when the hint shows
        self.assertEqual(len(self.said), 1)

    def test_hints_go_to_the_on_screen_display(self):
        shown = []
        m.osd = lambda **k: shown.append(k)
        m.guide_say("hello")
        self.assertEqual(shown, [{"message": "hello", "duration": 3500}])


class GuideReset(Base):
    def test_it_removes_the_progress_file(self):
        path = os.path.join(self.tmp, "progress.json")
        with open(path, "w") as f:
            f.write("{}")
        code, msg = m.reset_guide_file(path, running=False)
        self.assertEqual(code, 0)
        self.assertFalse(os.path.exists(path))
        self.assertIn("start again", msg)

    def test_it_says_so_when_there_is_nothing_to_reset(self):
        code, msg = m.reset_guide_file(os.path.join(self.tmp, "none.json"), running=False)
        self.assertEqual(code, 0)
        self.assertIn("Nothing to reset", msg)

    def test_it_refuses_while_the_daemon_runs_because_it_would_write_it_back(self):
        path = os.path.join(self.tmp, "progress.json")
        with open(path, "w") as f:
            f.write("{}")
        code, msg = m.reset_guide_file(path, running=True)
        self.assertEqual(code, 1)
        self.assertTrue(os.path.exists(path))
        self.assertIn("Stop it first", msg)

    def test_the_flag_is_documented_in_help(self):
        out = subprocess.run(
            [sys.executable, "-I", os.path.abspath(DAEMON), "--help"],
            capture_output=True,
            text=True,
            env={
                "DIAL_CONFIG_DIR": self.tmp,
                "DIAL_LOG_PATH": os.path.join(self.tmp, "l"),
                "PATH": os.environ["PATH"],
            },
        ).stdout
        self.assertIn("--reset-guide", out)


class GuideHooks(Base):
    """The dial tells the guide what the person did."""

    def setUp(self):
        super().setUp()
        self.seen = []
        self.armed = []
        m.GUIDE = types.SimpleNamespace(
            event=self.seen.append,
            armed=lambda name, rest=False: self.armed.append((name, rest)),
            attached=lambda: None,
            flush=lambda: None,
        )

    def test_a_completed_step_is_reported(self):
        d = m.Dial()
        d.on_rotate(60, 0.0)
        self.assertEqual(self.seen.count("step"), 1)

    def test_a_single_click_is_reported(self):
        self.gesture(1)
        self.assertEqual(self.seen, ["click"])

    def test_opening_the_menu_and_leaving_it_unchanged_is_reported(self):
        d = m.Dial()
        d.on_press(0.0)
        d.tick(1.0)
        d.on_release(1.1)
        self.assertEqual(self.seen, ["menu", "menu_same"])

    def test_choosing_a_different_tool_is_reported(self):
        d = m.Dial()
        d.on_press(0.0)
        d.tick(1.0)
        d.menu_pick = 1
        d.on_release(1.1)
        self.assertEqual(self.seen, ["menu", "pick"])

    def test_choosing_a_tool_reports_it_as_armed_and_going_back_as_the_resting_tool(self):
        d = m.Dial()
        d.on_press(0.0)
        d.tick(1.0)
        d.menu_pick = 1
        d.on_release(1.1)
        self.assertEqual(self.armed, [(m.TOOLS[1]["name"], False)])
        d.disarm(2.0)
        self.assertEqual(self.armed[-1], (m.TOOLS[m.IDLE_TOOL]["name"], True))

    def test_arming_the_tool_that_is_already_active_is_not_reported(self):
        d = m.Dial()
        d._arm(m.IDLE_TOOL, 0.0)
        self.assertEqual(self.armed, [])

    def test_scrolling_counts_as_steps_too(self):
        d = m.Dial()
        d.tool = tool_index("Scroll")
        m.POINTER = types.SimpleNamespace(scroll=lambda *a, **k: None)
        real = m.focused_class
        m.focused_class = lambda: (
            ""
        )  # not the live desktop: some focused windows suppress scrolling
        self.addCleanup(lambda: setattr(m, "focused_class", real))
        d.on_rotate(m.SCROLL_TICK * 3, 0.0)
        self.assertGreaterEqual(self.seen.count("step"), 1)


class GuideModes(Base):
    """Discover, guided and the per-tool hints, on top of the adaptive stages."""

    def setUp(self):
        super().setUp()
        self.path = os.path.join(self.tmp, "progress.json")
        self.now = [1000.0]
        self.said = []
        self.metas = []
        self.mode = ["adaptive"]
        self.on = [True]
        self.lines = {
            "Windows": {"intro": "Windows: Cycle focus", "click": "Windows: click to maximize"},
            "Zoom": {"intro": "Zoom: Ctrl+scroll", "click": "Zoom: click to reset"},
            "Volume": {"intro": "Volume: turn it up", "click": "Volume: click to mute"},
        }

    def say(self, text, meta=None):
        self.said.append(text)
        self.metas.append(meta)

    def guide(self):
        return m.Guide(
            self.path,
            self.say,
            clock=lambda: self.now[0],
            enabled=lambda: self.on[0],
            mode=lambda: self.mode[0],
            describe=self.lines.get,
        )

    def steps(self, g, n):
        for _ in range(n):
            g.event("step")

    # --- discover
    def test_discover_says_nothing_to_begin_with(self):
        self.mode[0] = "discover"
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT - 1)
        self.assertEqual(self.said, [])

    def test_discover_offers_press_after_a_while_and_hold_right_after_the_first_press(self):
        self.mode[0] = "discover"
        g = self.guide()
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, ["Press the dial: mute"])
        g.event("click")
        self.assertEqual(self.said[-1], "Hold the button for the tool ring")

    def test_discover_stops_after_hold_and_never_points_to_settings(self):
        self.mode[0] = "discover"
        g = self.guide()
        g.event("click")
        g.event("menu")
        self.said.clear()
        g.event("pick")
        self.now[0] += 1000
        self.steps(g, 100)
        self.assertEqual(self.said, [])

    def test_discover_with_an_early_press_still_hints_hold_on_that_press(self):
        self.mode[0] = "discover"
        g = self.guide()
        g.event("click")
        self.assertEqual(self.said, ["Hold the button for the tool ring"])

    def test_discover_does_not_show_the_hold_hint_to_someone_who_already_holds(self):
        self.mode[0] = "discover"
        g = self.guide()
        g.event("menu")
        g.event("click")
        self.assertEqual(self.said, [])

    # --- per-tool hints
    def test_a_tool_is_introduced_the_first_time_it_is_picked_and_not_again(self):
        g = self.guide()
        g.armed("Windows")
        self.assertEqual(self.said, ["Windows: Cycle focus"])
        g.armed("Windows")
        g.armed("Volume", rest=True)
        g.armed("Windows")
        self.assertEqual(len(self.said), 1)
        self.assertEqual(g.state["tools"]["Windows"]["intro"], 1)

    def test_the_resting_tool_is_never_introduced(self):
        g = self.guide()
        g.armed("Volume", rest=True)
        self.now[0] += m.GUIDE_COOLDOWN_S + 1
        g.state["done"] = ["press", "hold", "pick", "own"]
        self.steps(g, 50)
        self.assertEqual(self.said, [])

    def test_each_new_tool_gets_its_own_introduction(self):
        g = self.guide()
        g.armed("Windows")
        g.armed("Zoom")
        self.assertEqual(self.said, ["Windows: Cycle focus", "Zoom: Ctrl+scroll"])

    def test_a_tool_with_no_description_is_picked_silently(self):
        g = self.guide()
        g.armed("My Custom Tool")
        self.assertEqual(self.said, [])

    def test_turning_a_tool_a_while_without_clicking_says_what_its_click_does(self):
        g = self.guide()
        g.state["done"] = ["press", "hold", "pick", "own"]
        g.armed("Windows")
        self.now[0] += m.GUIDE_COOLDOWN_S + 1
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT - 1)
        self.assertEqual(len(self.said), 1)
        g.event("step")
        self.assertEqual(self.said[-1], "Windows: click to maximize")

    def test_clicking_the_tool_ends_its_click_hint(self):
        g = self.guide()
        g.state["done"] = ["press", "hold", "pick", "own"]
        g.armed("Windows")
        g.event("click")
        self.now[0] += m.GUIDE_COOLDOWN_S + 1
        self.steps(g, 50)
        self.assertNotIn("Windows: click to maximize", self.said)
        self.assertTrue(g.state["tools"]["Windows"]["clicked"])

    def test_the_click_hint_repeats_for_the_next_tool_you_try(self):
        g = self.guide()
        g.state["done"] = ["press", "hold", "pick", "own"]
        for tool in ("Windows", "Zoom"):
            g.armed(tool)
            self.now[0] += m.GUIDE_COOLDOWN_S + 1
            self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertIn("Windows: click to maximize", self.said)
        self.assertIn("Zoom: click to reset", self.said)

    def test_a_click_hint_that_has_not_worked_is_dropped_after_a_few_showings(self):
        g = self.guide()
        g.state["done"] = ["press", "hold", "pick", "own"]
        g.armed("Windows")
        for _ in range(m.GUIDE_MAX_SHOWS + 3):
            self.now[0] += m.GUIDE_COOLDOWN_S + 1
            self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said.count("Windows: click to maximize"), m.GUIDE_MAX_SHOWS)

    def test_a_click_hint_waits_for_the_cooldown_after_any_other_hint(self):
        g = self.guide()
        g.armed("Windows")  # the introduction counts as a hint
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said, ["Windows: Cycle focus"])

    def test_a_global_hint_takes_the_turn_when_both_are_due(self):
        g = self.guide()
        g.armed("Windows")
        self.now[0] += m.GUIDE_COOLDOWN_S + 1
        self.steps(g, m.GUIDE_STEPS_BEFORE_HINT)
        self.assertEqual(self.said[-1], "Press the dial: mute")

    def test_discover_also_teaches_tools_as_they_are_tried(self):
        self.mode[0] = "discover"
        g = self.guide()
        g.armed("Windows")
        self.assertEqual(self.said, ["Windows: Cycle focus"])

    def test_tool_hints_are_silent_when_hints_are_off_but_the_steps_still_count(self):
        self.on[0] = False
        g = self.guide()
        g.armed("Windows")
        self.steps(g, 30)
        self.assertEqual(self.said, [])
        self.assertEqual(g.state["tools"]["Windows"]["steps"], 30)
        self.assertEqual(g.state["tools"]["Windows"]["intro"], 0)

    def test_a_tool_picked_while_hints_were_off_is_introduced_once_they_are_back(self):
        self.on[0] = False
        g = self.guide()
        g.armed("Windows")
        self.on[0] = True
        g.armed("Zoom")
        self.assertEqual(self.said, ["Zoom: Ctrl+scroll"])

    # --- guided tour
    def tour(self):
        self.mode[0] = "guided"
        return self.guide()

    def test_the_tour_asks_for_the_first_step_when_the_dial_connects(self):
        g = self.tour()
        g.attached()
        self.assertEqual(self.said, ["Turn the dial"])

    def test_tour_hints_carry_their_gesture_and_place(self):
        g = self.tour()
        g.attached()
        self.steps(g, m.TOUR_TURN_STEPS)
        n = len(m.TOUR_STEPS)
        self.assertEqual(self.metas[0], {"gesture": "turn", "step": 1, "steps": n})
        self.assertEqual(self.metas[1], {"gesture": "press", "step": 2, "steps": n})

    def test_the_other_styles_do_not_start_a_tour(self):
        for mode in ("adaptive", "discover"):
            self.mode[0] = mode
            g = self.guide()
            g.attached()
        self.assertEqual(self.said, [])

    def test_the_tour_goes_through_every_gesture_in_order(self):
        g = self.tour()
        g.attached()
        self.steps(g, m.TOUR_TURN_STEPS - 1)
        self.assertEqual(self.said, ["Turn the dial"])
        g.event("step")
        g.event("click")
        g.event("menu")
        g.event("menu_same")
        g.event("menu")
        g.event("pick")
        self.assertEqual(
            self.said,
            [
                "Turn the dial",
                "Now press it",
                "Press and hold to open the tool ring",
                "Let go to close the ring",
                "Hold, turn to another tool, then let go",
                "Too fast or slow? Menu > Setup > re:dial > Feel",
            ],
        )
        self.assertTrue(g.state["tour"]["done"])

    def test_the_tour_wording_follows_the_tap_menu_setting(self):
        self.set_cfg(menu_latch=True)
        g = self.tour()
        g.attached()
        self.steps(g, m.TOUR_TURN_STEPS)
        g.event("click")
        g.event("menu")
        self.assertEqual(self.said[-1], "Click to close the ring")
        g.event("menu_same")
        self.assertEqual(self.said[-1], "Hold, turn to another tool, then click to choose it")

    def set_cfg(self, **kv):
        time.sleep(0.005)
        with open(self.cfg, "w") as f:
            json.dump(kv, f)

    def test_a_gesture_done_early_moves_the_tour_past_the_steps_before_it(self):
        g = self.tour()
        g.attached()
        g.event("menu")  # held straight away
        self.assertEqual(self.said[-1], "Let go to close the ring")
        self.assertEqual(g.state["tour"]["step"], 3)

    def test_choosing_a_tool_while_closing_the_ring_finishes_both_steps(self):
        g = self.tour()
        g.attached()
        g.event("menu")
        g.event("pick")
        self.assertEqual(self.said[-1], "Too fast or slow? Menu > Setup > re:dial > Feel")

    def test_a_step_nobody_does_is_asked_again_after_a_pause_not_before(self):
        g = self.tour()
        g.attached()
        g.event("click")  # press at once; now waiting for hold
        self.assertEqual(self.said[-1], "Press and hold to open the tool ring")
        n = len(self.said)
        self.now[0] += m.TOUR_REPROMPT_S - 1
        g.event("step")
        self.assertEqual(len(self.said), n)
        self.now[0] += 2
        g.event("step")
        self.assertEqual(self.said[-1], "Press and hold to open the tool ring")
        self.assertEqual(len(self.said), n + 1)

    def test_a_step_that_is_asked_enough_times_is_skipped_so_the_tour_never_sticks(self):
        g = self.tour()
        g.attached()
        self.steps(g, m.TOUR_TURN_STEPS)  # on to "press"; the person only keeps turning
        self.assertEqual(self.said[-1], "Now press it")
        for _ in range(m.TOUR_MAX_PROMPTS - 1):  # the first ask was the advance itself
            self.now[0] += m.TOUR_REPROMPT_S + 1
            g.event("step")
            self.assertEqual(self.said[-1], "Now press it")
        self.assertEqual(g.state["tour"]["skipped"], [])
        self.now[0] += m.TOUR_REPROMPT_S + 1
        g.event("step")
        self.assertEqual(g.state["tour"]["skipped"], ["press"])
        self.assertEqual(self.said[-1], "Press and hold to open the tool ring")

    def test_a_finished_tour_stays_finished(self):
        g = self.tour()
        g.attached()
        for kind in ("click", "menu", "pick"):
            g.event(kind)
        said = len(self.said)
        g.attached()
        self.now[0] += 1000
        self.steps(g, 50)
        g.event("click")
        self.assertEqual(len(self.said), said)

    def test_the_tour_only_runs_while_hints_are_on(self):
        self.on[0] = False
        g = self.tour()
        g.attached()
        g.event("click")
        self.assertEqual(self.said, [])
        self.assertEqual(g.state["tour"]["step"], 0)

    def test_the_tour_does_not_teach_tools_one_by_one(self):
        g = self.tour()
        g.state["tour"]["done"] = True
        g.armed("Windows")
        self.assertEqual(self.said, [])

    def test_an_unfinished_tour_resumes_where_it_stopped_after_a_restart(self):
        g = self.tour()
        g.attached()
        g.event("click")
        g.flush()
        g2 = self.guide()
        g2.attached()
        self.assertEqual(self.said[-1], "Press and hold to open the tool ring")

    # --- switching style
    def test_changing_the_style_keeps_what_was_already_learned(self):
        g = self.guide()
        g.event("click")
        self.mode[0] = "discover"
        self.steps(g, 3 * m.GUIDE_STEPS_BEFORE_HINT)
        self.assertNotIn("Press the dial: mute", self.said)
        self.assertIn("press", g.state["done"])

    def test_changing_to_the_tour_mid_way_asks_for_the_current_step_on_the_next_wake(self):
        g = self.guide()
        self.mode[0] = "guided"
        g.attached()
        self.assertEqual(self.said, ["Turn the dial"])

    # --- the setting and the saved data
    def test_the_style_setting_accepts_three_values_and_defaults_to_adaptive(self):
        for value, expected in (
            ("discover", "discover"),
            ("guided", "guided"),
            ("adaptive", "adaptive"),
            ("nonsense", "adaptive"),
            (3, "adaptive"),
            (None, "adaptive"),
        ):
            time.sleep(0.005)
            with open(self.cfg, "w") as f:
                json.dump({"onboarding_mode": value}, f)
            self.assertEqual(m.guide_mode(), expected)

    def test_no_style_set_means_adaptive(self):
        self.assertEqual(m.guide_mode(), "adaptive")

    def test_tool_progress_and_the_tour_are_saved_and_loaded(self):
        g = self.guide()
        g.armed("Windows")
        g.event("click")
        self.steps(g, 4)
        g.flush()
        g2 = self.guide()
        self.assertEqual(
            g2.state["tools"]["Windows"],
            {"intro": 1, "click_shown": 0, "clicked": True, "steps": 4},
        )

    def test_damaged_tool_and_tour_data_falls_back_to_a_fresh_start(self):
        with open(self.path, "w") as f:
            json.dump(
                {"tools": {"Windows": {"intro": "x", "clicked": 3}, 7: 1}, "tour": {"step": 99}},
                f,
            )
        g = self.guide()
        self.assertEqual(g.state["tools"]["Windows"], m.Guide._tool_entry())
        self.assertEqual(g.state["tour"]["step"], len(m.TOUR_STEPS) - 1)

    def test_old_progress_files_without_the_new_fields_still_load(self):
        with open(self.path, "w") as f:
            json.dump({"version": 1, "done": ["press"], "shown": {"press": 1}}, f)
        g = self.guide()
        self.assertEqual(g.state["done"], ["press"])
        self.assertEqual(g.state["tools"], {})
        self.assertFalse(g.state["tour"]["done"])

    def test_resetting_clears_the_tool_and_tour_progress_too(self):
        g = self.tour()
        g.attached()
        g.armed("Windows")
        g.reset()
        self.assertEqual(g.state["tools"], {})
        self.assertEqual(g.state["tour"]["step"], 0)

    # --- the text for each tool
    def test_the_tool_lines_come_from_the_tool_library_and_the_active_click(self):
        lines = m.tool_lines("Windows")
        self.assertTrue(lines["intro"].startswith("Windows: Cycle focus through your open windows"))
        self.assertNotIn("Click maximizes", lines["intro"])
        self.assertEqual(lines["click"], "Windows: click to maximize")

    def test_the_click_line_follows_a_single_click_override(self):
        self.set_cfg(single_click="dictation")
        self.assertIn("click to", m.tool_lines("Windows").get("click", "click to"))

    def test_a_tool_the_library_does_not_know_has_no_introduction(self):
        self.assertNotIn("intro", m.tool_lines("No Such Tool"))


class PrivateFiles(unittest.TestCase):
    def test_old_world_readable_files_are_tightened(self):
        root = tempfile.mkdtemp()
        state, config = os.path.join(root, "state"), os.path.join(root, "cfg")
        for d in (state, config):
            os.makedirs(d, mode=0o755)
        log_path, cfg_path = os.path.join(state, "daemon.log"), os.path.join(config, "config.json")
        for f in (log_path, cfg_path):
            with open(f, "w") as fh:
                fh.write("x")
            os.chmod(f, 0o644)
        old_mask = os.umask(0o022)
        real = (m.LOG_PATH, m.CONFIG_PATH)
        m.LOG_PATH, m.CONFIG_PATH = log_path, cfg_path
        self.addCleanup(
            lambda: (setattr(m, "LOG_PATH", real[0]), setattr(m, "CONFIG_PATH", real[1]))
        )
        self.addCleanup(lambda: os.umask(old_mask))
        m.make_private()
        self.assertEqual(os.stat(state).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(config).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(log_path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(cfg_path).st_mode & 0o777, 0o600)

    def test_new_files_are_private_after_it(self):
        old_mask = os.umask(0o022)
        self.addCleanup(lambda: os.umask(old_mask))
        m.make_private()
        path = os.path.join(tempfile.mkdtemp(), "new.json")
        m.write_json_atomic(path, {})
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_the_overlay_socket_has_no_tmp_fallback(self):
        saved = os.environ.pop("XDG_RUNTIME_DIR", None)
        self.addCleanup(
            lambda: saved is not None and os.environ.__setitem__("XDG_RUNTIME_DIR", saved)
        )
        src = open(m.__file__ if hasattr(m, "__file__") else "bin/redial-hypr").read()
        self.assertNotIn('"/tmp"), "redial.sock"', src)
        stream = m.MenuStream()
        stream.PATH = None
        stream.connect()
        self.assertIsNone(stream.sock)


class OverlayNotes(Base):
    """Turning, hints and can't-act go to re:dial's own overlay, or to Omarchy's OSD without it."""

    def setUp(self):
        super().setUp()
        self.notes = m.MENU_NOTES = Notes(listening=True)
        OSDS.clear()

    def listen(self):
        """A real socket where the overlay would be.

        Returns (stream, accepted-connection reader)."""
        import socket as so

        path = os.path.join(self.tmp, "redial.sock")
        server = so.socket(so.AF_UNIX, so.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        self.addCleanup(server.close)
        stream = m.MenuStream()
        stream.PATH = path
        return stream, server

    def test_a_note_is_one_json_line_after_its_kind(self):
        stream, server = self.listen()
        self.assertTrue(stream.note("hint", {"prompt": "Turn the dial", "gesture": "turn"}))
        conn, _ = server.accept()
        self.addCleanup(conn.close)
        stream.close()
        kind, _, body = conn.recv(4096).decode().rstrip("\n").partition(" ")
        self.assertEqual(kind, "hint")
        self.assertEqual(json.loads(body), {"prompt": "Turn the dial", "gesture": "turn"})

    def test_with_nothing_listening_it_retries_only_now_and_then(self):
        stream = m.MenuStream()
        stream.PATH = os.path.join(self.tmp, "nobody.sock")
        tries = []
        real = stream.connect
        stream.connect = lambda quiet=False: (tries.append(1), real(quiet))
        for _ in range(50):
            self.assertFalse(stream.note("turn", {"name": "Volume"}))
        self.assertEqual(len(tries), 1)

    def test_level_readouts_are_held_to_about_ten_a_second(self):
        stream, server = self.listen()
        self.assertEqual(stream.turn_wait(), 0.0, "not connected: no wait")
        stream.note("turn", {"name": "Volume"})
        self.assertGreater(stream.turn_wait(), 0.05)
        stream.last_turn -= stream.TURN_INTERVAL
        self.assertEqual(stream.turn_wait(), 0.0)

    def test_a_volume_step_shows_its_level_on_the_overlay(self):
        m.MenuUI = types.SimpleNamespace(_volume=lambda: (42, "42%"))
        PRISTINE["_show_level"]("volume")
        self.assertEqual(OSDS, [])
        kind, doc = self.notes.sent[0]
        self.assertEqual(kind, "turn")
        self.assertEqual((doc["name"], doc["value"], doc["valueText"]), ("Volume", 42, "42%"))

    def test_without_the_overlay_a_level_goes_to_omarchys_display(self):
        self.notes.listening = False
        m.MenuUI = types.SimpleNamespace(_volume=lambda: (42, "42%"))
        PRISTINE["_show_level"]("volume")
        self.assertEqual(OSDS, [{"icon": "volume", "progress": 42}])

    def test_a_turned_tool_without_a_level_is_named(self):
        d = m.Dial()
        d.tool = next(i for i, t in enumerate(m.TOOLS) if t["name"] == "Zoom")
        d.show_ack()
        self.assertEqual(self.notes.sent[0][0], "turn")
        self.assertEqual(self.notes.sent[0][1]["name"], "Zoom")
        self.assertNotIn("value", self.notes.sent[0][1])

    def test_a_hint_goes_to_the_overlay_with_its_gesture(self):
        m.guide_say("Now press it", {"gesture": "press", "step": 2, "steps": 6})
        self.assertEqual(
            self.notes.sent,
            [("hint", {"prompt": "Now press it", "gesture": "press", "step": 2, "steps": 6})],
        )
        self.assertEqual(OSDS, [])

    def test_a_tool_that_cannot_act_says_why(self):
        m.read_brightness = lambda d=None: None
        m.backlight_device = lambda: None
        m._bright_said[0] = -1e9
        m.set_brightness(1, True)
        kind, doc = self.notes.sent[0]
        self.assertEqual((kind, doc["reason"]), ("cant", "tool"))
        self.assertEqual(doc["line"], "No screen backlight on this machine")

    def test_a_look_that_does_not_draw_states_leaves_them_to_omarchy(self):
        with open(self.cfg, "w") as f:
            json.dump({"layout": "omarchy"}, f)  # the shell's OSD box draws no states
        m.guide_say("Now press it")
        self.assertEqual(self.notes.sent, [])
        self.assertEqual(OSDS, [{"message": "Now press it", "duration": 3500}])

    def test_with_the_display_off_nothing_reaches_the_overlay(self):
        m.osd_enabled = lambda: False
        self.assertFalse(m.overlay_note("hint", {"prompt": "x"}))
        self.assertEqual(self.notes.sent, [])


class LaunchDoesNotWait(unittest.TestCase):
    def test_a_long_running_program_is_started_and_left_alone(self):
        t0 = time.monotonic()
        m.launch(["sleep", "30"])
        self.assertLess(time.monotonic() - t0, 1.0)
        pids = subprocess.run(["pgrep", "-xf", "sleep 30"], capture_output=True, text=True)
        self.assertTrue(pids.stdout.split(), "the program must still be running")
        subprocess.run(["pkill", "-xf", "sleep 30"])

    def test_a_missing_program_is_logged_not_raised(self):
        m.launch(["/nonexistent/program"])

    def test_exec_actions_and_the_assistant_use_it(self):
        started = []
        real = m.launch
        m.launch = started.append
        self.addCleanup(lambda: setattr(m, "launch", real))
        m._compile_exec({"do": "exec", "cmd": ["obsidian"]})(1)
        self.assertEqual(started, [["obsidian"]])


class FocusLookupIsCached(unittest.TestCase):
    def test_many_quick_asks_cost_one_lookup(self):
        calls = []
        b = m.SwayBackend()
        b.active = lambda: calls.append(1) or {"class": "foot"}
        for _ in range(100):
            self.assertEqual(b.focused_class(), "foot")
        self.assertEqual(len(calls), 1)

    def test_it_asks_again_after_the_cache_expires(self):
        calls = []
        b = m.SwayBackend()
        b.active = lambda: calls.append(1) or {"class": "foot"}
        b.focused_class()
        b._seen = (b._seen[0] - 1.0, b._seen[1])
        b.focused_class()
        self.assertEqual(len(calls), 2)


class DetachReleasesTheModifier(unittest.TestCase):
    def test_a_dropped_dial_releases_a_held_ctrl(self):
        install_stubs(os.path.join(tempfile.mkdtemp(), "config.json"))
        pressed, released = [], []
        real = (m.press_mod, m.release_mod)
        m.press_mod = pressed.append
        m.release_mod = lambda: released.append(1)
        self.addCleanup(
            lambda: (setattr(m, "press_mod", real[0]), setattr(m, "release_mod", real[1]))
        )
        d = m.Dial()
        d._arm(tool_index("Zoom"), 1.0)
        self.assertEqual(pressed, ["ctrl"])
        d.detach()
        self.assertEqual(released, [1])
        self.assertEqual(d.tool, m.IDLE_TOOL)


class AtomicJsonWrites(unittest.TestCase):
    def test_writes_valid_json_and_leaves_no_temp_file(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "sub", "x.json")
        m.write_json_atomic(path, {"a": 1}, indent=2)
        with open(path) as f:
            self.assertEqual(json.load(f), {"a": 1})
        self.assertEqual(os.listdir(os.path.dirname(path)), ["x.json"])

    def test_a_failed_write_keeps_the_old_file(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "x.json")
        m.write_json_atomic(path, {"ok": True})
        with self.assertRaises(TypeError):
            m.write_json_atomic(path, {"bad": object()})
        with open(path) as f:
            self.assertEqual(json.load(f), {"ok": True})

    def test_the_manifests_the_settings_window_reads_are_written(self):
        cfg = os.path.join(tempfile.mkdtemp(), "config.json")
        real = m.CONFIG_PATH
        m.CONFIG_PATH = cfg
        self.addCleanup(lambda: setattr(m, "CONFIG_PATH", real))
        m.write_tool_manifest()
        for name in ("tools.json", "clicks.json", "pen_clicks.json"):
            with open(os.path.join(os.path.dirname(cfg), name)) as f:
                self.assertTrue(json.load(f), name)


class WorksHere(unittest.TestCase):
    """On GNOME, KDE and COSMIC the default ring leaves out the tools that can't act there."""

    def setUp(self):
        saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(saved)))
        for k in ("DIAL_WM", "HYPRLAND_INSTANCE_SIGNATURE", "NIRI_SOCKET", "SWAYSOCK", "I3SOCK"):
            os.environ.pop(k, None)

    def names(self):
        return [t["name"] for t in m.default_tools(False)]

    def test_cosmic_has_no_window_tools_and_no_settings_without_its_window(self):
        os.environ["XDG_CURRENT_DESKTOP"] = "COSMIC"
        real = m.shutil.which
        m.shutil.which = lambda n, *a, **k: None if n == "redial-settings" else real(n, *a, **k)
        try:
            self.assertEqual(self.names(), ["Volume", "Scroll", "Undo", "Zoom", "Media"])
        finally:
            m.shutil.which = real

    def test_settings_stays_when_redial_settings_is_installed(self):
        os.environ["XDG_CURRENT_DESKTOP"] = "KDE"
        real = m.shutil.which
        m.shutil.which = lambda n, *a, **k: "/x" if n == "redial-settings" else real(n, *a, **k)
        try:
            self.assertIn("Settings", self.names())
            self.assertNotIn("Windows", self.names())
        finally:
            m.shutil.which = real

    def test_hyprland_keeps_the_whole_ring(self):
        os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "x"
        self.assertIn("Windows", self.names())
        self.assertIn("Settings", self.names())


class OverlaySocket(unittest.TestCase):
    """Without omarchy-shell, MenuUI writes its calls to redial-overlay's socket."""

    def setUp(self):
        real = (m.MenuStream.PATH, m.omarchy_shell)
        self.addCleanup(
            lambda: (setattr(m.MenuStream, "PATH", real[0]), setattr(m, "omarchy_shell", real[1]))
        )
        m.omarchy_shell = lambda: False

    def test_a_call_reaches_the_overlay(self):
        import socket

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "redial.sock")
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(path)
            srv.listen(1)
            got = []

            def serve():
                conn, _ = srv.accept()
                got.append(conn.recv(4096))
                conn.close()

            t = threading.Thread(target=serve)
            t.start()
            m.MenuStream.PATH = path
            ui = m.MenuUI()
            ui._call("highlight", "4")
            t.join(2)
            srv.close()
        self.assertTrue(ui.overlay)
        self.assertEqual(got, [b"highlight 4\n"])

    def test_no_overlay_running_is_not_an_error(self):
        m.MenuStream.PATH = "/nonexistent/redial.sock"
        ui = m.MenuUI()
        ui._call("close")
        self.assertFalse(ui.overlay)

    def test_the_overlay_leaves_levels_and_hints_to_notifications(self):
        self.assertFalse(m.overlay_draws_states())

    def gate(self, layout, face):
        doc = {"layout": layout, "face": face}
        with (
            unittest.mock.patch.object(m, "omarchy_shell", lambda: True),
            unittest.mock.patch.object(m, "live_config", lambda: doc),
            unittest.mock.patch.dict(os.environ, {"DIAL_MENU_LAYOUT": ""}),
        ):
            return m.overlay_draws_states()

    def test_states_go_to_the_overlay_for_every_language_layout(self):
        for layout in ("dial", "deck", "carousel", "toast"):
            for face in ("classic", "pie", "wheel"):
                self.assertTrue(self.gate(layout, face), (layout, face))

    def test_omarchy_layout_keeps_the_osd(self):
        self.assertFalse(self.gate("omarchy", "classic"))


class UinputKeys(unittest.TestCase):
    """Keys through the uinput keyboard, for desktops wtype can't type into."""

    def kb(self):
        kb = m.VirtualKeyboard()
        kb.sent = []
        kb._ensure = lambda: True
        kb._emit = lambda code, value: kb.sent.append((code, value))
        return kb

    def test_every_built_in_key_name_has_a_code(self):
        kb = self.kb()
        names = "ctrl shift z 0 Page_Down Page_Up BackSpace Return Escape space Tab Left Up F12"
        for name in names.split():
            self.assertIsNotNone(kb.codes([name]), name)

    def test_combo_presses_in_order_and_releases_in_reverse(self):
        kb = self.kb()
        self.assertTrue(kb.combo(["ctrl", "z"]))
        self.assertEqual(kb.sent, [(29, 1), (44, 1), (44, 0), (29, 0)])

    def test_uppercase_letter_adds_shift(self):
        self.assertEqual(self.kb().codes(["A"]), [42, 30])

    def test_unknown_name_is_not_sent_so_wtype_can_try(self):
        kb = self.kb()
        self.assertFalse(kb.combo(["ctrl", "XF86Launch5"]))
        self.assertEqual(kb.sent, [])

    def test_keycodes_match_the_kernel_table(self):
        k = m.VirtualKeyboard.KEYS
        self.assertEqual((k["F1"], k["F10"], k["F11"], k["F13"], k["F24"]), (59, 68, 87, 183, 194))
        self.assertEqual((k["1"], k["0"], k["q"], k["m"]), (2, 11, 16, 50))

    def test_desktops_without_a_backend_use_uinput(self):
        saved = dict(os.environ)
        try:
            for k in ("DIAL_WM", "HYPRLAND_INSTANCE_SIGNATURE", "DIAL_KEYS"):
                os.environ.pop(k, None)
            os.environ["XDG_CURRENT_DESKTOP"] = "KDE"
            self.assertTrue(m.uinput_keys())
            os.environ["DIAL_KEYS"] = "wtype"
            self.assertFalse(m.uinput_keys())
        finally:
            os.environ.clear()
            os.environ.update(saved)


class WindowManagerBackends(unittest.TestCase):
    """Tools say what to do; the backend says how for the running compositor."""

    def setUp(self):
        self.ran = []
        self.real_run = m.run
        m.run = lambda cmd: self.ran.append(list(cmd))
        self.addCleanup(lambda: setattr(m, "run", self.real_run))

    def detect(self, **env):
        return m.detect_backend(env)

    def test_detection_follows_the_session(self):
        self.assertEqual(self.detect(HYPRLAND_INSTANCE_SIGNATURE="x").name, "hyprland")
        self.assertEqual(self.detect(SWAYSOCK="/run/sway").name, "sway")
        self.assertEqual(self.detect(I3SOCK="/run/i3").name, "i3")
        self.assertEqual(self.detect(NIRI_SOCKET="/run/niri").name, "niri")

    def test_hyprland_is_the_default_and_other_desktops_get_the_no_op(self):
        self.assertEqual(self.detect().name, "hyprland")
        for de in ("GNOME", "KDE", "ubuntu:GNOME", "XFCE"):
            b = self.detect(XDG_CURRENT_DESKTOP=de)
            self.assertFalse(b.supported, de)

    def test_the_override_beats_detection(self):
        self.assertEqual(self.detect(DIAL_WM="niri", SWAYSOCK="/s").name, "niri")
        self.assertEqual(self.detect(DIAL_WM="none", SWAYSOCK="/s").name, "none")
        self.assertEqual(self.detect(DIAL_WM="bogus", SWAYSOCK="/s").name, "sway")

    def test_hyprland_renders_exactly_what_the_tools_always_sent(self):
        sent = []
        real = m.hypr
        m.hypr = sent.append
        self.addCleanup(lambda: setattr(m, "hypr", real))
        b = m.HyprlandBackend()
        b.op("cycle", forward=True)
        b.op("cycle", forward=False)
        b.op("focus", dir="l")
        b.op("workspace", to="previous")
        b.op("send", to="-1")
        b.op("swap", forward=False)
        b.op("maximize")
        b.op("fullscreen")
        b.op("float")
        self.assertEqual(
            sent,
            [
                "hl.dsp.window.cycle_next()",
                "hl.dsp.window.cycle_next({ next = false })",
                'hl.dsp.focus({ direction = "l" })',
                'hl.dsp.focus({ workspace = "previous" })',
                'hl.dsp.window.move({ workspace = "-1" })',
                "hl.dsp.window.swap({ prev = true })",
                'hl.dsp.window.fullscreen({ mode = "maximized" })',
                'hl.dsp.window.fullscreen({ mode = "fullscreen" })',
                'hl.dsp.window.float({ action = "toggle" })',
            ],
        )

    def test_sway_commands(self):
        b = m.SwayBackend()
        b.op("cycle", forward=True)
        b.op("focus", dir="u")
        b.op("workspace", to="+1")
        b.op("workspace", to="previous")
        b.op("send", to="-1")
        b.op("float")
        b.op("resize", axis="y", grow=False, step=40)
        self.assertEqual(
            self.ran,
            [
                ["swaymsg", "focus", "next"],
                ["swaymsg", "focus", "up"],
                ["swaymsg", "workspace", "next_on_output"],
                ["swaymsg", "workspace", "back_and_forth"],
                ["swaymsg", "move", "container", "to", "workspace", "prev_on_output"],
                ["swaymsg", "floating", "toggle"],
                ["swaymsg", "resize", "shrink", "height", "40", "px"],
            ],
        )

    def test_i3_uses_its_own_tool(self):
        m.SwayBackend("i3-msg").op("float")
        self.assertEqual(self.ran, [["i3-msg", "floating", "toggle"]])

    def test_niri_commands(self):
        b = m.NiriBackend()
        b.op("focus", dir="d")
        b.op("workspace", to="-1")
        b.op("send", to="+1")
        b.op("maximize")
        b.op("resize", axis="x", grow=True, step=40)
        self.assertEqual(
            self.ran,
            [
                ["niri", "msg", "action", "focus-window-down"],
                ["niri", "msg", "action", "focus-workspace-up"],
                ["niri", "msg", "action", "move-window-to-workspace-down"],
                ["niri", "msg", "action", "maximize-column"],
                ["niri", "msg", "action", "set-column-width", "+40"],
            ],
        )

    def test_every_op_a_tool_uses_has_an_entry_in_every_backend(self):
        used = set()

        def walk(x):
            if isinstance(x, dict):
                if x.get("do") == "wm":
                    used.add(x["op"])
                for v in x.values():
                    walk(v)
            elif isinstance(x, list):
                for v in x:
                    walk(v)

        walk(m.TOOL_LIBRARY)
        walk(m.CLICK_ACTIONS if hasattr(m, "CLICK_ACTIONS") else [])
        used.add("resize")
        self.assertTrue(used)
        for b in (m.SwayBackend(), m.NiriBackend()):
            for op in used:
                self.assertIn(op, b.table, f"{b.name} lacks {op}")

    def test_the_no_op_backend_logs_and_runs_nothing(self):
        m.Backend().op("float")
        self.assertEqual(self.ran, [])

    def test_a_wm_action_without_a_known_op_is_refused_at_load(self):
        self.assertIsNone(m._compile_wm({"do": "wm", "op": "teleport"}))

    def test_terminal_detection_by_app_id(self):
        b = m.SwayBackend()
        b.active = lambda: {"class": "Alacritty"}
        self.assertTrue(b.focused_is_terminal())
        b._seen = (0.0, "")
        b.active = lambda: {"class": "firefox"}
        self.assertFalse(b.focused_is_terminal())

    def test_sway_tree_walk_finds_the_focused_window(self):
        tree = {
            "nodes": [
                {
                    "nodes": [{"focused": False}],
                    "floating_nodes": [{"focused": True, "app_id": "x"}],
                }
            ]
        }
        self.assertEqual(m._swayish_tree_focused(tree)["app_id"], "x")
        self.assertEqual(m._swayish_tree_focused({}), {})


@unittest.skipIf(os.geteuid() == 0, "the installer refuses to run as root, as CI containers do")
@unittest.skipUnless(_git_checkout_available(), "needs a git checkout to build the installer")
class SelfInstaller(unittest.TestCase):
    """scripts/make-installer.sh + the single-file installer, run in a scratch HOME."""

    ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

    @classmethod
    def setUpClass(cls):
        cls.out = tempfile.mkdtemp()
        cls.installer = os.path.join(cls.out, "dial-installer.sh")
        r = subprocess.run(
            ["bash", os.path.join(cls.ROOT, "scripts", "make-installer.sh"), "HEAD", cls.installer],
            capture_output=True,
            text=True,
            cwd=cls.ROOT,
        )
        assert r.returncode == 0, r.stdout + r.stderr
        cls.version = m.__version__

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.stubs = tempfile.mkdtemp()
        self.log = os.path.join(self.stubs, "calls.log")
        for name, body in (
            ("sudo", "exit 0"),
            ("pkill", ""),
            ("pgrep", "exit 1"),
            ("sleep", ""),
            ("hyprctl", ""),
            ("omarchy-restart-shell", ""),
            ("omarchy-pkg-add", ""),
            ("omarchy-shell", 'case "$*" in *ping*) echo ok;; esac'),
        ):
            path = os.path.join(self.stubs, name)
            with open(path, "w") as f:
                f.write(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n{body}\n')
            os.chmod(path, 0o755)
        os.makedirs(os.path.join(self.home, ".config", "hypr"))
        with open(os.path.join(self.home, ".config", "hypr", "autostart.lua"), "w") as f:
            f.write("-- mine\n")
        self.env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin", "USER": "tester"}
        self.target = os.path.join(self.home, ".local/share/redial-beta", f"redial-{self.version}")

    def run_installer(self, *args, text="", path=None, installer=None):
        env = dict(self.env)
        if path is not None:
            env["PATH"] = path
        return subprocess.run(
            ["bash", installer or self.installer, *args],
            env=env,
            capture_output=True,
            text=True,
            input=text,
        )

    def exists(self, rel):
        return os.path.exists(os.path.join(self.home, rel))

    def test_it_is_one_file_a_few_hundred_kilobytes_with_a_checksum(self):
        size = os.path.getsize(self.installer)
        # small enough to attach to an email;
        # ~200 KB of it is basic's three OFL faces (Latin subsets)
        self.assertLess(size, 800_000)
        self.assertGreater(size, 20_000)
        r = subprocess.run(
            ["sha256sum", "-c", os.path.basename(self.installer) + ".sha256"],
            cwd=self.out,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_version_comes_from_the_release_inside_it(self):
        r = self.run_installer("--version")
        self.assertEqual(r.stdout.strip(), self.version)

    def test_extract_only_unpacks_everything_and_installs_nothing(self):
        r = self.run_installer("--extract-only")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for f in ("install.sh", "uninstall.sh", "BETA.md", "FEEDBACK.md", "SECURITY.md", "LICENSE"):
            self.assertTrue(os.path.exists(os.path.join(self.target, f)), f)
        self.assertFalse(self.exists(".local/bin/redial-hypr"))
        self.assertFalse(self.exists(".config/omarchy/plugins/redial"))
        self.assertIn("Unpacked only", r.stdout)
        self.assertNotIn("Before you continue", r.stdout)  # it stopped before the notice

    def test_it_refuses_to_run_as_root(self):
        with open(os.path.join(self.stubs, "id"), "w") as f:
            f.write("#!/bin/sh\necho 0\n")
        os.chmod(os.path.join(self.stubs, "id"), 0o755)
        r = self.run_installer("--extract-only")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not root", r.stderr)
        self.assertFalse(os.path.exists(self.target))

    def test_saying_no_at_the_notice_installs_nothing_and_says_how_to_continue(self):
        r = self.run_installer(text="n\nn\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Nothing was installed", r.stdout)
        self.assertFalse(self.exists(".local/bin/redial-hypr"))
        self.assertTrue(os.path.exists(os.path.join(self.target, "install.sh")))

    def test_the_notice_names_the_real_risks(self):
        r = self.run_installer(text="n\nn\n")
        for needle in ("BETA", "sudo", "input", "uninstall.sh", "sends nothing"):
            self.assertIn(needle, r.stdout)

    def test_yes_runs_the_installer_which_still_asks_its_own_questions(self):
        r = self.run_installer(text="n\ny\n" + "y\n" * 40)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.exists(".local/bin/redial-hypr"))
        self.assertTrue(self.exists(".config/omarchy/plugins/redial/DialMenu.qml"))
        # install.sh ran with its own plan and questions (not silently with -y)
        self.assertIn("For your user only, no sudo", r.stdout)
        self.assertIn("uninstall.sh", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.target, "uninstall.sh")))

    def test_unattended_installs_without_the_notice(self):
        r = self.run_installer("--unattended")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.exists(".local/bin/redial-hypr"))
        self.assertNotIn("I have read this", r.stdout)

    def test_the_kept_uninstaller_removes_what_the_installer_added(self):
        self.assertEqual(self.run_installer("--unattended").returncode, 0)
        r = subprocess.run(
            ["bash", os.path.join(self.target, "uninstall.sh"), "-y"],
            env=self.env,
            capture_output=True,
            text=True,
            input="",
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.exists(".local/bin/redial-hypr"))
        with open(os.path.join(self.home, ".config/hypr/autostart.lua")) as f:
            self.assertEqual(f.read(), "-- mine\n")

    def test_a_changed_payload_is_refused_before_anything_is_unpacked(self):
        with open(self.installer, "rb") as f:
            data = bytearray(f.read())
        pos = data.rindex(b"\n", 0, len(data) - 200) - 5  # inside the payload
        data[pos] = ord("A") if data[pos] != ord("A") else ord("B")
        bad = os.path.join(self.out, "bad.sh")
        with open(bad, "wb") as f:
            f.write(data)
        r = self.run_installer("--extract-only", installer=bad)
        self.assertEqual(r.returncode, 1)
        self.assertIn("checksum mismatch", r.stderr)
        self.assertFalse(os.path.exists(self.target))

    def test_a_truncated_file_is_refused(self):
        with open(self.installer) as f:
            text = f.read()
        cut = os.path.join(self.out, "cut.sh")
        with open(cut, "w") as f:
            f.write(
                text[: text.index("__PAYLOAD_BELOW__\n") + len("__PAYLOAD_BELOW__\n")] + "AAAA\n"
            )
        r = self.run_installer("--extract-only", installer=cut)
        self.assertEqual(r.returncode, 1)
        self.assertFalse(os.path.exists(self.target))

    def test_running_it_again_keeps_the_old_folder_aside(self):
        self.assertEqual(self.run_installer("--extract-only").returncode, 0)
        self.assertEqual(self.run_installer("--extract-only").returncode, 0)
        parent = os.path.dirname(self.target)
        names = os.listdir(parent)
        self.assertEqual(len(names), 2, names)
        self.assertTrue(any(".old-" in n for n in names))

    def test_a_machine_that_is_not_omarchy_is_told_so(self):
        # A PATH with only the plain tools the installer needs, and no hyprctl or omarchy-shell
        # (this machine's real /usr/bin has them).
        plain = tempfile.mkdtemp()
        for tool in (
            "bash tar base64 sha256sum awk mktemp id date cut tail rm mkdir mv sed cat less dirname"
        ).split():
            real = shutil_which(tool)
            if real:
                os.symlink(real, os.path.join(plain, tool))
        r = self.run_installer("--extract-only", path=plain)
        self.assertIn("does not look like an Omarchy", r.stdout)
        self.assertIn("https://omarchy.org", r.stdout)  # where to get it: it is not bundled

    def test_unknown_options_are_refused(self):
        self.assertEqual(self.run_installer("--nuke").returncode, 2)


class NewControls(Base):
    """The tools and click actions added for driving a whole session from the dial."""

    # v1 trimmed Word Nav, Arrow Keys and Window Size (still in the library) and added Settings
    ORIGINAL_DEFAULTS = [
        "Volume", "Windows", "Workspaces", "Scroll", "Undo", "Zoom",
        "Media", "Settings", "Brightness",
    ]  # fmt: skip
    NEW_TOOLS = ["Focus", "Tabs", "Text", "Pages", "Tile Focus", "Move Window"]

    def setUp(self):
        super().setUp()
        self.addCleanup(lambda: setattr(m, "hypr_json", self.real_hypr_json))
        self.real_hypr_json = m.hypr_json
        m.TOOLS = m.build_tools(m.TOOL_LIBRARY)  # these tests need the optional tools too

    def window(self, **kw):
        m.hypr_json = lambda what: kw

    def click_action(self, name):
        return m.make_action({a[0]: a[3] for a in m.CLICK_ACTIONS}[name])

    # --- terminal detection
    def test_a_terminal_is_recognised_by_its_tag_like_omarchy_does(self):
        self.window(tags=["default-opacity*", "terminal*"])
        self.assertTrue(m.focused_is_terminal())
        self.window(tags=["terminal"])
        self.assertTrue(m.focused_is_terminal())

    def test_other_windows_are_not_terminals(self):
        for w in ({"tags": ["default-opacity*"]}, {"tags": []}, {}, {"tags": ["terminal-like*"]}):
            self.window(**w)
            self.assertFalse(m.focused_is_terminal(), w)

    def test_a_failed_lookup_means_not_a_terminal(self):
        def boom(what):
            raise OSError("no compositor")

        m.hypr_json = boom
        self.assertFalse(m.focused_is_terminal())

    # --- keys that differ in a terminal
    def test_copy_and_paste_use_terminal_safe_keys_in_a_terminal(self):
        self.window(tags=["terminal*"])
        EVENTS.clear()
        self.click_action("copy")(1)
        self.click_action("paste")(1)
        self.assertEqual(EVENTS, ["KEY:ctrl+Insert", "KEY:shift+Insert"])  # never Ctrl+C there

    def test_copy_and_paste_use_the_normal_keys_elsewhere(self):
        self.window(tags=[])
        EVENTS.clear()
        self.click_action("copy")(1)
        self.click_action("paste")(1)
        self.assertEqual(EVENTS, ["KEY:ctrl+c", "KEY:ctrl+v"])

    def test_select_all_and_redo_do_nothing_in_a_terminal(self):
        self.window(tags=["terminal*"])
        EVENTS.clear()
        self.click_action("select_all")(1)
        self.click_action("redo")(1)
        self.assertEqual(EVENTS, [])

    def test_an_action_without_terminal_keys_never_asks_the_compositor(self):
        calls = []
        m.hypr_json = lambda what: calls.append(what) or {}
        self.click_action("cut")(1)
        self.assertEqual(calls, [])  # no per-press lookup when it isn't needed

    def test_bad_terminal_keys_are_ignored_not_fatal(self):
        act = m.make_action({"do": "key", "keys": ["a"], "terminal_keys": "nope"})
        self.window(tags=["terminal*"])
        EVENTS.clear()
        act(1)
        self.assertEqual(EVENTS, ["KEY:a"])

    # --- the click-action table
    def test_every_click_action_is_well_formed_and_compiles(self):
        names = [a[0] for a in m.CLICK_ACTIONS]
        self.assertEqual(len(names), len(set(names)), "duplicate action name")
        for name, label, desc, spec in m.CLICK_ACTIONS:
            self.assertTrue(label and desc, name)
            if name in ("tool", "none"):
                self.assertIsNone(spec)
            else:
                self.assertTrue(callable(m.make_action(spec)), name)

    def test_the_new_click_actions_exist(self):
        have = {a[0] for a in m.CLICK_ACTIONS}
        for want in ("launcher", "screenshot", "copy", "paste", "cut", "select_all", "redo",
                     "tab_next", "tab_prev", "fullscreen", "float"):  # fmt: skip
            self.assertIn(want, have)

    def test_nothing_destructive_was_added_as_a_click_option(self):
        have = {a[0] for a in m.CLICK_ACTIONS}
        self.assertNotIn("close", have)
        self.assertNotIn("close_window", have)

    # --- the tool library
    def test_brightness_joins_the_default_ring_only_with_a_backlight(self):
        self.assertIn("Brightness", [t["name"] for t in m.default_tools(True)])
        self.assertNotIn("Brightness", [t["name"] for t in m.default_tools(False)])

    def test_the_default_tool_set_is_exactly_what_it_was(self):
        self.assertEqual([t["name"] for t in m.DEFAULT_TOOLS], self.ORIGINAL_DEFAULTS)
        with open(self.cfg, "w") as f:
            json.dump({}, f)
        self.assertEqual([t["name"] for t in m.load_tools()], self.ORIGINAL_DEFAULTS)

    def test_the_new_tools_are_in_the_library_and_can_be_chosen(self):
        names = [t["name"] for t in m.TOOL_LIBRARY]
        for n in self.NEW_TOOLS:
            self.assertIn(n, names)
        with open(self.cfg, "w") as f:
            json.dump({"active_tools": ["Volume", "Focus", "Tile Focus"]}, f)
        self.assertEqual([t["name"] for t in m.load_tools()], ["Volume", "Focus", "Tile Focus"])

    def test_text_moves_then_a_click_selects_and_a_double_click_copies(self):
        d = m.Dial()
        d.tool = tool_index_all("Text")
        EVENTS.clear()
        d.on_rotate(60, 0.0)
        self.assertEqual(EVENTS, ["KEY:ctrl+Right"])
        self.assertEqual(m.click_choice("double", m.TOOLS[d.tool]), "copy")
        d._native_click(1.0)  # what Text's single click does
        EVENTS.clear()
        d.on_rotate(60, 2.0)
        self.assertEqual(EVENTS, ["KEY:ctrl+shift+Right"])

    def test_rings_saved_with_the_merged_tools_load_their_new_names_once(self):
        with open(self.cfg, "w") as f:
            json.dump({"active_tools": ["Volume", "Word Nav", "Select", "H Scroll", "Scroll"]}, f)
        self.assertEqual([t["name"] for t in m.load_tools()], ["Volume", "Text", "Scroll"])

    def test_every_new_tool_compiles(self):
        built = {t["name"]: t for t in m.build_tools(m.TOOL_LIBRARY)}
        for n in self.NEW_TOOLS:
            self.assertTrue(callable(built[n]["cw"]) and callable(built[n]["ccw"]), n)

    def test_focus_tool_sends_tab_and_shift_tab(self):
        d = m.Dial()
        d.tool = tool_index_all("Focus")
        EVENTS.clear()
        d.on_rotate(60, 0.0)
        d.on_rotate(-60, 1.0)
        self.assertEqual(EVENTS, ["KEY:Tab", "KEY:shift+Tab"])

    def test_tile_focus_flips_between_left_right_and_up_down(self):
        d = m.Dial()
        d.tool = tool_index_all("Tile Focus")
        EVENTS.clear()
        d.on_rotate(60, 0.0)
        d.arrow_horizontal = True  # the click toggles this
        d.on_rotate(60, 1.0)
        self.assertEqual(
            EVENTS,
            ['HYPR:hl.dsp.focus({ direction = "r" })', 'HYPR:hl.dsp.focus({ direction = "d" })'],
        )


class FlowFixes(Base):
    """v1 fixes found by walking the user flows (docs: the interaction map)."""

    def test_settings_tool_opens_the_window_when_picked(self):
        d = m.Dial()
        d._arm(tool_index("Settings"), 0.0)
        self.assertIn("EXEC:omarchy-shell -q", EVENTS)

    def test_settings_tool_drives_the_window_while_it_is_open(self):
        d = m.Dial()
        d.tool = tool_index("Settings")
        d.on_rotate(200, 0.0)
        self.assertIn("KEY:Tab", EVENTS)
        self.assertEqual(self.gesture(1, tool_index("Settings")), ["KEY:Return"])

    def test_settings_tool_never_types_into_another_app(self):
        m.settings_window_focused = lambda: False
        focus = 'HYPR:hl.dsp.focus({ window = "title:^re:dial settings$" })'
        self.assertEqual(self.gesture(1, tool_index("Settings")), ["EXEC:omarchy-shell -q", focus])
        EVENTS.clear()
        d = m.Dial()
        d.tool = tool_index("Settings")
        d.on_rotate(200, 0.0)
        self.assertNotIn("KEY:Tab", EVENTS)
        self.assertIn("EXEC:omarchy-shell -q", EVENTS)

    def test_settings_keys_need_the_settings_window_focused(self):
        focused = PRISTINE["settings_window_focused"]
        for win, want in (
            ({"class": "org.quickshell", "title": "re:dial settings"}, True),
            ({"class": "firefox", "title": "re:dial settings"}, False),  # a web page with the name
            ({"class": "org.quickshell", "title": "Omarchy shell – dev gallery"}, False),
            (None, False),
        ):
            m.hypr_json = lambda what, _w=win: _w
            self.assertEqual(focused(), want, win)

    def test_cycling_windows_says_where_you_landed(self):
        m.backend = lambda: types.SimpleNamespace(op=lambda *a, **k: None)
        self.addCleanup(lambda: setattr(m, "backend", PRISTINE["backend"]))
        shown = []
        m.show_level = shown.append
        m.make_action({"do": "wm", "op": "cycle", "forward": True})(1)
        m.make_action({"do": "wm", "op": "workspace", "to": "+1"})(1)
        self.assertEqual(shown, ["window"])

    def test_a_turn_note_can_carry_text_without_a_level(self):
        sent = []
        m.overlay_note = lambda kind, doc: sent.append(doc) or True
        m.turn_note("Windows", None, "foot  notes")
        self.assertEqual(sent[0]["valueText"], "foot  notes")
        self.assertNotIn("value", sent[0])

    def test_scroll_pauses_over_claude_code_in_a_plain_terminal(self):
        m.focused_class = lambda: "foot"
        m.focused_runs_suppressed_program = PRISTINE["focused_runs_suppressed_program"]
        m.backend = lambda: m.HyprlandBackend()
        m.hypr_json = lambda what: {"pid": 4242}
        m._descendant_names = lambda pid: {"bash", "claude"} if pid == 4242 else set()
        m.cant_note = lambda *a: None
        m._tree_cache.update(at=0.0, pid=None, hit=None)
        self.assertEqual(m.scroll_mode(), "suppress")
        m._descendant_names = lambda pid: {"bash", "nvim"}
        m._tree_cache.update(at=0.0, pid=None, hit=None)
        self.assertEqual(m.scroll_mode(), "wheel")

    def test_undo_sends_nothing_in_a_terminal_and_says_why(self):
        cants = []
        m.cant_note = lambda *a: cants.append(a)
        m.focused_is_terminal = lambda: True
        m._term_warned["at"] = -1e9
        d = m.Dial()
        d.tool = tool_index("Undo")
        d.on_rotate(-400, 0.0)
        self.assertFalse([e for e in EVENTS if e.startswith("KEY:")])
        self.assertEqual(len(cants), 1)
        m.focused_is_terminal = lambda: False
        d.on_rotate(-400, 1.0)
        self.assertIn("KEY:ctrl+z", EVENTS)

    def test_the_microphone_can_be_muted_from_a_click(self):
        self.assertIn("mic_mute", {a[0] for a in m.CLICK_ACTIONS})

    def test_descendants_are_read_from_proc(self):
        names = PRISTINE["_descendant_names"](os.getppid())
        with open("/proc/self/comm") as f:  # "coverage" under CI, "python3" locally
            self.assertIn(f.read().strip(), names)


class SettingsSchema(unittest.TestCase):
    """plugin/redial/schema.json lists every setting, so the Every setting page shows them all."""

    ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

    def setUp(self):
        with open(os.path.join(self.ROOT, "plugin/redial/schema.json")) as f:
            self.rows = {i["key"]: i for g in json.load(f)["groups"] for i in g["items"]}
        with open(os.path.join(self.ROOT, "bin/redial-hypr")) as f:
            self.src = f.read()

    def test_every_documented_key_has_a_row(self):
        with open(os.path.join(self.ROOT, "plugin/redial/config.example.json")) as f:
            doc = json.load(f)

        def leaves(d, prefix=""):
            for k, v in d.items():
                if k.startswith("_"):
                    continue
                path = prefix + k
                if isinstance(v, dict) and path not in self.rows:
                    yield from leaves(v, path + ".")
                else:
                    yield path

        missing = [k for k in leaves(doc) if k not in self.rows]
        self.assertEqual(missing, [])

    def test_every_key_the_daemon_reads_has_a_row(self):
        read = set(re.findall(r'live_(?:num|bool)\("([a-z_]+)"', self.src))
        read |= set(re.findall(r'live_config\(\)\.get\("([a-z_]+)"', self.src))
        self.assertTrue({"sensitivity", "osd", "tool_return_s"} <= read)
        self.assertEqual(sorted(read - set(self.rows)), [])

    def test_ranges_match_the_daemon_clamps(self):
        for key, lo, hi in re.findall(
            r'live_num\("([a-z_]+)", [^,]+, ([0-9.]+), ([0-9.]+)\)', self.src
        ):
            row = self.rows[key]
            self.assertEqual((row["min"], row["max"]), (float(lo), float(hi)), key)

    def test_rows_are_well_formed(self):
        kinds = {"bool", "number", "choice", "text", "json", "click", "language"}
        for key, row in self.rows.items():
            self.assertIn(row["type"], kinds, key)
            self.assertTrue(row["label"], key)
            if row["type"] == "number":
                self.assertLessEqual(row["min"], row["default"], key)
                self.assertLessEqual(row["default"], row["max"], key)
            if row["type"] == "choice" and row["default"] != "":
                self.assertIn(row["default"], [o["key"] for o in row["options"]], key)
            if row["type"] == "click":
                self.assertIn(
                    row["group"], ("dial", "pentail", "barrel", "barrelhold", "eraser"), key
                )

    def test_style_presets_start_from_the_defaults(self):
        # An untouched config must read as Normal, Medium and 96% on the Look page's Style block.
        with open(os.path.join(self.ROOT, "plugin/redial/StylePresets.js")) as f:
            js = f.read()
        normal = re.search(r'key: "normal".*?w: \{([^}]*)\}', js).group(1)
        for k, v in re.findall(r"(\w+): ([0-9.]+)", normal):
            self.assertEqual(float(v), self.rows["dial." + k]["default"], k)
        for k, v in re.findall(r'key: "(\w+)", label: "[^"]*", fallback: (true|false)', js):
            self.assertEqual(v == "true", self.rows["dial." + k]["default"], k)
        self.assertIn(f"key: {self.rows['plateOpacity']['default']:g},", js)
        self.assertIn(f"key: {self.rows['dial.barCount']['default']:d},", js)


def tool_index_all(name):
    return [t["name"] for t in m.TOOLS].index(name)


class DoctorUdevRule(unittest.TestCase):
    """redial-setup carries its own copy of the udev rule (it runs from ~/.local/bin, away from the
    release folder). That copy once drifted and lost the GROUP:= fix for the Vial haptics bug."""

    def rules(self, text):
        return [ln for ln in text.splitlines() if ln.startswith("KERNEL")]

    def test_the_doctor_installs_the_same_rule_the_release_ships(self):
        root = os.path.join(HERE, "..")
        shipped = open(os.path.join(root, "udev", "70-redial.rules")).read()
        doctor = open(os.path.join(root, "bin", "redial-setup")).read()
        embedded = doctor.split("<<'EOF'", 1)[1].split("\nEOF\n", 1)[0]
        self.assertEqual(self.rules(embedded), self.rules(shipped))
        self.assertIn('GROUP:="input"', doctor.split("<<'EOF'", 1)[0])  # and checks for the fix


class LanguageFiles(unittest.TestCase):
    """The shell can't resolve a sibling QML file used as a property type.

    (Basic looks drew an empty plate.)
    """

    def test_no_property_typed_as_a_sibling_qml_file(self):
        root = os.path.join(HERE, "..", "plugin", "redial", "languages")
        for lang in sorted(os.listdir(root)):
            folder = os.path.join(root, lang)
            if not os.path.isdir(folder):
                continue
            names = [f[:-4] for f in os.listdir(folder) if f.endswith(".qml")]
            pattern = re.compile(r"\bproperty\s+({})\b".format("|".join(map(re.escape, names))))
            for f in names:
                with open(os.path.join(folder, f + ".qml")) as fh:
                    hit = pattern.search(fh.read())
                self.assertIsNone(hit, f"{lang}/{f}.qml types a property as {hit and hit.group(1)}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
