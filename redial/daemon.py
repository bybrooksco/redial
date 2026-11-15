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
import os
import fcntl
import queue
import re
from collections import deque
import select
import shutil
import signal
import socket
import struct
import json
import math
import subprocess
import sys
import threading
import time

from . import __version__
from .cli import parse_args, reset_guide_file  # noqa: F401  (tests reach them through here)
from .paths import CONFIG_PATH
from .log import LOG_PATH, log, debug
from .config import (
    load_config,
    cfg_str,
    MENU_ANCHOR,
    MENU_LAYOUT,
    ANCHORS,
    ACK_QUIET_S,
    WATCH_SAFETY_S,
    OPEN_RETRY_S,
    OPEN_RETRY_MAX,
    DROP_IN_USE_S,
    REATTACH_PAUSE_S,
    READING_RETURN_S,
    SPEED_WINDOW,
    MAG_FALLOFF,
    MAG_MAX,
    HAPTIC_WAVEFORM,
    HAPTIC_MIN_GAP,
    KEEP_AWAKE_S,
    KEEP_AWAKE_MINUTES,
    SCREEN_LOCKERS,
    HAPTIC_NONE,
    STALL_HOLD_S,
    STALL_KICK_GAP_S,
    PAT_TICK,
    PAT_MENU,
    PAT_SELECT,
    PAT_IDLE,
    PAT_DICTATION,
    SCROLL_GAIN,
    POINTER_GAIN,
    POINTER_ACCEL_COUNTS,
    POINTER_ACCEL_MAX,
    MAX_LAUNCHERS,
    SCROLL_TICK,
    ZOOM_GAIN,
    RESIZE_STEP,
    RESIZE_EDGE_SLACK,
    SEEK_STEP_S,
    BRIGHT_STEP,
    BRIGHT_MIN,
    live_config,
    _pen_section,
    live_derived,
    live_num,
    live_bool,
    disarm_after,
    sensitivity,
    double_window,
    hold_time,
    return_buzz,
    osd_enabled,
    deadzone,
    DEADZONE_REST_S,
    menu_latch,
    menu_idle_timeout,
    menu_step,
)

DEVICE_NAME = "Surface Dial System Multi Axis"
STYLUS_NAME = "Surface Touch Device Stylus"
PEN_KBD_NAME = "Surface Pen Keyboard"

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

# Wheel scroll breaks only where an app opts into alt-scroll (DECSET 1007) and binds the
# resulting arrows destructively (Claude Code). See docs/DESIGN.md#scroll-routing.
SCROLL_SUPPRESS_CLASSES = {
    "org.omarchy.agent",  # Claude Code -- Up/Down there is prompt history.
}

# The same apps run inside an ordinary terminal (foot > bash > claude), where the class is just
# "foot"; the focused window's process tree tells them apart.
SCROLL_SUPPRESS_PROGRAMS = {"claude"}

_scroll_warned_class = None
_tree_cache = {"at": 0.0, "pid": None, "hit": None}


def _descendant_names(pid):
    """Program names (comm) of every process under `pid`, read from /proc."""
    kids = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        # comm sits in parentheses and may hold spaces; ppid is the 2nd field after it
        comm, rest = stat[stat.find("(") + 1 : stat.rfind(")")], stat[stat.rfind(")") + 2 :].split()
        kids.setdefault(int(rest[1]), []).append((int(d), comm))
    names, todo = set(), [pid]
    while todo:
        for child, comm in kids.get(todo.pop(), []):
            names.add(comm)
            todo.append(child)
    return names


def focused_runs_suppressed_program():
    """The focused window is a terminal running one of SCROLL_SUPPRESS_PROGRAMS (cached 2 s)."""
    if not isinstance(backend(), HyprlandBackend):
        return None
    try:
        pid = int((hypr_json("activewindow") or {}).get("pid") or 0)
    except (*HYPR_ERRORS, TypeError, ValueError):
        return None
    now = time.monotonic()
    if pid != _tree_cache["pid"] or now - _tree_cache["at"] > 2.0:
        hit = (
            next(iter(_descendant_names(pid) & SCROLL_SUPPRESS_PROGRAMS), None) if pid > 0 else None
        )
        _tree_cache.update(at=now, pid=pid, hit=hit)
    return _tree_cache["hit"]


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


HID_ID = "091B"  # Microsoft Surface Dial product id

EV_FORMAT = "llHHi"
EV_SIZE = struct.calcsize(EV_FORMAT)
EV_KEY, EV_REL = 0x01, 0x02
REL_DIAL, BTN_0 = 0x07, 0x100
BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS = 0x141, 0x14A, 0x14B
EV_ABS = 0x03
ABS_X, ABS_Y = 0x00, 0x01


class Actions:
    """Runs tool actions off the input thread, one at a time, in order.

    An action is a subprocess or a Hyprland query; run on the thread that reads the dial it
    stalls rotation for as long as it takes. A single worker keeps strict ordering (a
    resize's read-then-dispatch stays sequential) and contains any exception an action
    raises, which used to propagate out of the read loop. `inline` runs actions on the
    caller's thread instead; the tests use it so they can assert straight after a gesture.
    """

    def __init__(self):
        self.inline = False
        self.q = queue.Queue(maxsize=64)
        self._started = False

    def submit(self, fn, *args):
        if self.inline:
            fn(*args)
            return
        if not self._started:
            self._started = True
            threading.Thread(target=self._worker, daemon=True).start()
        try:
            self.q.put_nowait((fn, args))
        except queue.Full:
            log("action queue full; dropped one")

    def _worker(self):
        while True:
            fn, args = self.q.get()
            try:
                fn(*args)
            except Exception as exc:
                log(f"action failed: {exc}")


ACTIONS = Actions()


def single_instance(path=None):
    """Hold the daemon's lock for as long as it runs; False when another daemon already holds it.

    Two daemons would both read the dial, so every turn would act twice. The lock dies with the
    process, so a crash never leaves it stuck."""
    if getattr(single_instance, "fd", None) is not None and path is None:
        return True  # this process already holds it
    if path is None:
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        path = os.path.join(runtime, "redial.lock") if runtime else LOG_PATH + ".lock"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    single_instance.fd = fd  # kept open (and locked) until the process ends
    return True


def make_private():
    """Keep the daemon's own files readable by this user only.

    The log can name windows and the config can name programs; there is no reason for another
    account on the machine to read either. New files get 0600 through the umask; files and
    folders made by earlier versions are tightened once, here. Best effort.
    """
    os.umask(0o077)
    state = os.path.dirname(LOG_PATH)
    config = os.path.dirname(CONFIG_PATH)
    for path, mode in [(state, 0o700), (config, 0o700)] + [
        (os.path.join(d, n), 0o600)
        for d in (state, config)
        if os.path.isdir(d)
        for n in os.listdir(d)
        if os.path.isfile(os.path.join(d, n))
    ]:
        try:
            if os.path.exists(path):
                os.chmod(path, mode)
        except OSError:
            pass


def write_json_atomic(path, doc, **dump_kw):
    """Write `doc` as JSON so a reader (the settings window, the shell) never sees half a file.

    Writes a temp file beside it, then renames. Raises OSError; callers decide how much it matters.
    """
    tmp = f"{path}.{os.getpid()}.tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, **dump_kw)
    os.replace(tmp, path)


def launch(cmd):
    """Start a program and leave it running; never wait for it or kill it.

    For things the user opens (launchers, the assistant), which may stay open for hours. run()
    waits for the command and kills it after 5 s, and it holds the one action worker meanwhile,
    which is right for short commands whose output we check and wrong here.
    """
    try:
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        log(f"{cmd[0]} could not start: {exc}")
        return
    threading.Thread(target=p.wait, daemon=True).start()  # reap it when it exits


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except Exception as exc:
        log(f"{cmd[0]} raised {exc}")
        return
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    # hyprctl exits 0 even when its Lua dispatcher fails -- check the text.
    if p.returncode != 0 or out.lower().startswith("error"):
        log(f"{cmd[0]} failed: {out[:200]}")
        return False
    return True


