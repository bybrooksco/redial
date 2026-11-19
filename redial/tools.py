"""The tool library, the ring built from config.json, and the manifest the settings window reads."""

import os
import shutil

from .actions import CAST_ERRORS, make_action
from .config import POINTER_GAIN, READING_RETURN_S, SCROLL_GAIN, ZOOM_GAIN, load_config
from .feedback import backlight_device
from .gestures import (
    CLICK_ACTIONS,
    CLICK_DEFAULTS,
    PEN_BARREL_ACTIONS,
    PEN_BARREL_DEFAULT,
    PEN_BARREL_HOLD_ACTIONS,
    PEN_BARREL_HOLD_DEFAULT,
    PEN_ERASER_ACTIONS,
    PEN_ERASER_DEFAULTS,
    PEN_TAIL_ACTIONS,
    PEN_TAIL_DEFAULTS,
    tool_clicks_spec,
)
from .log import log
from .paths import CONFIG_PATH
from .system import write_json_atomic
from .wm import backend

# Volume is index 0 and is the idle home: rotating at rest only changes volume.
# "detent" is the constant angle (in counts) between clicks for this tool.
# "mag" tools accept a magnitude 1..MAG_MAX derived from rotation speed;
# discrete tools ignore it because "1.6 windows" is meaningless.


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
                # What its own click does, for the picker ("" = nothing).
                "click_label": str((t.get("click") or {}).get("label", "") or "")
                if isinstance(t.get("click"), dict)
                else "",
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
TOOLS_STATE = {"mtime": None}
try:
    TOOLS_STATE["mtime"] = os.stat(CONFIG_PATH).st_mtime_ns
except OSError:
    pass
