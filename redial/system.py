"""Process plumbing: the action worker, the single-instance lock, private files, programs."""

import fcntl
import json
import os
import queue
import subprocess
import threading

from .log import LOG_PATH, log
from .paths import CONFIG_PATH


class Actions:
    """Runs tool actions off the input thread, one at a time, in order.

    An action is a subprocess or a Hyprland query; run on the thread that reads the dial it
    stalls rotation for as long as it takes. A single worker keeps strict ordering (a
    resize's read-then-dispatch stays sequential) and contains any exception an action
    raises, which used to propagate out of the read loop. `inline` runs actions on the
    caller's thread instead; the tests use it so they can assert straight after a gesture.
    """

    def __init__(self):
        self.inline = False
        self.q = queue.Queue(maxsize=64)
        self._started = False

    def submit(self, fn, *args):
        if self.inline:
            fn(*args)
            return
        if not self._started:
            self._started = True
            threading.Thread(target=self._worker, daemon=True).start()
        try:
            self.q.put_nowait((fn, args))
        except queue.Full:
            log("action queue full; dropped one")

    def _worker(self):
        while True:
            fn, args = self.q.get()
            try:
                fn(*args)
            except Exception as exc:
                log(f"action failed: {exc}")


ACTIONS = Actions()


def single_instance(path=None):
    """Hold the daemon's lock for as long as it runs; False when another daemon already holds it.

    Two daemons would both read the dial, so every turn would act twice. The lock dies with the
    process, so a crash never leaves it stuck."""
    if getattr(single_instance, "fd", None) is not None and path is None:
        return True  # this process already holds it
    if path is None:
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        path = os.path.join(runtime, "redial.lock") if runtime else LOG_PATH + ".lock"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    single_instance.fd = fd  # kept open (and locked) until the process ends
    return True


def make_private():
    """Keep the daemon's own files readable by this user only.

    The log can name windows and the config can name programs; there is no reason for another
    account on the machine to read either. New files get 0600 through the umask; files and
    folders made by earlier versions are tightened once, here. Best effort.
    """
    os.umask(0o077)
    state = os.path.dirname(LOG_PATH)
    config = os.path.dirname(CONFIG_PATH)
    for path, mode in [(state, 0o700), (config, 0o700)] + [
        (os.path.join(d, n), 0o600)
        for d in (state, config)
        if os.path.isdir(d)
        for n in os.listdir(d)
        if os.path.isfile(os.path.join(d, n))
    ]:
        try:
            if os.path.exists(path):
                os.chmod(path, mode)
        except OSError:
            pass


def write_json_atomic(path, doc, **dump_kw):
    """Write `doc` as JSON so a reader (the settings window, the shell) never sees half a file.

    Writes a temp file beside it, then renames. Raises OSError; callers decide how much it matters.
    """
    tmp = f"{path}.{os.getpid()}.tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, **dump_kw)
    os.replace(tmp, path)


def launch(cmd):
    """Start a program and leave it running; never wait for it or kill it.

    For things the user opens (launchers, the assistant), which may stay open for hours. run()
    waits for the command and kills it after 5 s, and it holds the one action worker meanwhile,
    which is right for short commands whose output we check and wrong here.
    """
    try:
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        log(f"{cmd[0]} could not start: {exc}")
        return
    threading.Thread(target=p.wait, daemon=True).start()  # reap it when it exits


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except Exception as exc:
        log(f"{cmd[0]} raised {exc}")
        return
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    # hyprctl exits 0 even when its Lua dispatcher fails -- check the text.
    if p.returncode != 0 or out.lower().startswith("error"):
        log(f"{cmd[0]} failed: {out[:200]}")
        return False
    return True
