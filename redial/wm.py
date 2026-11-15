"""The window manager: Hyprland, Sway, niri or none, and what window has focus."""

import json
import os
import socket
import subprocess
import time

from .config import RESIZE_EDGE_SLACK, RESIZE_STEP
from .log import log
from .system import run

# Wheel scroll breaks only where an app opts into alt-scroll (DECSET 1007) and binds the
# resulting arrows destructively (Claude Code). See docs/DESIGN.md#scroll-routing.
SCROLL_SUPPRESS_CLASSES = {
    "org.omarchy.agent",  # Claude Code -- Up/Down there is prompt history.
}

# The same apps run inside an ordinary terminal (foot > bash > claude), where the class is just
# "foot"; the focused window's process tree tells them apart.
SCROLL_SUPPRESS_PROGRAMS = {"claude"}


_tree_cache = {"at": 0.0, "pid": None, "hit": None}


def _descendant_names(pid):
    """Program names (comm) of every process under `pid`, read from /proc."""
    kids = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        # comm sits in parentheses and may hold spaces; ppid is the 2nd field after it
        comm, rest = stat[stat.find("(") + 1 : stat.rfind(")")], stat[stat.rfind(")") + 2 :].split()
        kids.setdefault(int(rest[1]), []).append((int(d), comm))
    names, todo = set(), [pid]
    while todo:
        for child, comm in kids.get(todo.pop(), []):
            names.add(comm)
            todo.append(child)
    return names


def focused_runs_suppressed_program():
    """The focused window is a terminal running one of SCROLL_SUPPRESS_PROGRAMS (cached 2 s)."""
    if not isinstance(backend(), HyprlandBackend):
        return None
    try:
        pid = int((hypr_json("activewindow") or {}).get("pid") or 0)
    except (*HYPR_ERRORS, TypeError, ValueError):
        return None
    now = time.monotonic()
    if pid != _tree_cache["pid"] or now - _tree_cache["at"] > 2.0:
        hit = (
            next(iter(_descendant_names(pid) & SCROLL_SUPPRESS_PROGRAMS), None) if pid > 0 else None
        )
        _tree_cache.update(at=now, pid=pid, hit=hit)
    return _tree_cache["hit"]


def hypr(lua):
    """Dispatch a Hyprland Lua dispatcher expression.

    Omarchy 4 / Hyprland 0.56 replaced string dispatchers ("cyclenext",
    "workspace e+1") with a Lua API; the old form is parsed as Lua and fails.
    Reference: /usr/share/omarchy/default/hypr/bindings/
    """
    run(["hyprctl", "dispatch", lua])


def resize_active(axis, grow, step=RESIZE_STEP):
    """Grow or shrink the focused window by `step` px along one axis.

    Hyprland's relative resize acts on the edge that touches a neighbour, so on
    a tiled window a positive delta SHRINKS one that is pinned to the right (or
    bottom) monitor edge -- measured 2026-09-20: x=+40 took the right-hand of two
    tiled windows from 760 to 720 wide. Left alone, "clockwise = bigger" would
    flip depending on where the window happens to sit, so point the delta at
    the edge that actually has a neighbour. Floating windows always resize from
    the bottom-right corner; a fullscreen window has nothing to resize.
    """

    try:
        w = hypr_json("activewindow")
        if not w or w.get("fullscreen"):
            return
        delta = step if grow else -step
        if not w.get("floating"):
            mon = next(
                (m for m in hypr_json("monitors") or [] if m.get("id") == w.get("monitor")), None
            )
            if mon:
                scale = mon.get("scale") or 1
                (ax, ay), (sw, sh) = w["at"], w["size"]
                if axis == "x":
                    pinned = ax + sw >= mon["x"] + mon["width"] / scale - RESIZE_EDGE_SLACK
                else:
                    pinned = ay + sh >= mon["y"] + mon["height"] / scale - RESIZE_EDGE_SLACK
                if pinned:
                    delta = -delta
    except Exception as exc:
        log(f"resize: could not read window/monitor state: {exc}")
        return
    dx, dy = (delta, 0) if axis == "x" else (0, delta)
    hypr(f"hl.dsp.window.resize({{ x = {dx}, y = {dy}, relative = true }})")


