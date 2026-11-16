"""The guide: teaches the dial by what the person does, one idea at a time."""

import json
import os
import time

from .config import live_bool, live_config, menu_latch, osd_enabled
from .feedback import osd, overlay_note
from .gestures import click_hint
from .log import log
from .paths import CONFIG_PATH
from .system import ACTIONS, write_json_atomic
from .tools import IDLE_TOOL, TOOL_LIBRARY, TOOLS

# --------------------------------------------------------------------------
# --- the guide ---
# Teaches the dial by what the person actually does, one idea at a time, instead of up front:
# a hint appears only when their behaviour shows they are ready for it (or stuck) and they have
# not just done the thing. Progress and counters live in progress.json next to the config; the
# counters are plain usage totals, kept on this machine only.
#
# Three styles, picked by the "onboarding_mode" setting (all share the same progress file):
#   adaptive  four stages, each shown when behaviour says the person is ready for it (default)
#   discover  almost nothing up front: two hints (press, then hold), only when they are needed
#   guided    a short linear tour on first connect: do each gesture once, in order
# Adaptive and discover also teach each tool the first time it is picked, and again with its
# click if the person turns it a while without ever clicking. Guided teaches only the tour.
GUIDE_COOLDOWN_S = 30.0  # never two hints within this long
GUIDE_MAX_SHOWS = 3  # a hint that has not worked after this many showings is dropped
GUIDE_FLUSH_S = 30.0  # progress is written at least this often while counters change
GUIDE_STEPS_BEFORE_HINT = 10  # steps of turning with the next thing still undone
GUIDE_MODES = ("adaptive", "discover", "guided")
TOUR_REPROMPT_S = 20.0  # a tour step nobody has done is asked again after this long...
TOUR_MAX_PROMPTS = 3  # ...up to this many times, then skipped so the tour never gets stuck
TOUR_TURN_STEPS = 3  # steps of turning that count as having tried it


def _hint_press():
    label = click_hint(TOOLS[IDLE_TOOL]) if TOOLS else ""
    return f"Press the dial: {label}" if label and label != "—" else None


def _hint_pick():
    if menu_latch():
        return "Turn to a tool, then click to choose it"
    return "Keep holding, turn to a tool, then let go"


# id, the event that completes it, what makes its hint appear, the hint text, whether showing the
# hint is itself the lesson. Order is the order of learning; an event completes its stage even when
# it happens early or out of order.
GUIDE_STAGES = [
    {
        "id": "press",
        "done": "click",
        "when": ("steps", GUIDE_STEPS_BEFORE_HINT),
        "text": _hint_press,
    },
    {
        "id": "hold",
        "done": "menu",
        "when": ("steps", GUIDE_STEPS_BEFORE_HINT),
        "text": lambda: "Hold the button to choose a tool",
    },
    {"id": "pick", "done": "pick", "when": ("event", "menu_same"), "text": _hint_pick},
    {
        "id": "own",
        "done": None,
        "when": ("steps", 3 * GUIDE_STEPS_BEFORE_HINT),
        "text": lambda: "Make it yours: Menu > Setup > re:dial",
    },
]

# Discover: two hints. Press when turning alone has gone on a while, hold right after the first
# press. No pick hint, no pointer to settings; the person finds those or they do not need them.
DISCOVER_STAGES = [
    GUIDE_STAGES[0],
    {
        "id": "hold",
        "done": "menu",
        "when": ("event", "click"),
        "text": lambda: "Hold the button for the tool ring",
    },
]


def _tour_close():
    return "Click to close the ring" if menu_latch() else "Let go to close the ring"


def _tour_pick():
    if menu_latch():
        return "Hold, turn to another tool, then click to choose it"
    return "Hold, turn to another tool, then let go"


