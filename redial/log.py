"""The daemon's log file, and debug chatter that only shows with DIAL_DEBUG set."""

import os
import sys
import threading
import time


# The daemon's own log. Started the Omarchy way its stderr is /dev/null, so this file is the only
# record of connects, disconnects and errors. One rotation: daemon.log and daemon.log.1.
LOG_PATH = os.environ.get("DIAL_LOG_PATH") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "redial",
    "daemon.log",
)
LOG_MAX_BYTES = 256 * 1024
_log_lock = threading.Lock()


def _append_log(line):
    try:
        with _log_lock:
            os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
            try:
                if os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
                    os.replace(LOG_PATH, LOG_PATH + ".1")
            except FileNotFoundError:
                pass
            with open(LOG_PATH, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
    except OSError:
        pass  # logging must never take the daemon down


def log(msg):
    print(f"redial: {msg}", file=sys.stderr, flush=True)
    _append_log(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}")


DEBUG = bool(os.environ.get("DIAL_DEBUG"))


def debug(msg):
    """Per-detent and per-press chatter; off unless DIAL_DEBUG is set (it goes to the journal)."""
    if DEBUG:
        log(msg)
