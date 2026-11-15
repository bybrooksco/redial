"""Where re:dial keeps its files. The one rule every program follows (the GTK overlay, the settings
window and the bar copy it, and tests/test_dial.py checks they agree)."""

import os

# DIAL_CONFIG_DIR exists so tests can import the daemon away from the real config.
CONFIG_DIR = os.environ.get("DIAL_CONFIG_DIR") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "redial"
)
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