# What hypr_json() and its callers can raise: no socket or hyprctl (OSError), a hung hyprctl
# (SubprocessError), unparseable output (ValueError), or a reply that is not an object.
HYPR_ERRORS = (OSError, subprocess.SubprocessError, ValueError, AttributeError)


def hypr_json(what):
    """Query Hyprland for `what` (activewindow, monitors, ...) and return the parsed JSON.

    Talks to Hyprland's own socket, which takes ~0.03 ms; `hyprctl` costs a process spawn
    (~3.6 ms) and this is called on every rotation event by the Scroll tool. Falls back to
    hyprctl if the socket is unavailable. Raises on failure.
    """
    sig, rt = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"), os.environ.get("XDG_RUNTIME_DIR")
    if sig and rt:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.5)
                s.connect(os.path.join(rt, "hypr", sig, ".socket.sock"))
                s.sendall(f"j/{what}".encode())
                chunks = []
                while chunk := s.recv(65536):
                    chunks.append(chunk)
            return json.loads(b"".join(chunks) or b"null")
        except (OSError, ValueError):
            pass
    p = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True, timeout=2)
    return json.loads(p.stdout or "null")


# --- window-manager backends -------------------------------------------------------------
#
# Tools say WHAT to do ({"do": "wm", "op": "workspace", "to": "+1"}); a backend says HOW for the
# compositor that is running. The dial itself (reading the device, haptics, volume, brightness,
# media, keys and scroll through the virtual input device) does not depend on any of this.
#
# Ops: cycle(forward) focus(dir l|r|u|d) workspace(to "+1"|"-1"|"previous") send(to "+1"|"-1")
#      swap(forward) maximize fullscreen float resize(axis x|y, grow, step)
# plus two queries: focused_class() and focused_is_terminal().
#
# Hyprland is the reference backend and renders exactly what the tools always sent. Sway, i3 and
# niri are built from their documented command lines. Anything else gets NoBackend, which says
# once that window tools are unavailable and leaves everything else working.

FOCUS_CACHE_S = 0.15

TERMINAL_APP_IDS = {
    "alacritty", "kitty", "foot", "footclient", "wezterm", "org.wezfurlong.wezterm", "ghostty",
    "com.mitchellh.ghostty", "xterm", "urxvt", "st", "konsole", "gnome-terminal-server",
    "org.gnome.terminal", "terminator", "tilix", "xfce4-terminal", "ptyxis", "org.gnome.ptyxis",
}  # fmt: skip


class Backend:
    name = "none"
    supported = False

    def op(self, name, **a):
        log(f"window tool '{name}' is not available here ({self.name})")

    def focused_class(self):
        return ""

    def focused_is_terminal(self):
        return False


class HyprlandBackend(Backend):
    name = "hyprland"
    supported = True

    def op(self, name, **a):
        if name == "resize":
            return resize_active(a["axis"], a["grow"], a.get("step", RESIZE_STEP))
        lua = {
            "cycle": lambda: (
                "hl.dsp.window.cycle_next()"
                if a["forward"]
                else "hl.dsp.window.cycle_next({ next = false })"
            ),
            "focus": lambda: f'hl.dsp.focus({{ direction = "{a["dir"]}" }})',
            "workspace": lambda: f'hl.dsp.focus({{ workspace = "{a["to"]}" }})',
            "send": lambda: f'hl.dsp.window.move({{ workspace = "{a["to"]}" }})',
            "swap": lambda: (
                "hl.dsp.window.swap({ next = true })"
                if a["forward"]
                else "hl.dsp.window.swap({ prev = true })"
            ),
            "maximize": lambda: 'hl.dsp.window.fullscreen({ mode = "maximized" })',
            "fullscreen": lambda: 'hl.dsp.window.fullscreen({ mode = "fullscreen" })',
            "float": lambda: 'hl.dsp.window.float({ action = "toggle" })',
        }.get(name)
        if lua is None:
            return log(f"unknown window op {name!r}")
        hypr(lua())

    def focused_class(self):
        try:
            return (hypr_json("activewindow") or {}).get("class", "")
        except HYPR_ERRORS:
            return ""

    def focused_is_terminal(self):
        try:
            tags = (hypr_json("activewindow") or {}).get("tags") or []
        except HYPR_ERRORS:
            return False
        return any(isinstance(t, str) and t.rstrip("*") == "terminal" for t in tags)


