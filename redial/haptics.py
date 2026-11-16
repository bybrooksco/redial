"""The dial's haptic motor, driven over hidraw from a worker thread."""

import os
import queue
import threading
import time

from .config import HAPTIC_MIN_GAP, HAPTIC_NONE, HAPTIC_WAVEFORM
from .devices import HID_ID
from .log import log


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


HAPTIC = Haptics()