def hypr(lua):
    """Dispatch a Hyprland Lua dispatcher expression.

    Omarchy 4 / Hyprland 0.56 replaced string dispatchers ("cyclenext",
    "workspace e+1") with a Lua API; the old form is parsed as Lua and fails.
    Reference: /usr/share/omarchy/default/hypr/bindings/
    """
    run(["hyprctl", "dispatch", lua])


def resize_active(axis, grow, step=RESIZE_STEP):
    """Grow or shrink the focused window by `step` px along one axis.

    Hyprland's relative resize acts on the edge that touches a neighbour, so on
    a tiled window a positive delta SHRINKS one that is pinned to the right (or
    bottom) monitor edge -- measured 2026-09-20: x=+40 took the right-hand of two
    tiled windows from 760 to 720 wide. Left alone, "clockwise = bigger" would
    flip depending on where the window happens to sit, so point the delta at
    the edge that actually has a neighbour. Floating windows always resize from
    the bottom-right corner; a fullscreen window has nothing to resize.
    """

    try:
        w = hypr_json("activewindow")
        if not w or w.get("fullscreen"):
            return
        delta = step if grow else -step
        if not w.get("floating"):
            mon = next(
                (m for m in hypr_json("monitors") or [] if m.get("id") == w.get("monitor")), None
            )
            if mon:
                scale = mon.get("scale") or 1
                (ax, ay), (sw, sh) = w["at"], w["size"]
                if axis == "x":
                    pinned = ax + sw >= mon["x"] + mon["width"] / scale - RESIZE_EDGE_SLACK
                else:
                    pinned = ay + sh >= mon["y"] + mon["height"] / scale - RESIZE_EDGE_SLACK
                if pinned:
                    delta = -delta
    except Exception as exc:
        log(f"resize: could not read window/monitor state: {exc}")
        return
    dx, dy = (delta, 0) if axis == "x" else (0, delta)
    hypr(f"hl.dsp.window.resize({{ x = {dx}, y = {dy}, relative = true }})")


_media = {"at": 0.0, "pick": None, "last": None}
_seek_warned = 0.0


def _media_rows():
    """[(instance, status)] for every MPRIS player, in playerctl's order.

    [] when none or no playerctl."""
    try:
        p = subprocess.run(
            ["playerctl", "-a", "metadata", "--format", "{{playerInstance}}\t{{status}}"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [tuple(ln.split("\t")[:2]) for ln in p.stdout.splitlines() if "\t" in ln]


def pick_player(rows, last):
    """The one player the Media tool works on, for turning, clicking and the readout alike.

    By full instance ("firefox.instance_1_68"), never by app name: `-p firefox` means whichever
    Firefox player playerctl lists first, which is how a scrub or a click landed on another tab.
    A playing player wins; among several, the one re:dial last worked on. With nothing playing,
    the one it last worked on (so a click resumes what it paused), else the first paused one.
    """
    names = [r[0] for r in rows]
    playing = [r[0] for r in rows if r[1] == "Playing"]
    if playing:
        return last if last in playing else playing[0]
    if last in names:
        return last
    return next((r[0] for r in rows if r[1] == "Paused"), names[0] if names else None)


def media_player(fresh=False):
    """pick_player() over the live players. Cached briefly: a fast spin fires several detents a
    second and asking playerctl costs a subprocess."""
    now = time.monotonic()
    if fresh or now - _media["at"] >= 2.0:
        _media.update(at=now, pick=pick_player(_media_rows(), _media["last"]))
    return _media["pick"]


def _playerctl(player, *args):
    p = subprocess.run(
        ["playerctl", *(["-p", player] if player else []), *args],
        capture_output=True,
        text=True,
        timeout=3,
    )
    if player:
        _media["last"] = player
    return p


def media_command(op):
    """Play/pause, next or previous on the same player the Media tool scrubs."""
    try:
        _playerctl(media_player(fresh=True), op)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"{op} raised {exc}")
    _media["at"] = 0.0  # its status just changed


def media_reading(player):
    """(percent or None, "1:23 / 4:56  title") for the overlay, or None when nothing answers."""
    if not player:
        return None
    try:
        p = _playerctl(
            player, "metadata", "--format", "{{position}}\t{{mpris:length}}\t{{xesam:title}}"
        )
    except (OSError, subprocess.SubprocessError):
        return None
    parts = (p.stdout.strip().split("\t") + ["", "", ""])[:3]

    def clock(us):
        s = int(us) // 1_000_000
        return (
            f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}"
            if s >= 3600
            else f"{s // 60}:{s % 60:02d}"
        )

    try:
        pos, length = int(parts[0] or 0), int(parts[1] or 0)
    except ValueError:
        return None
    title = parts[2][:40]
    if length <= 0:
        return None, title or player.split(".")[0]
    return round(100 * pos / length), f"{clock(pos)} / {clock(length)}  {title}".strip()


def seek_media(forward, mag=1, step=SEEK_STEP_S):
    """Scrub the Media tool's player by `step` seconds, doubled per speed step.

    Uses MPRIS through playerctl, so it moves a song, a Jellyfin/browser video, VLC or anything
    else that reports a position. Failures (nothing playing, a player that can't seek) are logged
    at most every 5 s -- a spin fires many detents -- and said on screen once.
    """
    global _seek_warned
    secs = step * (2 ** (max(1, int(mag)) - 1))
    player = media_player()
    if player is None:
        if time.monotonic() - _seek_warned > 5:
            _seek_warned = time.monotonic()
            cant_note("tool", "Media can't act", "Nothing is playing")
        return
    try:
        p = _playerctl(player, "position", f"{secs:g}{'+' if forward else '-'}")
    except Exception as exc:
        log(f"seek raised {exc}")
        return
    if p.returncode != 0 and time.monotonic() - _seek_warned > 5:
        _seek_warned = time.monotonic()
        log(f"seek failed on {player}: {(p.stderr or p.stdout).strip()[:120]}")
        cant_note("tool", "Media can't scrub", f"{player.split('.')[0]} doesn't allow seeking")
        return
    show_level("media")


def uinput_keys():
    """True when keys go through the uinput keyboard instead of `wtype`.

    `wtype` needs the virtual-keyboard Wayland protocol, which GNOME lacks and KDE and COSMIC
    may not offer, so desktops on the no-op backend use uinput. Everywhere else `wtype` stays
    (it sends keysyms, so letters survive non-QWERTY layouts) unless it isn't installed.
    DIAL_KEYS=uinput|wtype overrides.
    """
    forced = os.environ.get("DIAL_KEYS", "").lower()
    if forced in ("uinput", "wtype"):
        return forced == "uinput"
    return backend().name == "none" or not shutil.which("wtype")


def key(*combo):
    if uinput_keys() and KEYBOARD.combo(combo):
        return
    args = ["wtype"]
    for mod in combo[:-1]:
        args += ["-M", mod]
    args += ["-k", combo[-1]]
    for mod in reversed(combo[:-1]):
        args += ["-m", mod]
    run(args)


# --- held modifier (ctrl+scroll zoom) ---
# One parked wtype process holds the modifier; killing it releases. Released on atexit and
# SIGTERM; after a SIGKILL run `pkill wtype`. See docs/DESIGN.md#held-modifier-zoom.
# On the uinput path the key is simply held down; the kernel releases it if the daemon dies.
_mod_proc = None
_mod_held = None  # modifier held down on the uinput keyboard


def press_mod(mod):
    global _mod_proc, _mod_held
    release_mod()
    if uinput_keys() and KEYBOARD.hold(mod, True):
        _mod_held = mod
        return
    try:
        _mod_proc = subprocess.Popen(["wtype", "-M", mod, "-s", "999999999"])
    except Exception as exc:
        log(f"press_mod({mod}) failed: {exc}")
        _mod_proc = None


def release_mod():
    global _mod_proc, _mod_held
    if _mod_held is not None:
        KEYBOARD.hold(_mod_held, False)
        _mod_held = None
    if _mod_proc is not None:
        try:
            _mod_proc.terminate()
            _mod_proc.wait(timeout=1)
        except (OSError, subprocess.SubprocessError):
            pass  # already gone, or slow to exit; either way we drop the handle
        _mod_proc = None