class CommandBackend(Backend):
    """A backend that is a table of ops -> argv lists for the compositor's own command-line tool.

    A table entry may be an argv list, a callable taking the op's arguments and returning one,
    or None for "this compositor has no such thing".
    """

    supported = True
    table = {}
    tool = ""

    def op(self, name, **a):
        entry = self.table.get(name)
        if callable(entry):
            entry = entry(a)
        if not entry:
            return log(f"{self.name}: no equivalent for window tool '{name}'")
        run([self.tool, *self.prefix(), *entry])

    def prefix(self):
        return []

    def active(self):
        return {}

    _seen = (0.0, "")

    def focused_class(self):
        """The focused window's class, remembered for 150 ms.

        The Scroll tool asks on every knob event (about 100 a second) and each answer here costs
        a process spawn, so ask at most a few times a second. The window cannot change faster
        than a person can alt-tab.
        """
        at, cls = self._seen
        now = time.monotonic()
        if now - at > FOCUS_CACHE_S:
            cls = str(self.active().get("class", ""))
            self._seen = (now, cls)
        return cls

    def focused_is_terminal(self):
        return self.focused_class().lower() in TERMINAL_APP_IDS


def _swayish_resize(a):
    word = "width" if a["axis"] == "x" else "height"
    return [
        "resize",
        "grow" if a["grow"] else "shrink",
        word,
        str(a.get("step", RESIZE_STEP)),
        "px",
    ]


def _swayish_tree_focused(tree):
    stack = [tree]
    while stack:
        n = stack.pop()
        if n.get("focused"):
            return n
        stack.extend(n.get("nodes") or [])
        stack.extend(n.get("floating_nodes") or [])
    return {}


class SwayBackend(CommandBackend):
    """Sway, and i3 with `tool = "i3-msg"`. Both speak the i3 command language."""

    name = "sway"
    tool = "swaymsg"
    table = {
        "cycle": lambda a: ["focus", "next" if a["forward"] else "prev"],
        "focus": lambda a: ["focus", {"l": "left", "r": "right", "u": "up", "d": "down"}[a["dir"]]],
        "workspace": lambda a: [
            "workspace",
            {"+1": "next_on_output", "-1": "prev_on_output", "previous": "back_and_forth"}[a["to"]],
        ],
        "send": lambda a: [
            "move",
            "container",
            "to",
            "workspace",
            "next_on_output" if a["to"] == "+1" else "prev_on_output",
        ],
        # i3/sway can only swap with a named container, so "swap" moves the window along its row.
        "swap": lambda a: ["move", "right" if a["forward"] else "left"],
        # There is no separate "maximize" in this model; fullscreen is the closest.
        "maximize": ["fullscreen", "toggle"],
        "fullscreen": ["fullscreen", "toggle"],
        "float": ["floating", "toggle"],
        "resize": _swayish_resize,
    }

    def __init__(self, tool="swaymsg"):
        self.tool = tool
        self.name = "sway" if tool == "swaymsg" else "i3"

    def active(self):
        try:
            p = subprocess.run(
                [self.tool, "-t", "get_tree"], capture_output=True, text=True, timeout=2
            )
            node = _swayish_tree_focused(json.loads(p.stdout or "{}"))
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return {}
        props = node.get("window_properties") or {}
        return {"class": node.get("app_id") or props.get("class") or ""}


