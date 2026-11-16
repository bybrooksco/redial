"""Telling the user what happened: re:dial's overlay, Omarchy's OSD, notifications, speech."""

import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time

from .config import (
    ANCHORS,
    MENU_ANCHOR,
    MENU_LAYOUT,
    cfg_str,
    live_bool,
    live_config,
    load_config,
    osd_enabled,
)
from .log import log
from .system import ACTIONS, run


def omarchy_shell():
    """Whether Omarchy's shell (and so re:dial's own Omarchy overlay) is installed."""
    return shutil.which("omarchy-shell") is not None


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
        # The tool layer imports this module, so the ring is looked up at call time.
        from .gestures import click_hint
        from .tools import TOOLS

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
        from .tools import TOOLS

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
    from .gestures import click_hint
    from .tools import TOOLS

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
