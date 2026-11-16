"""The command line: --version, --help and --reset-guide are answered here, before the daemon
module loads (importing it writes the tool manifest and reads the tools)."""

import argparse
import os
import subprocess
import sys

from . import __version__
from .paths import CONFIG_PATH


def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        prog="redial-hypr",
        description="re:dial: Surface Dial and Surface Pen control daemon for Hyprland/Omarchy.",
        epilog=f"Config: {CONFIG_PATH}. Docs: plugin/redial/README.md",
    )
    ap.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    ap.add_argument(
        "--reset-guide",
        action="store_true",
        help="forget the introduction's progress so it starts again (stop the daemon first)",
    )
    return ap.parse_args(argv)


def reset_guide_file(path, running):
    """Delete the guide's progress file. Returns (exit code, message).

    Refuses while the daemon runs: it keeps progress in memory and would write it straight back.
    """
    if running:
        return (
            1,
            "The dial service is running. Stop it first (pkill -f redial-hypr), then retry.",
        )
    try:
        os.remove(path)
    except FileNotFoundError:
        return 0, "Nothing to reset: the introduction has not started yet."
    except OSError as exc:
        return 1, f"Could not remove {path}: {exc}"
    return 0, "The introduction will start again. Start the dial service (redial-restart)."


def main(argv=None):
    args = parse_args(argv)  # --help/--version exit here, before any side effects
    if args.reset_guide:
        running = (
            subprocess.run(
                ["pgrep", "-f", "^python3 .*redial-hypr$"], capture_output=True
            ).returncode
            == 0
        )
        code, msg = reset_guide_file(
            os.path.join(os.path.dirname(CONFIG_PATH), "progress.json"), running
        )
        print(msg)
        sys.exit(code)
    from . import daemon

    daemon.main()
