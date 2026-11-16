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
import select
import signal
import struct
import sys
import threading
import time

from . import guide
from .config import (
    DROP_IN_USE_S,
    OPEN_RETRY_MAX,
    OPEN_RETRY_S,
    REATTACH_PAUSE_S,
    WATCH_SAFETY_S,
    pen_section,
    load_config,
)
from .devices import (
    BTN_0,
    DEVICE_NAME,
    EV_FORMAT,
    EV_KEY,
    EV_REL,
    EV_SIZE,
    REL_DIAL,
    DeviceWatch,
    event_time,
    open_input,
    use_monotonic_event_clock,
)
from .dial import Dial
from .feedback import cant_note
from .guide import Guide, guide_enabled, guide_mode, guide_path, guide_say, tool_lines
from .keys import uinput_keys
from .log import log
from .pen import eraser_watcher, pen_button_watcher
from .status import STATUS, status_loop
from .system import make_private, single_instance
from .tools import IDLE_TOOL
from .uinput import KEYBOARD, POINTER

# A plain `kill` exits through sys.exit, so atexit hooks run (release_mod lets go of a held key).
signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))


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
                STATUS["last_use"] = now  # the keep-awake idle window counts from here
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
    if bool(pen_section(load_config()).get("enabled", True)):
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
    guide.GUIDE = Guide(
        guide_path(), guide_say, enabled=guide_enabled, mode=guide_mode, describe=tool_lines
    )
    atexit.register(guide.GUIDE.flush)
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
        STATUS["attached"] = True
        STATUS["last_use"] = time.monotonic()  # a press woke it, so someone is here
        dial.reset_gestures()
        dial._arm(IDLE_TOOL, time.monotonic())
        dial.last_action = time.monotonic()
        dial.show_connected()
        guide.GUIDE.attached()
        attached_at = time.monotonic()
        try:
            pump(fh, dial)
        except OSError as exc:
            log(f"detached ({exc})")
        STATUS["attached"] = False
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
