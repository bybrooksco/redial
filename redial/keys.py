"""Key presses: through wtype, or the uinput keyboard where wtype can't work; a held modifier."""

import atexit
import os
import shutil
import subprocess

from .log import log
from .system import run
from .uinput import KEYBOARD
from .wm import backend


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


def repeat_key(mag, *combo):
    for _ in range(mag):
        key(*combo)
