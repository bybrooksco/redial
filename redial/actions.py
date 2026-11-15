"""The action vocabulary: a tool's {"do": ...} spec compiled into something the dial can run."""

import threading
import time

from .config import BRIGHT_STEP, RESIZE_STEP, SEEK_STEP_S, live_config
from .controls import media_command, seek_media, set_brightness, show_level, vol
from .feedback import cant_note, notify, omarchy_shell
from .keys import key, repeat_key
from .log import log
from .status import kick_dial
from .system import launch, run
from .uinput import POINTER, VirtualPointer
from .wm import (
    HYPR_ERRORS,
    SCROLL_SUPPRESS_CLASSES,
    backend,
    focused_class,
    focused_is_terminal,
    focused_runs_suppressed_program,
    hypr,
    hypr_json,
)

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


_scroll_warned_class = None


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


def dictation_toggle():
    if run(["voxtype", "record", "toggle"]):
        notify("\U0001f399  Dictation", "voxtype toggled")
    else:
        notify(
            "\U0001f399  Dictation unavailable",
            "voxtype isn't running: journalctl --user -u voxtype",
        )