atexit.register(release_mod)
signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))


def omarchy_shell():
    """Whether Omarchy's shell (and so re:dial's own Omarchy overlay) is installed."""
    return shutil.which("omarchy-shell") is not None


class MenuUI:
    """Drives the redial Quickshell dashboard over Omarchy's shell IPC.

    Best-effort by design: the dial must keep working headless if the shell is
    restarting or the plugin is disabled, so every call is fire-and-forget and
    failures are logged, never raised. `-q` makes omarchy-shell exit 0 when the
    target is missing.
    """

    def __init__(self):
        self.open_now = False
        self.overlay = False  # redial-overlay took the last call (desktops without Omarchy)

    def _call(self, method, *args):
        if not omarchy_shell():
            self.overlay = self._send_overlay(method, *args)
            return
        try:
            subprocess.Popen(
                ["omarchy-shell", "-q", "dialmenu", method, *args],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            log(f"menu ui {method} failed: {e}")

    @staticmethod
    def _send_overlay(method, *args):
        """The same call as one line to redial-overlay's socket; False when it isn't running."""
        if not MenuStream.PATH:
            return False
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.25)
                s.connect(MenuStream.PATH)
                s.sendall((" ".join((method, *args)) + "\n").encode())
            return True
        except OSError:
            return False

    @staticmethod
    def _volume():
        """Current sink volume as a percent, or None if wpctl is unhappy."""
        try:
            out = subprocess.run(
                ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                capture_output=True,
                text=True,
                timeout=1,
            ).stdout
            m = re.search(r"([\d.]+)", out)
            if not m:
                return None
            pct = int(round(float(m.group(1)) * 100))
            return (0 if "MUTED" in out else pct), ("muted" if "MUTED" in out else f"{pct}%")
        except (OSError, subprocess.SubprocessError, ValueError):
            return None

    def _payload(self, index):
        # Re-read per open so config edits land without restarting the daemon.
        doc = load_config()
        anchor = os.environ.get("DIAL_MENU_ANCHOR") or cfg_str(doc, "anchor", MENU_ANCHOR, ANCHORS)
        layout = os.environ.get("DIAL_MENU_LAYOUT") or cfg_str(
            doc, "layout", MENU_LAYOUT, ("dial", "deck", "carousel", "toast", "omarchy")
        )
        vol = self._volume()
        tools = []
        for t in TOOLS:
            entry = {"icon": t["icon"], "name": t["name"], "hint": click_hint(t)}
            if t["name"] == "Volume" and vol is not None:
                entry["value"], entry["valueText"] = vol
            if t["name"] == "Brightness":
                pct = read_brightness()
                if pct is not None:
                    entry["value"], entry["valueText"] = pct, f"{pct}%"
            tools.append(entry)
        return json.dumps({"tools": tools, "index": index, "anchor": anchor, "layout": layout})

    def open(self, index):
        payload = self._payload(index)
        self.open_now = True
        self._call("open", payload)

    def highlight(self, index):
        # Reopening rather than highlighting keeps the live readout current;
        # `open` is idempotent on an already-open deck.
        if TOOLS[index]["name"] == "Volume":
            self.open_now = True
            self._call("open", self._payload(index))
            return
        if MENU_STREAM.sock is not None:
            # The position socket already drives the highlight; this per-detent call can
            # land late and flicker it, so skip it while the stream is live.
            # See docs/DESIGN.md#menu-highlight-alignment.
            return
        if not self.open_now:
            self.open(index)
            return
        self._call("highlight", str(index))

    def close(self):
        # Always send the close, even if we think it is shut: a stale overlay
        # left up by a crash or a restart is worse than a redundant IPC call.
        self.open_now = False
        self._call("close")


class MenuStream:
    """Unix-socket channel to the overlay, for continuous rotation.

    The dial emits ~100 rotation events a second. Each `omarchy-shell` call
    spawns a process, so the needle could only ever step per detent through
    that path. A socket carries the live position at rotation rate for
    essentially nothing. Open/close still go over IPC - they happen once.

    Entirely optional: if the overlay is not listening the dial keeps working,
    just without the continuous needle.
    """

    # No /tmp fallback: that directory is shared, so another local user could plant a socket
    # there. Without a private runtime directory the continuous needle is simply off.
    PATH = (
        os.path.join(os.environ["XDG_RUNTIME_DIR"], "redial.sock")
        if os.environ.get("XDG_RUNTIME_DIR")
        else None
    )
    MIN_INTERVAL = 0.012  # ~80Hz ceiling; the panel cannot use more
    RETRY_S = 2.0  # a note retries an overlay that was not listening at most this often
    TURN_INTERVAL = 0.1  # level readouts at most ~10 a second; the eye cannot use more

    def __init__(self):
        self.sock = None
        self.last = 0.0
        self.tried = -1e9
        self.last_turn = -1e9
        # The main thread, the action worker and the pen threads all write notes; without it one
        # thread's close() could land between another's None check and its send.
        self.lock = threading.RLock()

    def _send(self, data):
        """Send one line: True if all of it went, False if the overlay is behind (dropped whole).
        A partial write closes the socket, since half a line would glue onto the next one."""
        try:
            n = self.sock.send(data)
        except BlockingIOError:
            return False
        if n < len(data):
            self.close()
            return False
        return True

    def connect(self, quiet=False):
        with self.lock:
            self._connect(quiet)

    def _connect(self, quiet):
        self.close()
        if not self.PATH:
            return
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.25)
            s.connect(self.PATH)
            s.setblocking(False)
            self.sock = s
            self.last = 0.0
        except Exception as e:
            self.sock = None
            if not quiet:
                log(f"menu stream unavailable ({e}) - needle will step per detent")

    def pos(self, value, now):
        with self.lock:
            if self.sock is None or now - self.last < self.MIN_INTERVAL:
                return
            self.last = now
            try:
                self._send(f"pos {value:.4f}\n".encode())  # behind: dropping a frame is correct
            except Exception as e:
                log(f"menu stream write failed: {e}")
                self.close()

    def note(self, kind, doc):
        """Send one state ("turn", "hint", "cant") as `kind {json}`; True when the overlay took it.

        The note channel stays connected between notes. While nothing listens it retries at most
        every RETRY_S, so a missing overlay costs nothing per detent.
        """
        with self.lock:
            now = time.monotonic()
            if self.sock is None:
                if now - self.tried < self.RETRY_S:
                    return False
                self.tried = now
                self.connect(quiet=True)  # the lock is re-entrant
                if self.sock is None:
                    return False
            try:
                if not self._send(f"{kind} {json.dumps(doc)}\n".encode()):
                    return False  # the overlay is behind; the OSD shows this one
            except OSError as e:
                log(f"overlay note failed: {e}")
                self.close()
                return False
            if kind == "turn":
                self.last_turn = now
            return True

    def turn_wait(self):
        """Seconds until the next level readout may go to the overlay (0 when not connected)."""
        if self.sock is None:
            return 0.0
        return max(0.0, self.last_turn + self.TURN_INTERVAL - time.monotonic())

    def close(self):
        with self.lock:
            if self.sock is not None:
                try:
                    self.sock.close()
                except OSError:
                    pass
                self.sock = None


MENU_UI = MenuUI()
MENU_STREAM = MenuStream()  # the live needle while the ring is held
MENU_NOTES = MenuStream()  # turning, hints and can't-act, whenever the overlay listens


_notify_id = None  # id of our last notification, so the next one replaces it in place


def _notify_sync(title, body=""):
    """Show a short on-screen message.

    Uses Omarchy's own notifier (45 of its scripts do; `notify-send` is not in its base
    packages), replacing the previous message so quick toggles don't stack. Falls back to
    notify-send where Omarchy's isn't installed.
    """
    global _notify_id
    found = [n for n in ("omarchy-notification-send", "notify-send") if shutil.which(n)]
    if not found:
        return
    exe = found[0]
    cmd = [exe, "--app-name", "re:dial", "-t", "1100", "-p"]
    if exe == "notify-send":
        cmd += ["-h", "string:x-canonical-private-synchronous:redial"]
    if _notify_id:
        cmd += ["-r", _notify_id]
    cmd += [title, body] if body else [title]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except Exception as exc:
        log(f"{exe} raised {exc}")
        return
    lines = p.stdout.strip().splitlines()
    if p.returncode == 0 and lines and lines[-1].isdigit():
        _notify_id = lines[-1]


