"""Virtual input over /dev/uinput: a pointer (moves, wheel, buttons) and a keyboard."""

import fcntl
import os
import struct

from .devices import EV_FORMAT, EV_KEY
from .log import log


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


POINTER = VirtualPointer()
KEYBOARD = VirtualKeyboard()
