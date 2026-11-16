"""Linux input devices: evdev event codes, finding and opening the dial and the pen by name."""

import fcntl
import os
import select
import struct
import time

from .log import log

DEVICE_NAME = "Surface Dial System Multi Axis"
STYLUS_NAME = "Surface Touch Device Stylus"
PEN_KBD_NAME = "Surface Pen Keyboard"

HID_ID = "091B"  # Microsoft Surface Dial product id

EV_FORMAT = "llHHi"
EV_SIZE = struct.calcsize(EV_FORMAT)
EV_KEY, EV_REL = 0x01, 0x02
REL_DIAL, BTN_0 = 0x07, 0x100
BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS = 0x141, 0x14A, 0x14B
EV_ABS = 0x03
ABS_X, ABS_Y = 0x00, 0x01


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