def notify(title, body=""):
    ACTIONS.submit(_notify_sync, title, body)


_speech = {"proc": None, "warned": False}


def speech_command():
    """The first available text-to-speech command as a list, or None."""
    for exe in ("spd-say", "espeak-ng", "espeak"):
        path = shutil.which(exe)
        if path:
            return [path]
    return None


def _speak_sync(text):
    prev = _speech["proc"]
    if prev is not None and prev.poll() is None:
        prev.terminate()  # a new announcement replaces the old one rather than queueing behind it
    cmd = speech_command()
    if cmd is None:
        if not _speech["warned"]:
            _speech["warned"] = True
            log("announce_tool is on but no speech tool was found (speech-dispatcher or espeak-ng)")
        return
    try:
        _speech["proc"] = subprocess.Popen(
            [*cmd, text], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except OSError as exc:
        log(f"speech failed ({exc})")


def speak(text):
    """Say `text` aloud if the "announce_tool" setting is on (off by default)."""
    if live_bool("announce_tool", False):
        ACTIONS.submit(_speak_sync, text)


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


class Haptics:
    """Fire motor clicks without blocking the input loop."""

    def __init__(self):
        self.q = queue.Queue(maxsize=8)
        self.path = None
        self.inst = None
        self.fd = None
        self.warned = False
        self.last = 0.0
        self.last_write = None  # monotonic time of the last report that reached the dial
        self.poke_ok = False
        threading.Thread(target=self._worker, daemon=True).start()

    @staticmethod
    def find_node():
        """Return (path, instance). The path is reused across reconnects but
        the uhid instance id is not, so it is the real identity."""
        base = "/sys/class/hidraw"
        try:
            names = os.listdir(base)
        except OSError:
            return (None, None)
        for name in names:
            try:
                with open(f"{base}/{name}/device/uevent") as fh:
                    if HID_ID not in fh.read().upper():
                        continue
                inst = os.path.basename(os.path.realpath(f"{base}/{name}/device"))
                return (f"/dev/{name}", inst)
            except OSError:
                continue
        return (None, None)

    def _open(self):
        path, inst = self.find_node()
        if path is None:
            return False
        if self.fd is not None and inst == self.inst:
            return True
        if self.fd is not None:  # same path, new device: reopen
            try:
                self.fd.close()
            except OSError:
                pass
            self.fd = None
        try:
            self.fd = open(path, "wb", buffering=0)
            self.path = path
            self.inst = inst
            log(f"haptics on {path}")
            self.warned = False
            return True
        except OSError as exc:
            if not self.warned:
                log(
                    f"haptics unavailable ({exc}) -- running silently. "
                    f"Needs write access to {path}."
                )
                self.warned = True
            self.fd = None
            return False

    def _fire(self, repeat, period, waveform=HAPTIC_WAVEFORM):
        try:
            self.fd.write(bytes([0x01, repeat, waveform, period & 0xFF, (period >> 8) & 0xFF]))
            self.last_write = time.monotonic()
            return True
        except OSError as exc:
            log(f"haptic write failed ({exc})")
            try:
                self.fd.close()
            except OSError:
                pass
            self.fd = None
            return False

    def _poke(self):
        """Keep-awake: a haptic report with waveform NONE.

        The dial counts it as use; the motor stays still.
        """
        if self._fire(0, 0, HAPTIC_NONE) and not self.poke_ok:
            log("keep-awake: first silent haptic sent")
            self.poke_ok = True

    def _worker(self):
        while True:
            pattern = self.q.get()
            if not self._open():
                continue
            if pattern is None:
                self._poke()
            else:
                self._fire(*pattern)

    def keep_awake(self):
        """Queue one silent keep-awake read (handled by the worker, which owns the fd)."""
        try:
            self.q.put_nowait(None)
        except queue.Full:
            pass

    def fire(self, pattern, rate_limit=True):
        """Queue one haptic pattern. A pattern is a single output report --
        the dial's firmware times the repeats, so nothing sleeps here."""
        now = time.monotonic()
        if rate_limit and now - self.last < HAPTIC_MIN_GAP:
            return  # too soon; this would smear into the last one
        self.last = now
        try:
            self.q.put_nowait(pattern)
        except queue.Full:
            pass


class VirtualPointer:
    """A uinput virtual mouse, used only for high-resolution wheel events.

    Arrow keys cannot scroll smoothly and follow keyboard FOCUS -- in a
    terminal they walk shell history instead of the scrollback. A real wheel
    event follows the POINTER and scrolls whatever is under it, continuously.
    REL_WHEEL_HI_RES uses 120 units per traditional wheel notch, so we can
    emit fractional notches and get smooth motion.
    """

    UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
    UI_DEV_CREATE = 0x5501
    EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
    REL_X, REL_Y, REL_WHEEL, REL_WHEEL_HI_RES = 0x00, 0x01, 0x08, 0x0B
    REL_HWHEEL, REL_HWHEEL_HI_RES = 0x06, 0x0C
    BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112

    def __init__(self):
        self.fd = None
        self.residual = 0.0
        self.residual_h = 0.0
        self.move_x = 0.0
        self.move_y = 0.0
        self.warned = False

    def _ensure(self):
        if self.fd is not None:
            return True
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if not self.warned:
                log(f"uinput unavailable ({exc}) -- scroll disabled")
                self.warned = True
            return False
        try:
            for ev in (self.EV_KEY, self.EV_REL, self.EV_SYN):
                fcntl.ioctl(fd, self.UI_SET_EVBIT, ev)
            for btn in (self.BTN_LEFT, self.BTN_RIGHT, self.BTN_MIDDLE):
                fcntl.ioctl(fd, self.UI_SET_KEYBIT, btn)
            for r in (
                self.REL_X,
                self.REL_Y,
                self.REL_WHEEL,
                self.REL_WHEEL_HI_RES,
                self.REL_HWHEEL,
                self.REL_HWHEEL_HI_RES,
            ):
                fcntl.ioctl(fd, self.UI_SET_RELBIT, r)
            name = b"re:dial Virtual Pointer".ljust(80, b"\0")
            dev = (
                name
                + struct.pack("HHHH", 0x0003, 0x045E, 0x091B, 1)
                + struct.pack("i", 0)
                + struct.pack("i" * 256, *([0] * 256))
            )
            os.write(fd, dev)
            fcntl.ioctl(fd, self.UI_DEV_CREATE)
        except OSError as exc:
            log(f"uinput setup failed ({exc})")
            os.close(fd)
            return False
        self.fd = fd
        log("virtual pointer created")
        return True

    def _emit(self, etype, code, value):
        os.write(self.fd, struct.pack(EV_FORMAT, 0, 0, etype, code, value))

    def click(self, button, down):
        if not self._ensure():
            return
        try:
            self._emit(self.EV_KEY, button, 1 if down else 0)
            self._emit(self.EV_SYN, 0, 0)
        except OSError as exc:
            log(f"pointer click failed ({exc})")
            self.fd = None

    def scroll(self, hi_res, horizontal=False):
        """hi_res: signed, 120 == one traditional wheel notch. horizontal: right is positive."""
        if not self._ensure():
            return
        fine, coarse = (
            (self.REL_HWHEEL_HI_RES, self.REL_HWHEEL)
            if horizontal
            else (self.REL_WHEEL_HI_RES, self.REL_WHEEL)
        )
        try:
            self._emit(self.EV_REL, fine, int(hi_res))
            # coarse notches for anything not handling hi-res
            if horizontal:
                self.residual_h += hi_res
                notches = int(self.residual_h / 120)
                self.residual_h -= notches * 120
            else:
                self.residual += hi_res
                notches = int(self.residual / 120)
                self.residual -= notches * 120
            if notches:
                self._emit(self.EV_REL, coarse, notches)
            self._emit(self.EV_SYN, 0, 0)
        except OSError as exc:
            log(f"pointer write failed ({exc})")
            self.fd = None

    def move(self, dx, dy):
        """Move the cursor by (dx, dy) pixels; fractions carry over to the next call."""
        if not self._ensure():
            return
        self.move_x += dx
        self.move_y += dy
        ix, iy = int(self.move_x), int(self.move_y)
        if not ix and not iy:
            return
        self.move_x -= ix
        self.move_y -= iy
        try:
            if ix:
                self._emit(self.EV_REL, self.REL_X, ix)
            if iy:
                self._emit(self.EV_REL, self.REL_Y, iy)
            self._emit(self.EV_SYN, 0, 0)
        except OSError as exc:
            log(f"pointer move failed ({exc})")
            self.fd = None


def _keycodes():
    """wtype key names -> Linux input keycodes (linux/input-event-codes.h)."""
    codes = {
        "Escape": 1, "minus": 12, "equal": 13, "BackSpace": 14, "Tab": 15, "Return": 28,
        "space": 57, "Caps_Lock": 58, "Home": 102, "Up": 103, "Page_Up": 104, "Left": 105,
        "Right": 106, "End": 107, "Down": 108, "Page_Down": 109, "Insert": 110, "Delete": 111,
        "XF86AudioMute": 113, "XF86AudioLowerVolume": 114, "XF86AudioRaiseVolume": 115,
        "XF86AudioNext": 163, "XF86AudioPlay": 164, "XF86AudioPrev": 165,
        "ctrl": 29, "shift": 42, "alt": 56, "logo": 125, "win": 125, "super": 125, "altgr": 100,
    }  # fmt: skip
    for row, first in (("1234567890", 2), ("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)):
        codes.update((c, first + i) for i, c in enumerate(row))
    codes.update((f"F{n}", 58 + n) for n in range(1, 11))
    codes.update(F11=87, F12=88)
    codes.update((f"F{n}", 183 + n - 13) for n in range(13, 25))
    return codes


class VirtualKeyboard:
    """A uinput keyboard for key actions where `wtype` can't type (see uinput_keys()).

    It sends keycodes, not keysyms, so letters follow the physical QWERTY position: on an AZERTY
    layout "z" types "w". Names it doesn't know return False, and key() falls back to `wtype`.
    Created at startup, like the pointer, so the compositor has added it before the first key.
    """

    KEYS = _keycodes()

    def __init__(self):
        self.fd = None
        self.warned = False

    def _ensure(self):
        if self.fd is not None:
            return True
        vp = VirtualPointer
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if not self.warned:
                log(f"uinput unavailable ({exc}) -- uinput keys disabled")
                self.warned = True
            return False
        try:
            for ev in (vp.EV_KEY, vp.EV_SYN):
                fcntl.ioctl(fd, vp.UI_SET_EVBIT, ev)
            for code in set(self.KEYS.values()):
                fcntl.ioctl(fd, vp.UI_SET_KEYBIT, code)
            name = b"re:dial Virtual Keyboard".ljust(80, b"\0")
            os.write(fd, name + struct.pack("HHHH", 0x0006, 0, 0, 1) + bytes(4 + 4 * 256))
            fcntl.ioctl(fd, vp.UI_DEV_CREATE)
        except OSError as exc:
            log(f"uinput keyboard setup failed ({exc})")
            os.close(fd)
            return False
        self.fd = fd
        log("virtual keyboard created")
        return True

    def _emit(self, code, value):
        os.write(self.fd, struct.pack(EV_FORMAT, 0, 0, EV_KEY, code, value))
        os.write(self.fd, struct.pack(EV_FORMAT, 0, 0, 0, 0, 0))  # EV_SYN

    def codes(self, combo):
        """The keycodes for a combo, an uppercase letter adding shift; None if any is unknown."""
        out = []
        for name in combo:
            if len(name) == 1 and name.isupper() and name.lower() in self.KEYS:
                out += [self.KEYS["shift"], self.KEYS[name.lower()]]
            elif name in self.KEYS:
                out.append(self.KEYS[name])
            else:
                return None
        return out

    def combo(self, combo):
        """Press the combo's keys in order and release them in reverse. False if not sent."""
        codes = self.codes(combo)
        if codes is None or not self._ensure():
            return False
        try:
            for c in codes:
                self._emit(c, 1)
            for c in reversed(codes):
                self._emit(c, 0)
        except OSError as exc:
            log(f"uinput key failed ({exc})")
            self.fd = None
            return False
        return True

    def hold(self, name, down):
        """Hold (down=True) or release one key. False if not sent."""
        if name not in self.KEYS or not self._ensure():
            return False
        try:
            self._emit(self.KEYS[name], 1 if down else 0)
        except OSError as exc:
            log(f"uinput key failed ({exc})")
            self.fd = None
            return False
        return True


HAPTIC = Haptics()
POINTER = VirtualPointer()
KEYBOARD = VirtualKeyboard()


def vol(mag, up):
    pct = f"{mag}%{'+' if up else '-'}"
    cmd = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", pct]
    if up:
        cmd += ["-l", "1.0"]
    run(cmd)
    show_level("volume")


def osd(icon="", message="", progress=None, duration=900):
    """Put something on screen with Omarchy's own on-screen display; best effort.

    Falls back to a notification where `omarchy-osd` is missing, so the dial is never silent.
    """
    if not osd_enabled():
        return
    exe = shutil.which("omarchy-osd")
    if not exe:
        if message:
            notify(message)
        return
    cmd = [exe, "-d", str(duration)]
    if icon:
        cmd += ["-i", icon]
    if progress is not None:
        cmd += ["-p", str(max(0, min(100, int(progress))))]
    elif message:
        cmd += ["-m", message]
    run(cmd)


_level_pending = set()


def show_level(kind):
    """Show the current volume or brightness on screen, once per burst of turning.

    The job reads the level when it runs, not when it was queued, so one waiting job always
    shows the latest value and a fast spin cannot back the action queue up with overlays.
    """
    if not osd_enabled() or kind in _level_pending:
        return
    _level_pending.add(kind)
    ACTIONS.submit(_show_level, kind)


def _show_level(kind):
    wait = MENU_NOTES.turn_wait()
    if wait > 0:  # the overlay takes ~10 readouts a second; this job reads the level when it fires
        threading.Timer(wait, ACTIONS.submit, (_show_level, kind)).start()
        return
    _level_pending.discard(kind)
    if kind == "volume":
        v = MenuUI._volume()
        if v is not None:
            pct, text = v
            if not turn_note("Volume", pct, text):
                osd(icon="volume-muted" if text == "muted" else "volume", progress=pct)
    elif kind == "media":
        r = media_reading(media_player())
        if r is not None and not turn_note("Media", r[0], r[1]):
            osd(message=f"\uf001  {r[1]}")
    elif kind == "window":
        label = window_label()
        if label and not turn_note("Windows", None, label):
            osd(message=label)
    elif kind == "brightness":
        pct = read_brightness()
        if pct is not None and not turn_note("Brightness", pct, f"{pct}%"):
            osd(icon="brightness", progress=pct)


def overlay_note(kind, doc):
    """Show a state ("turn", "hint" or "cant") on re:dial's own overlay.

    False when the overlay is not listening (or the on-screen display is off): the caller then
    uses Omarchy's OSD, so the dial is never quieter than before.
    """
    return osd_enabled() and overlay_draws_states() and MENU_NOTES.note(kind, doc)


def overlay_draws_states():
    """Whether the overlay's chosen look draws these states itself.

    Every language look does (dial faces, deck, carousel, toast); the omarchy layout is the
    shell's own OSD box and leaves them to Omarchy's OSD.
    """
    if not omarchy_shell():
        return False  # redial-overlay draws only the ring; levels and hints stay notifications
    doc = live_config()
    layout = os.environ.get("DIAL_MENU_LAYOUT") or cfg_str(doc, "layout", MENU_LAYOUT)
    return layout in ("dial", "deck", "carousel", "toast")


def turn_note(name, value=None, text=None):
    """A tool turning, for the overlay: its name and icon, and its level when it has one."""
    spec = next((t for t in TOOLS if t["name"] == name), None)
    doc = {
        "name": name,
        "icon": spec["icon"] if spec else "",
        "hint": click_hint(spec) if spec else "",
    }
    if value is not None:
        doc["value"] = value
    if text is not None:
        doc["valueText"] = text
    return overlay_note("turn", doc)


def cant_note(reason, title, line):
    """The dial cannot act; say why (reason: "asleep", "waiting" or "tool")."""
    if not overlay_note("cant", {"reason": reason, "title": title, "line": line}):
        osd(message=line)


def backlight_device():
    """Name of the first backlight device, or None (a desktop like the Studio has none).

    Always passed to brightnessctl explicitly: a bare call once grabbed the wrong LED
    on the Studio, and this laptop also has non-backlight LEDs (wifi, numlock).
    """
    try:
        names = sorted(os.listdir("/sys/class/backlight"))
    except OSError:
        return None
    return names[0] if names else None


def read_brightness(device=None):
    """Current backlight percent as an int, or None."""
    dev = device or backlight_device()
    if not dev:
        return None
    try:
        out = subprocess.run(
            ["brightnessctl", "-m", "-d", dev, "info"], capture_output=True, text=True, timeout=2
        ).stdout
        return int(out.strip().split(",")[3].rstrip("%"))
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


_bright_warned = False
_bright_said = [-1e9]  # when the "no backlight" message was last shown


def set_brightness(mag, up, step=BRIGHT_STEP, device=None):
    """Nudge the screen backlight by `step` percent x magnitude, clamped to 1..100."""
    global _bright_warned
    dev = device or backlight_device()
    cur = read_brightness(dev)
    if cur is None:
        if not _bright_warned:
            _bright_warned = True
            log("brightness: no readable backlight device on this machine")
        # Silence reads as a broken dial: say why nothing happened (at most every few seconds).
        if time.monotonic() - _bright_said[0] > 3.0:
            _bright_said[0] = time.monotonic()
            cant_note("tool", "Brightness can't act", "No screen backlight on this machine")
        return
    delta = int(step) * max(1, int(mag))
    new = max(BRIGHT_MIN, min(100, cur + (delta if up else -delta)))
    if new != cur:
        run(["brightnessctl", "-q", "-d", dev, "set", f"{new}%"])
    show_level("brightness")


def repeat_key(mag, *combo):
    for _ in range(mag):
        key(*combo)


# What hypr_json() and its callers can raise: no socket or hyprctl (OSError), a hung hyprctl
# (SubprocessError), unparseable output (ValueError), or a reply that is not an object.
HYPR_ERRORS = (OSError, subprocess.SubprocessError, ValueError, AttributeError)


def hypr_json(what):
    """Query Hyprland for `what` (activewindow, monitors, ...) and return the parsed JSON.

    Talks to Hyprland's own socket, which takes ~0.03 ms; `hyprctl` costs a process spawn
    (~3.6 ms) and this is called on every rotation event by the Scroll tool. Falls back to
    hyprctl if the socket is unavailable. Raises on failure.
    """
    sig, rt = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"), os.environ.get("XDG_RUNTIME_DIR")
    if sig and rt:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.5)
                s.connect(os.path.join(rt, "hypr", sig, ".socket.sock"))
                s.sendall(f"j/{what}".encode())
                chunks = []
                while chunk := s.recv(65536):
                    chunks.append(chunk)
            return json.loads(b"".join(chunks) or b"null")
        except (OSError, ValueError):
            pass
    p = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True, timeout=2)
    return json.loads(p.stdout or "null")


# --- window-manager backends -------------------------------------------------------------
#
# Tools say WHAT to do ({"do": "wm", "op": "workspace", "to": "+1"}); a backend says HOW for the
# compositor that is running. The dial itself (reading the device, haptics, volume, brightness,
# media, keys and scroll through the virtual input device) does not depend on any of this.
#
# Ops: cycle(forward) focus(dir l|r|u|d) workspace(to "+1"|"-1"|"previous") send(to "+1"|"-1")
#      swap(forward) maximize fullscreen float resize(axis x|y, grow, step)
# plus two queries: focused_class() and focused_is_terminal().
#
# Hyprland is the reference backend and renders exactly what the tools always sent. Sway, i3 and
# niri are built from their documented command lines. Anything else gets NoBackend, which says
# once that window tools are unavailable and leaves everything else working.

FOCUS_CACHE_S = 0.15

TERMINAL_APP_IDS = {
    "alacritty", "kitty", "foot", "footclient", "wezterm", "org.wezfurlong.wezterm", "ghostty",
    "com.mitchellh.ghostty", "xterm", "urxvt", "st", "konsole", "gnome-terminal-server",
    "org.gnome.terminal", "terminator", "tilix", "xfce4-terminal", "ptyxis", "org.gnome.ptyxis",
}  # fmt: skip


class Backend:
    name = "none"
    supported = False

    def op(self, name, **a):
        log(f"window tool '{name}' is not available here ({self.name})")

    def focused_class(self):
        return ""

    def focused_is_terminal(self):
        return False


class HyprlandBackend(Backend):
    name = "hyprland"
    supported = True

    def op(self, name, **a):
        if name == "resize":
            return resize_active(a["axis"], a["grow"], a.get("step", RESIZE_STEP))
        lua = {
            "cycle": lambda: (
                "hl.dsp.window.cycle_next()"
                if a["forward"]
                else "hl.dsp.window.cycle_next({ next = false })"
            ),
            "focus": lambda: f'hl.dsp.focus({{ direction = "{a["dir"]}" }})',
            "workspace": lambda: f'hl.dsp.focus({{ workspace = "{a["to"]}" }})',
            "send": lambda: f'hl.dsp.window.move({{ workspace = "{a["to"]}" }})',
            "swap": lambda: (
                "hl.dsp.window.swap({ next = true })"
                if a["forward"]
                else "hl.dsp.window.swap({ prev = true })"
            ),
            "maximize": lambda: 'hl.dsp.window.fullscreen({ mode = "maximized" })',
            "fullscreen": lambda: 'hl.dsp.window.fullscreen({ mode = "fullscreen" })',
            "float": lambda: 'hl.dsp.window.float({ action = "toggle" })',
        }.get(name)
        if lua is None:
            return log(f"unknown window op {name!r}")
        hypr(lua())

    def focused_class(self):
        try:
            return (hypr_json("activewindow") or {}).get("class", "")
        except HYPR_ERRORS:
            return ""

    def focused_is_terminal(self):
        try:
            tags = (hypr_json("activewindow") or {}).get("tags") or []
        except HYPR_ERRORS:
            return False
        return any(isinstance(t, str) and t.rstrip("*") == "terminal" for t in tags)


class CommandBackend(Backend):
    """A backend that is a table of ops -> argv lists for the compositor's own command-line tool.

    A table entry may be an argv list, a callable taking the op's arguments and returning one,
    or None for "this compositor has no such thing".
    """

    supported = True
    table = {}
    tool = ""

    def op(self, name, **a):
        entry = self.table.get(name)
        if callable(entry):
            entry = entry(a)
        if not entry:
            return log(f"{self.name}: no equivalent for window tool '{name}'")
        run([self.tool, *self.prefix(), *entry])

    def prefix(self):
        return []

    def active(self):
        return {}

    _seen = (0.0, "")

    def focused_class(self):
        """The focused window's class, remembered for 150 ms.

        The Scroll tool asks on every knob event (about 100 a second) and each answer here costs
        a process spawn, so ask at most a few times a second. The window cannot change faster
        than a person can alt-tab.
        """
        at, cls = self._seen
        now = time.monotonic()
        if now - at > FOCUS_CACHE_S:
            cls = str(self.active().get("class", ""))
            self._seen = (now, cls)
        return cls

    def focused_is_terminal(self):
        return self.focused_class().lower() in TERMINAL_APP_IDS


def _swayish_resize(a):
    word = "width" if a["axis"] == "x" else "height"
    return [
        "resize",
        "grow" if a["grow"] else "shrink",
        word,
        str(a.get("step", RESIZE_STEP)),
        "px",
    ]


def _swayish_tree_focused(tree):
    stack = [tree]
    while stack:
        n = stack.pop()
        if n.get("focused"):
            return n
        stack.extend(n.get("nodes") or [])
        stack.extend(n.get("floating_nodes") or [])
    return {}


class SwayBackend(CommandBackend):
    """Sway, and i3 with `tool = "i3-msg"`. Both speak the i3 command language."""

    name = "sway"
    tool = "swaymsg"
    table = {
        "cycle": lambda a: ["focus", "next" if a["forward"] else "prev"],
        "focus": lambda a: ["focus", {"l": "left", "r": "right", "u": "up", "d": "down"}[a["dir"]]],
        "workspace": lambda a: [
            "workspace",
            {"+1": "next_on_output", "-1": "prev_on_output", "previous": "back_and_forth"}[a["to"]],
        ],
        "send": lambda a: [
            "move",
            "container",
            "to",
            "workspace",
            "next_on_output" if a["to"] == "+1" else "prev_on_output",
        ],
        # i3/sway can only swap with a named container, so "swap" moves the window along its row.
        "swap": lambda a: ["move", "right" if a["forward"] else "left"],
        # There is no separate "maximize" in this model; fullscreen is the closest.
        "maximize": ["fullscreen", "toggle"],
        "fullscreen": ["fullscreen", "toggle"],
        "float": ["floating", "toggle"],
        "resize": _swayish_resize,
    }

    def __init__(self, tool="swaymsg"):
        self.tool = tool
        self.name = "sway" if tool == "swaymsg" else "i3"

    def active(self):
        try:
            p = subprocess.run(
                [self.tool, "-t", "get_tree"], capture_output=True, text=True, timeout=2
            )
            node = _swayish_tree_focused(json.loads(p.stdout or "{}"))
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return {}
        props = node.get("window_properties") or {}
        return {"class": node.get("app_id") or props.get("class") or ""}


class NiriBackend(CommandBackend):
    """niri scrolls windows in columns, so left/right moves between columns, up/down within one."""

    name = "niri"
    tool = "niri"
    table = {
        "cycle": lambda a: [
            "action",
            "focus-column-right" if a["forward"] else "focus-column-left",
        ],
        "focus": lambda a: [
            "action",
            {
                "l": "focus-column-left",
                "r": "focus-column-right",
                "u": "focus-window-up",
                "d": "focus-window-down",
            }[a["dir"]],
        ],
        "workspace": lambda a: [
            "action",
            {
                "+1": "focus-workspace-down",
                "-1": "focus-workspace-up",
                "previous": "focus-workspace-previous",
            }[a["to"]],
        ],  # fmt: skip
        "send": lambda a: [
            "action",
            "move-window-to-workspace-down" if a["to"] == "+1" else "move-window-to-workspace-up",
        ],
        "swap": lambda a: ["action", "move-column-right" if a["forward"] else "move-column-left"],
        "maximize": ["action", "maximize-column"],
        "fullscreen": ["action", "fullscreen-window"],
        "float": ["action", "toggle-window-floating"],
        "resize": lambda a: [
            "action",
            "set-column-width" if a["axis"] == "x" else "set-window-height",
            f"{'+' if a['grow'] else '-'}{a.get('step', RESIZE_STEP)}",
        ],
    }

    def prefix(self):
        return ["msg"]

    def active(self):
        try:
            p = subprocess.run(
                ["niri", "msg", "--json", "focused-window"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            w = json.loads(p.stdout or "null") or {}
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return {}
        return {"class": w.get("app_id") or "" if isinstance(w, dict) else ""}


def detect_backend(env=None):
    """Pick the backend for the running session. DIAL_WM overrides (hyprland|sway|i3|niri|none).

    Hyprland is the default when nothing else is recognised, because that is what this was built
    on. A desktop that is clearly something else (GNOME, KDE, ...) gets the no-op backend.
    """
    env = os.environ if env is None else env
    forced = env.get("DIAL_WM", "").lower()
    if forced in ("sway", "i3", "niri", "none", "hyprland"):
        choice = forced
    elif env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        choice = "hyprland"
    elif env.get("NIRI_SOCKET"):
        choice = "niri"
    elif env.get("SWAYSOCK"):
        choice = "sway"
    elif env.get("I3SOCK"):
        choice = "i3"
    elif any(
        k in env.get("XDG_CURRENT_DESKTOP", "").upper()
        for k in ("GNOME", "KDE", "XFCE", "COSMIC", "MATE", "CINNAMON")
    ):
        choice = "none"
    else:
        choice = "hyprland"
    return {
        "hyprland": HyprlandBackend,
        "sway": SwayBackend,
        "i3": lambda: SwayBackend("i3-msg"),
        "niri": NiriBackend,
        "none": Backend,
    }[choice]()


_backend_cache = {"key": None, "backend": None}


def backend():
    """The current backend; re-detected only if the session's environment changes."""
    keys = (
        "DIAL_WM",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "NIRI_SOCKET",
        "SWAYSOCK",
        "I3SOCK",
        "XDG_CURRENT_DESKTOP",
    )
    key = tuple(os.environ.get(k, "") for k in keys)
    if _backend_cache["key"] != key:
        _backend_cache.update(key=key, backend=detect_backend())
        log(f"window manager backend: {_backend_cache['backend'].name}")
    return _backend_cache["backend"]


def window_label():
    """ "App  title" of the focused window for the overlay, short; "" when it can't be read."""
    if isinstance(backend(), HyprlandBackend):
        try:
            w = hypr_json("activewindow") or {}
        except HYPR_ERRORS:
            return ""
        app = str(w.get("class", "")).split(".")[-1]
        title = str(w.get("title", ""))
        return f"{app}  {title}"[:56].strip()
    return focused_class()


def focused_is_terminal():
    """Is the focused window a terminal? Omarchy tags terminals `terminal`; so do we.

    In a terminal Ctrl+C is "interrupt" and kills the running program, so copy and paste there use
    Ctrl+Insert and Shift+Insert, exactly as Omarchy's own universal copy and paste do.
    """
    return backend().focused_is_terminal()


def focused_class():
    return backend().focused_class()


EVIOCGNAME = 0x81004506  # _IOR('E', 0x06, char[256])


def device_name(fd):
    """Ask an open event device its own name."""
    buf = bytearray(256)
    try:
        fcntl.ioctl(fd, EVIOCGNAME, buf)
    except OSError:
        return ""
    return buf.split(b"\x00", 1)[0].decode("utf-8", "replace")


def find_input(name):
    """Resolve /dev/input/eventN for a device name.

    Blocks in /proc/bus/input/devices are separated by blank lines, but the
    file can be read mid-mutation when a device is being added or removed --
    which pairs one device's Name with another's Handlers. That really
    happened: after a pen BLE drop this returned the DIAL's node for the pen
    keyboard, and the tail button silently stopped working. Blocks are now
    delimited by their "I:" header, and the caller verifies with EVIOCGNAME.
    """
    try:
        with open("/proc/bus/input/devices") as fh:
            text = fh.read()
    except OSError:
        return None
    block = []
    for line in text.splitlines():
        if line.startswith("I: ") and block:
            hit = _match_block(block, name)
            if hit:
                return hit
            block = []
        block.append(line)
    return _match_block(block, name)


def _match_block(block, name):
    if not any(line.strip() == f'N: Name="{name}"' for line in block):
        return None
    for line in block:
        if line.startswith("H: Handlers="):
            for h in line.split("=", 1)[1].split():
                if h.startswith("event"):
                    return "/dev/input/" + h
    return None


# DIAL_DEVICE=/dev/input/eventN forces a node when two devices share a name. The name
# check below still runs.
DEVICE_OVERRIDES = {
    DEVICE_NAME: os.environ.get("DIAL_DEVICE", ""),
    STYLUS_NAME: os.environ.get("STYLUS_DEVICE", ""),
    PEN_KBD_NAME: os.environ.get("PEN_KBD_DEVICE", ""),
}


_open_failed = {}  # name -> the last "cannot open" message logged for it


def open_input(name, quiet=False):
    """Open the named device, verifying we got the right one.

    quiet: don't log a failed open. The dial's reconnect retries for about a second while udev
    sets the new node's permissions; only a failure that outlasts that is worth a line.
    """
    forced = DEVICE_OVERRIDES.get(name) or ""
    path = forced if forced else find_input(name)
    if path is None:
        return None, None
    try:
        fh = open(path, "rb")
    except OSError as exc:
        msg = f"cannot open {path} for {name}: {exc}"
        # a retry loop must not repeat one line fifty times
        if not quiet and _open_failed.get(name) != msg:
            log(msg)
            _open_failed[name] = msg
        return None, path  # listed but not openable (yet): the caller may retry soon
    _open_failed.pop(name, None)
    actual = device_name(fh.fileno())
    if actual != name:
        log(f"REFUSED {path}: expected '{name}', device says '{actual}'")
        fh.close()
        return None, None
    return fh, path


class DeviceWatch:
    """Sleep until the kernel's input device list changes, instead of re-reading it on a timer.

    /proc/bus/input/devices reports readable to poll() whenever a device is added or removed, so a
    dial that reconnects is noticed at once, and an idle daemon uses no CPU while it waits. A
    change that lands between a check and the next wait is not lost: poll() reports it
    immediately. Where the file cannot be polled this degrades to a plain sleep.
    """

    def __init__(self, path="/proc/bus/input/devices"):
        self._poll = None
        try:
            self._fh = open(path)
            self._poll = select.poll()
            self._poll.register(self._fh.fileno(), select.POLLIN)
            self._poll.poll(0)  # the first poll always says "changed"; take that now
        except (OSError, AttributeError):
            self._poll = None

    def wait(self, timeout):
        """Return when the device list changes or `timeout` seconds pass."""
        if self._poll is None:
            time.sleep(timeout)
        else:
            self._poll.poll(int(timeout * 1000))


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


EVIOCSCLOCKID = 0x400445A0  # _IOW('E', 0xa0, int)


def event_time(sec, usec, now):
    """An input event's kernel timestamp as a monotonic time, or `now` if it looks wrong.

    The kernel stamps each event when it happens. Re-stamping at read time lets any stall in
    this loop bunch buffered events together, which the speed estimate reads as a spin.
    """
    t = sec + usec / 1e6
    return t if 0 <= now - t < 5.0 else now


def use_monotonic_event_clock(fd):
    """Ask the kernel to stamp this device's events with CLOCK_MONOTONIC (our own clock)."""
    try:
        fcntl.ioctl(fd, EVIOCSCLOCKID, struct.pack("i", time.CLOCK_MONOTONIC))
        return True
    except OSError:
        return False


STATUS_PATH = os.path.join(os.path.dirname(CONFIG_PATH), "status.json")
STATUS_BEAT_S = 15  # rewrite at least this often; the settings window treats older as "not running"
_status = {"attached": False, "last_use": -math.inf}


def parse_bluetooth_info(text):
    """(connected, battery percent) from `bluetoothctl info` output; None where unknown."""
    connected = None
    battery = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Connected:"):
            connected = line.split(":", 1)[1].strip() == "yes"
        elif line.startswith("Battery Percentage:"):
            m = re.search(r"\((\d+)\)", line)
            if m:
                battery = max(0, min(100, int(m.group(1))))
    return connected, battery


def dial_address():
    """The paired Surface Dial's Bluetooth address, or None. Raises OSError/SubprocessError."""
    devs = subprocess.run(
        ["bluetoothctl", "devices"], capture_output=True, text=True, timeout=3
    ).stdout
    return next(
        (ln.split()[1] for ln in devs.splitlines() if "Surface Dial" in ln and len(ln.split()) > 1),
        None,
    )


def dial_bluetooth():
    """(connected, battery) for the paired Surface Dial, or (None, None) if unavailable."""
    try:
        addr = dial_address()
        if not addr:
            return None, None
        info = subprocess.run(
            ["bluetoothctl", "info", addr], capture_output=True, text=True, timeout=3
        ).stdout
        return parse_bluetooth_info(info)
    except (OSError, subprocess.SubprocessError):
        return None, None


def build_status(attached, connected, battery, now=None, keeping_awake=False):
    """What the settings window shows about the dial.

    `state` is "ready" (reading events), "asleep" (Bluetooth reports it disconnected) or
    "waiting" (not reading events, reason unknown, for example no Bluetooth tool installed).
    """
    if attached:
        state = "ready"
    elif connected is False:
        state = "asleep"
    else:
        state = "waiting"
    return {
        "version": __version__,
        "pid": os.getpid(),
        "updated": round(time.time() if now is None else now, 1),
        "state": state,
        "attached": bool(attached),
        "bluetooth_connected": connected,
        "battery": battery,
        "keeping_awake": bool(keeping_awake),
    }


def write_status(doc):
    """Atomically write the status file. Best-effort: the dial works without it."""
    try:
        write_json_atomic(STATUS_PATH, doc)
    except OSError as exc:
        log(f"could not write status ({exc})")


# Bluetooth can report the dial connected while the kernel never made an input device for it:
# BlueZ handed over an empty HID report map (kernel: "unbalanced collection ... parse failed").
# Dropping the link makes the dial reconnect cleanly on its next touch.
STUCK_S = 12.0  # connected-but-no-input this long counts as stuck
STUCK_BACKOFF_S = (30.0, 120.0, 600.0)  # wait between kicks while it stays stuck


class StuckWatch:
    """Decide when a connected-but-unattached dial needs its Bluetooth link dropped."""

    def __init__(self):
        self.since = None  # when the current stuck stretch began
        self.next_at = None  # earliest time the next kick may happen
        self.kicks = 0

    def feed(self, connected, attached, now):
        if attached or connected is not True:
            if attached and self.kicks:
                log(f"self-heal: dial attached after {self.kicks} reconnect(s)")
            self.since = self.next_at = None
            self.kicks = 0
            return False
        if self.since is None:
            self.since, self.next_at = now, now + STUCK_S
        if now < self.next_at:
            return False
        self.next_at = now + STUCK_BACKOFF_S[min(self.kicks, len(STUCK_BACKOFF_S) - 1)]
        self.kicks += 1
        return True


def kick_dial(why="self-heal: Bluetooth connected but no input device"):
    """Drop the dial's Bluetooth link so it reconnects (and re-sends its HID map) on next touch."""
    try:
        addr = dial_address()
        if addr:
            log(f"{why}; disconnecting {addr}")
            subprocess.run(["bluetoothctl", "disconnect", addr], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"self-heal: disconnect failed ({exc})")


def screen_locked(proc="/proc"):
    """A known lock screen is running (see SCREEN_LOCKERS)."""
    for d in os.listdir(proc):
        if d.isdigit():
            try:
                with open(f"{proc}/{d}/comm") as f:
                    if f.read().strip() in SCREEN_LOCKERS:
                        return True
            except OSError:
                continue  # exited mid-scan
    return False


def status_loop(interval=5):
    """Keep status.json current: on any change, and as a heartbeat otherwise."""
    last_doc, last_at, last_poke = None, 0.0, -math.inf
    keeping = False
    stuck = StuckWatch()
    while True:
        now = time.monotonic()
        idle_s = live_num("keep_awake_minutes", KEEP_AWAKE_MINUTES, 5, 240) * 60
        if not (
            _status["attached"]
            and live_bool("keep_awake", False)
            and now - _status["last_use"] <= idle_s
        ):
            keeping = False
        elif now - last_poke >= KEEP_AWAKE_S:
            keeping = not screen_locked()  # read /proc once a minute, not every pass
            if keeping:
                HAPTIC.keep_awake()
                last_poke = now
        connected, battery = dial_bluetooth()
        if stuck.feed(connected, _status["attached"], time.monotonic()):
            kick_dial()
        doc = build_status(_status["attached"], connected, battery, keeping_awake=keeping)
        key = {k: v for k, v in doc.items() if k != "updated"}
        if key != last_doc or time.monotonic() - last_at >= STATUS_BEAT_S:
            write_status(doc)
            last_doc, last_at = key, time.monotonic()
        time.sleep(interval)


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