# The guided tour: id, the events that finish it, how many of them it takes, what it asks. The
# last step only points at settings, and being shown is its lesson. An event that finishes a later
# step moves the tour past every step before it.
TOUR_STEPS = [
    {"id": "turn", "done": ("step",), "need": TOUR_TURN_STEPS, "text": lambda: "Turn the dial"},
    {"id": "press", "done": ("click",), "need": 1, "text": lambda: "Now press it"},
    {
        "id": "hold",
        "done": ("menu",),
        "need": 1,
        "text": lambda: "Press and hold to open the tool ring",
    },
    {"id": "close", "done": ("menu_same", "pick"), "need": 1, "text": _tour_close},
    {"id": "pick", "done": ("pick",), "need": 1, "text": _tour_pick},
    {
        "id": "feel",
        "done": (),
        "need": 1,
        "text": lambda: "Too fast or slow? Menu > Setup > re:dial > Feel",
    },
]


# The gesture a hint asks for, from the event that answers it (the overlay draws it).
HINT_GESTURE = {
    "step": "turn",
    "click": "press",
    "menu": "hold",
    "menu_same": "hold",
    "pick": "hold",
}


def guide_stages(mode):
    return DISCOVER_STAGES if mode == "discover" else GUIDE_STAGES


class Guide:
    """The introduction: counts what the person does and speaks up when it will help.

    `event(kind)` takes "step", "click", "menu" (menu opened), "pick" (a different tool chosen)
    and "menu_same" (menu closed without a change). `armed(name, rest)` says which tool is now
    active, `attached()` that the dial just connected or woke. `say(text, meta)` shows a line
    (meta: the gesture it asks for and, on the tour, "step" of "steps"),
    `mode()` returns "adaptive", "discover" or "guided", and `describe(name)` returns the
    {"intro", "click"} lines for a tool (or None). Nothing here blocks or changes what the dial
    does; it only watches and, now and then, shows a line of text.
    """

    def __init__(
        self,
        path,
        say,
        clock=time.monotonic,
        enabled=lambda: True,
        mode=lambda: "adaptive",
        describe=lambda name: None,
    ):
        self.path = path
        self.say = say
        self.clock = clock
        self.enabled = enabled
        self.mode = mode
        self.describe = describe
        self.state = self._load()
        self.session_steps = 0  # turning since the last hint or stage change
        self.last_hint = -1e9
        self.last_flush = clock()
        self.dirty = False
        self.tool = None  # the active tool, for the per-tool hints
        self.tool_rest = True  # ...and whether it is the resting tool (Volume), which is skipped
        self.tool_steps = 0  # steps on the active tool since it was armed or last hinted
        self.last_prompt = -1e9  # when the guided tour last asked for its current step

    @staticmethod
    def _fresh():
        return {
            "version": 2,
            "done": [],
            "shown": {},
            "counts": {"steps": 0, "clicks": 0, "menus": 0, "picks": 0},
            "tools": {},
            "tour": {"step": 0, "n": 0, "prompts": 0, "skipped": [], "done": False},
        }

    @staticmethod
    def _int(v):
        return isinstance(v, int) and not isinstance(v, bool) and v >= 0

    def _load(self):
        state = self._fresh()
        try:
            with open(self.path, encoding="utf-8") as f:
                doc = json.load(f)
            if isinstance(doc, dict):
                if isinstance(doc.get("done"), list):
                    state["done"] = [d for d in doc["done"] if isinstance(d, str)]
                if isinstance(doc.get("shown"), dict):
                    state["shown"] = {k: v for k, v in doc["shown"].items() if self._int(v)}
                if isinstance(doc.get("counts"), dict):
                    for k in state["counts"]:
                        v = doc["counts"].get(k)
                        if self._int(v):
                            state["counts"][k] = v
                self._load_tools(state, doc.get("tools"))
                self._load_tour(state, doc.get("tour"))
        except (OSError, ValueError):
            pass  # no file yet, or a damaged one: start the introduction from the beginning
        return state

    def _load_tools(self, state, tools):
        if not isinstance(tools, dict):
            return
        for name, entry in tools.items():
            if isinstance(name, str) and isinstance(entry, dict):
                fresh = self._tool_entry()
                for k in ("intro", "click_shown", "steps"):
                    if self._int(entry.get(k)):
                        fresh[k] = entry[k]
                if isinstance(entry.get("clicked"), bool):
                    fresh["clicked"] = entry["clicked"]
                state["tools"][name] = fresh

    def _load_tour(self, state, tour):
        if not isinstance(tour, dict):
            return
        for k in ("step", "n", "prompts"):
            if self._int(tour.get(k)):
                state["tour"][k] = tour[k]
        state["tour"]["step"] = min(state["tour"]["step"], len(TOUR_STEPS) - 1)
        if isinstance(tour.get("skipped"), list):
            state["tour"]["skipped"] = [s for s in tour["skipped"] if isinstance(s, str)]
        if isinstance(tour.get("done"), bool):
            state["tour"]["done"] = tour["done"]

    @staticmethod
    def _tool_entry():
        return {"intro": 0, "click_shown": 0, "clicked": False, "steps": 0}

    def flush(self):
        """Write progress, atomically. Best effort: the dial works without it."""
        if not self.dirty:
            return
        try:
            write_json_atomic(self.path, self.state)
            self.dirty = False
        except OSError as exc:
            log(f"could not write progress ({exc})")
        self.last_flush = self.clock()

    def reset(self):
        """Start the introduction again (the counters go too)."""
        self.state = self._fresh()
        self.session_steps = 0
        self.tool_steps = 0
        self.last_prompt = -1e9
        self.dirty = True
        self.flush()

    def _complete(self, stage_id):
        if stage_id not in self.state["done"]:
            self.state["done"].append(stage_id)
            self.session_steps = 0
            self.dirty = True
            self.flush()

    def _speaking(self):
        return self.enabled()

    def _learning(self):
        return self._speaking() and self.mode() != "guided"

    def _entry(self, name):
        return self.state["tools"].setdefault(name, self._tool_entry())

    # --- what the dial tells us
    def event(self, kind):
        counts = self.state["counts"]
        key = {"step": "steps", "click": "clicks", "menu": "menus", "pick": "picks"}.get(kind)
        if key:
            counts[key] += 1
            self.dirty = True
        mode = self.mode()
        if kind == "step":
            self.session_steps += 1
            self.tool_steps += 1
            if self.tool:
                self._entry(self.tool)["steps"] += 1
        if kind == "click" and self.tool and not self.tool_rest:
            self._entry(self.tool)["clicked"] = True
        if mode == "guided":
            self._tour_event(kind)
        else:
            for stage in guide_stages(mode):
                if stage["done"] == kind:
                    self._complete(stage["id"])
            if not self._maybe_hint(kind, mode):
                self._maybe_tool_click_hint(kind)
        if self.dirty and self.clock() - self.last_flush >= GUIDE_FLUSH_S:
            self.flush()

    def armed(self, name, rest=False):
        """A different tool is now active. The resting tool is taught by the other hints."""
        self.tool, self.tool_rest, self.tool_steps = name, rest, 0
        if rest or not self._learning():
            return
        entry = self._entry(name)
        if entry["intro"]:
            return
        lines = self.describe(name) or {}
        if not lines.get("intro"):
            return
        entry["intro"] = 1
        self.dirty = True
        self.last_hint = self.clock()
        self.session_steps = 0
        self.flush()
        self.say(lines["intro"], {"gesture": "turn"})

    def attached(self):
        """The dial connected or woke: the tour (if it is the chosen style) asks its next step."""
        if self.mode() != "guided" or not self._speaking() or self.state["tour"]["done"]:
            return
        self._tour_say()

    # --- adaptive and discover
    def _next_stage(self, mode):
        for stage in guide_stages(mode):
            if stage["id"] not in self.state["done"]:
                return stage
        return None

    def _maybe_hint(self, kind, mode):
        """Show the next stage's hint if it is due. True when a hint was shown."""
        stage = self._next_stage(mode)
        if stage is None or not self._speaking():
            return False
        what, need = stage["when"]
        ready = self.session_steps >= need if what == "steps" else kind == need
        if not ready or self.state["shown"].get(stage["id"], 0) >= GUIDE_MAX_SHOWS:
            return False
        now = self.clock()
        # The cooldown spaces out hints the guide volunteers while someone turns; one that answers
        # something they just did (a menu closed without a choice) is help they asked for.
        if what == "steps" and now - self.last_hint < GUIDE_COOLDOWN_S:
            return False
        text = stage["text"]()
        if not text:
            return False
        self.last_hint = now
        self.session_steps = 0
        self.state["shown"][stage["id"]] = self.state["shown"].get(stage["id"], 0) + 1
        self.dirty = True
        if stage["done"] is None:
            self._complete(stage["id"])  # showing it was the lesson
        self.flush()
        self.say(text, {"gesture": HINT_GESTURE.get(stage["done"], "")})
        return True

    def _maybe_tool_click_hint(self, kind):
        """A tool turned a while with no click on it: say what its click does."""
        if kind != "step" or self.tool_rest or not self.tool or not self._learning():
            return
        entry = self._entry(self.tool)
        if entry["clicked"] or entry["click_shown"] >= GUIDE_MAX_SHOWS:
            return
        if self.tool_steps < GUIDE_STEPS_BEFORE_HINT:
            return
        now = self.clock()
        if now - self.last_hint < GUIDE_COOLDOWN_S:
            return
        text = (self.describe(self.tool) or {}).get("click")
        if not text:
            return
        entry["click_shown"] += 1
        self.tool_steps = 0
        self.last_hint = now
        self.dirty = True
        self.flush()
        self.say(text, {"gesture": "press"})

    # --- guided tour
    def _tour_say(self):
        tour = self.state["tour"]
        step = TOUR_STEPS[tour["step"]]
        text = step["text"]()
        tour["prompts"] += 1
        self.last_prompt = self.clock()
        self.dirty = True
        gesture = HINT_GESTURE.get(step["done"][0], "") if step["done"] else ""
        self.say(text, {"gesture": gesture, "step": tour["step"] + 1, "steps": len(TOUR_STEPS)})
        if TOUR_STEPS[tour["step"]]["id"] == "feel":
            tour["done"] = True  # showing the last step was the lesson
        self.flush()

    def _tour_event(self, kind):
        tour = self.state["tour"]
        if tour["done"] or not self._speaking():
            return
        if kind == "step":
            tour["n"] += 1
        for i in range(len(TOUR_STEPS) - 1, tour["step"] - 1, -1):
            step = TOUR_STEPS[i]
            if kind in step["done"] and (kind != "step" or tour["n"] >= step["need"]):
                self._tour_advance(i + 1)
                return
        if self.clock() - self.last_prompt < TOUR_REPROMPT_S:
            return
        if tour["prompts"] >= TOUR_MAX_PROMPTS:  # asked enough: move on rather than stall
            tour["skipped"].append(TOUR_STEPS[tour["step"]]["id"])
            self._tour_advance(tour["step"] + 1)
        else:
            self._tour_say()

    def _tour_advance(self, nxt):
        tour = self.state["tour"]
        tour["n"], tour["prompts"] = 0, 0
        tour["step"] = min(nxt, len(TOUR_STEPS) - 1)
        self.dirty = True
        self._tour_say()


