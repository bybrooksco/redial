"""What the settings window reads (attached, connected, battery), and the dial's self-heal."""

import math
import os
import re
import subprocess
import time

from . import __version__
from .config import KEEP_AWAKE_MINUTES, KEEP_AWAKE_S, SCREEN_LOCKERS, live_bool, live_num
from .haptics import HAPTIC
from .log import log
from .paths import CONFIG_PATH
from .system import write_json_atomic

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