class NiriBackend(CommandBackend):
    """niri scrolls windows in columns, so left/right moves between columns, up/down within one."""

    name = "niri"
    tool = "niri"
    table = {
        "cycle": lambda a: [
            "action",
            "focus-column-right" if a["forward"] else "focus-column-left",
        ],
        "focus": lambda a: [
            "action",
            {
                "l": "focus-column-left",
                "r": "focus-column-right",
                "u": "focus-window-up",
                "d": "focus-window-down",
            }[a["dir"]],
        ],
        "workspace": lambda a: [
            "action",
            {
                "+1": "focus-workspace-down",
                "-1": "focus-workspace-up",
                "previous": "focus-workspace-previous",
            }[a["to"]],
        ],  # fmt: skip
        "send": lambda a: [
            "action",
            "move-window-to-workspace-down" if a["to"] == "+1" else "move-window-to-workspace-up",
        ],
        "swap": lambda a: ["action", "move-column-right" if a["forward"] else "move-column-left"],
        "maximize": ["action", "maximize-column"],
        "fullscreen": ["action", "fullscreen-window"],
        "float": ["action", "toggle-window-floating"],
        "resize": lambda a: [
            "action",
            "set-column-width" if a["axis"] == "x" else "set-window-height",
            f"{'+' if a['grow'] else '-'}{a.get('step', RESIZE_STEP)}",
        ],
    }

    def prefix(self):
        return ["msg"]

    def active(self):
        try:
            p = subprocess.run(
                ["niri", "msg", "--json", "focused-window"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            w = json.loads(p.stdout or "null") or {}
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return {}
        return {"class": w.get("app_id") or "" if isinstance(w, dict) else ""}


def detect_backend(env=None):
    """Pick the backend for the running session. DIAL_WM overrides (hyprland|sway|i3|niri|none).

    Hyprland is the default when nothing else is recognised, because that is what this was built
    on. A desktop that is clearly something else (GNOME, KDE, ...) gets the no-op backend.
    """
    env = os.environ if env is None else env
    forced = env.get("DIAL_WM", "").lower()
    if forced in ("sway", "i3", "niri", "none", "hyprland"):
        choice = forced
    elif env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        choice = "hyprland"
    elif env.get("NIRI_SOCKET"):
        choice = "niri"
    elif env.get("SWAYSOCK"):
        choice = "sway"
    elif env.get("I3SOCK"):
        choice = "i3"
    elif any(
        k in env.get("XDG_CURRENT_DESKTOP", "").upper()
        for k in ("GNOME", "KDE", "XFCE", "COSMIC", "MATE", "CINNAMON")
    ):
        choice = "none"
    else:
        choice = "hyprland"
    return {
        "hyprland": HyprlandBackend,
        "sway": SwayBackend,
        "i3": lambda: SwayBackend("i3-msg"),
        "niri": NiriBackend,
        "none": Backend,
    }[choice]()


_backend_cache = {"key": None, "backend": None}


def backend():
    """The current backend; re-detected only if the session's environment changes."""
    keys = (
        "DIAL_WM",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "NIRI_SOCKET",
        "SWAYSOCK",
        "I3SOCK",
        "XDG_CURRENT_DESKTOP",
    )
    key = tuple(os.environ.get(k, "") for k in keys)
    if _backend_cache["key"] != key:
        _backend_cache.update(key=key, backend=detect_backend())
        log(f"window manager backend: {_backend_cache['backend'].name}")
    return _backend_cache["backend"]


def window_label():
    """ "App  title" of the focused window for the overlay, short; "" when it can't be read."""
    if isinstance(backend(), HyprlandBackend):
        try:
            w = hypr_json("activewindow") or {}
        except HYPR_ERRORS:
            return ""
        app = str(w.get("class", "")).split(".")[-1]
        title = str(w.get("title", ""))
        return f"{app}  {title}"[:56].strip()
    return focused_class()


def focused_is_terminal():
    """Is the focused window a terminal? Omarchy tags terminals `terminal`; so do we.

    In a terminal Ctrl+C is "interrupt" and kills the running program, so copy and paste there use
    Ctrl+Insert and Shift+Insert, exactly as Omarchy's own universal copy and paste do.
    """
    return backend().focused_is_terminal()


def focused_class():
    return backend().focused_class()