class NoGuide:
    """What the dial uses until the daemon starts the real guide (and in most tests)."""

    def event(self, kind):
        pass

    def armed(self, name, rest=False):
        pass

    def attached(self):
        pass

    def flush(self):
        pass


GUIDE = NoGuide()


def guide_path():
    return os.path.join(os.path.dirname(CONFIG_PATH), "progress.json")


def guide_enabled():
    """Whether hints are shown (config "guide", and never while the on-screen display is off)."""
    return live_bool("guide", True) and osd_enabled()


def guide_mode():
    """The introduction style (config "onboarding_mode"); anything unrecognised is adaptive."""
    v = live_config().get("onboarding_mode")
    return v if v in GUIDE_MODES else "adaptive"


def tool_lines(name):
    """What the per-tool hints say about `name`: {"intro": turning, "click": its click}."""
    lib = next((t for t in TOOL_LIBRARY if t["name"] == name), None)
    spec = next((t for t in TOOLS if t["name"] == name), None)
    lines = {}
    if lib and lib.get("description"):
        lines["intro"] = f"{name}: {lib['description'].split('. ')[0].rstrip('.')}"
    label = click_hint(spec) if spec else ""
    if label and label != "—":
        lines["click"] = f"{name}: click to {label}"
    return lines


def _say_sync(text, meta=None):
    if not overlay_note("hint", dict(meta or {}, prompt=text)):
        osd(message=text, duration=3500)


def guide_say(text, meta=None):
    ACTIONS.submit(_say_sync, text, meta)
