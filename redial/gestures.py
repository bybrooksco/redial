"""Clicks and pen buttons: what each gesture can do, what it is set to, and its compiled action."""

import math
import re

from .actions import is_string_list, make_action
from .config import MAX_LAUNCHERS, pen_section, live_derived, load_config
from .log import log

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
        if not cmd or not is_string_list(cmd):
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
CLICK_BY_NAME = {a[0]: a for a in CLICK_ACTIONS}
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
        if k in CLICK_DEFAULTS and isinstance(v, str) and v in CLICK_BY_NAME:
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
            if isinstance(v, str) and v in CLICK_BY_NAME and not (v == "tool" and k != "single"):
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
        spec = CLICK_BY_NAME[name][3]
        _click_fns[name] = make_action(spec) if spec else None
    return _click_fns[name]


def click_hint(tool):
    """Click label the overlay shows for `tool`, honouring a single-click override."""
    name = click_choice("single", tool)
    return tool["click_label"] if name == "tool" else CLICK_BY_NAME[name][1]


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
PEN_TAIL_BY_NAME = {a[0]: a for a in PEN_TAIL_ACTIONS}
_pen_tail_cache = {}
_pen_tail_fns = {}


def pen_tail_choice(slot):
    """Configured action name for the tail button's "single"|"double"|"hold"."""

    def build(doc):
        raw = pen_section(doc).get("tail_clicks")
        raw = raw if isinstance(raw, dict) else {}
        choice = dict(PEN_TAIL_DEFAULTS)
        for k in PEN_TAIL_DEFAULTS:
            v = raw.get(k)
            if isinstance(v, str) and v in PEN_TAIL_BY_NAME:
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
        spec = PEN_TAIL_BY_NAME[name][3]
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
# A touch shorter than this is a brush, not a tap: a scroll often starts with a bounce of contact
# 30-60 ms long, which used to fire Escape. The default is easy to beat on purpose; the Pen
# settings can raise, lower or switch it off (0).
ERASER_TAP_MIN_MS_DEFAULT = 100
PEN_ERASER_DEFAULTS = {"tap": "escape", "hold": "delete_word"}
PEN_ERASER_BY_NAME = {a[0]: a for a in PEN_ERASER_ACTIONS}
_pen_eraser_cache = {}
_pen_eraser_fns = {}


def pen_eraser_config():
    """(tap action, hold action, minimum tap seconds, scroll speed multiplier), live-reloaded."""

    def build(doc):
        pen = pen_section(doc)
        raw = pen.get("eraser")
        raw = raw if isinstance(raw, dict) else {}
        choice = dict(PEN_ERASER_DEFAULTS)
        for k in PEN_ERASER_DEFAULTS:
            v = raw.get(k)
            if isinstance(v, str) and v in PEN_ERASER_BY_NAME:
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
        spec = PEN_ERASER_BY_NAME[name][3]
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
PEN_BARREL_BY_NAME = {a[0]: a for a in PEN_BARREL_ACTIONS}
_pen_barrel_cache = {}
_pen_barrel_fns = {}


def pen_barrel_config():
    """(enabled, action name) for the stylus barrel button, live-reloaded."""

    def build(doc):
        raw = pen_section(doc).get("barrel")
        raw = raw if isinstance(raw, dict) else {}
        enabled = bool(raw.get("enabled", True))
        action = raw.get("action")
        if not (isinstance(action, str) and action in PEN_BARREL_BY_NAME):
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
PEN_BARREL_HOLD_BY_NAME = {a[0]: a for a in PEN_BARREL_HOLD_ACTIONS}
_pen_barrel_hold_cache = {}


def pen_barrel_hold():
    """(action name, seconds) for holding the barrel button, live-reloaded."""

    def build(doc):
        raw = pen_section(doc).get("barrel")
        raw = raw if isinstance(raw, dict) else {}
        name = raw.get("hold", PEN_BARREL_HOLD_DEFAULT)
        if not (isinstance(name, str) and name in PEN_BARREL_HOLD_BY_NAME):
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
        spec = (PEN_BARREL_BY_NAME.get(name) or PEN_BARREL_HOLD_BY_NAME[name])[3]
        _pen_barrel_fns[name] = make_action(spec) if spec else None
    return _pen_barrel_fns[name]
