"""What the tools turn: volume, the media player, screen brightness; and showing the new level."""

import subprocess
import threading
import time

from .config import BRIGHT_MIN, BRIGHT_STEP, SEEK_STEP_S, osd_enabled
from .feedback import (
    MENU_NOTES,
    MenuUI,
    backlight_device,
    cant_note,
    osd,
    read_brightness,
    turn_note,
)
from .log import log
from .system import ACTIONS, run
from .wm import window_label

_media = {"at": 0.0, "pick": None, "last": None}
_seek_warned = 0.0


def _media_rows():
    """[(instance, status)] for every MPRIS player, in playerctl's order.

    [] when none or no playerctl."""
    try:
        p = subprocess.run(
            ["playerctl", "-a", "metadata", "--format", "{{playerInstance}}\t{{status}}"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [tuple(ln.split("\t")[:2]) for ln in p.stdout.splitlines() if "\t" in ln]


def pick_player(rows, last):
    """The one player the Media tool works on, for turning, clicking and the readout alike.

    By full instance ("firefox.instance_1_68"), never by app name: `-p firefox` means whichever
    Firefox player playerctl lists first, which is how a scrub or a click landed on another tab.
    A playing player wins; among several, the one re:dial last worked on. With nothing playing,
    the one it last worked on (so a click resumes what it paused), else the first paused one.
    """
    names = [r[0] for r in rows]
    playing = [r[0] for r in rows if r[1] == "Playing"]
    if playing:
        return last if last in playing else playing[0]
    if last in names:
        return last
    return next((r[0] for r in rows if r[1] == "Paused"), names[0] if names else None)


def media_player(fresh=False):
    """pick_player() over the live players. Cached briefly: a fast spin fires several detents a
    second and asking playerctl costs a subprocess."""
    now = time.monotonic()
    if fresh or now - _media["at"] >= 2.0:
        _media.update(at=now, pick=pick_player(_media_rows(), _media["last"]))
    return _media["pick"]


def _playerctl(player, *args):
    p = subprocess.run(
        ["playerctl", *(["-p", player] if player else []), *args],
        capture_output=True,
        text=True,
        timeout=3,
    )
    if player:
        _media["last"] = player
    return p


def media_command(op):
    """Play/pause, next or previous on the same player the Media tool scrubs."""
    try:
        _playerctl(media_player(fresh=True), op)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"{op} raised {exc}")
    _media["at"] = 0.0  # its status just changed


def media_reading(player):
    """(percent or None, "1:23 / 4:56  title") for the overlay, or None when nothing answers."""
    if not player:
        return None
    try:
        p = _playerctl(
            player, "metadata", "--format", "{{position}}\t{{mpris:length}}\t{{xesam:title}}"
        )
    except (OSError, subprocess.SubprocessError):
        return None
    parts = (p.stdout.strip().split("\t") + ["", "", ""])[:3]

    def clock(us):
        s = int(us) // 1_000_000
        return (
            f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}"
            if s >= 3600
            else f"{s // 60}:{s % 60:02d}"
        )

    try:
        pos, length = int(parts[0] or 0), int(parts[1] or 0)
    except ValueError:
        return None
    title = parts[2][:40]
    if length <= 0:
        return None, title or player.split(".")[0]
    return round(100 * pos / length), f"{clock(pos)} / {clock(length)}  {title}".strip()


def seek_media(forward, mag=1, step=SEEK_STEP_S):
    """Scrub the Media tool's player by `step` seconds, doubled per speed step.

    Uses MPRIS through playerctl, so it moves a song, a Jellyfin/browser video, VLC or anything
    else that reports a position. Failures (nothing playing, a player that can't seek) are logged
    at most every 5 s -- a spin fires many detents -- and said on screen once.
    """
    global _seek_warned
    secs = step * (2 ** (max(1, int(mag)) - 1))
    player = media_player()
    if player is None:
        if time.monotonic() - _seek_warned > 5:
            _seek_warned = time.monotonic()
            cant_note("tool", "Media can't act", "Nothing is playing")
        return
    try:
        p = _playerctl(player, "position", f"{secs:g}{'+' if forward else '-'}")
    except Exception as exc:
        log(f"seek raised {exc}")
        return
    if p.returncode != 0 and time.monotonic() - _seek_warned > 5:
        _seek_warned = time.monotonic()
        log(f"seek failed on {player}: {(p.stderr or p.stdout).strip()[:120]}")
        cant_note("tool", "Media can't scrub", f"{player.split('.')[0]} doesn't allow seeking")
        return
    show_level("media")


def vol(mag, up):
    pct = f"{mag}%{'+' if up else '-'}"
    cmd = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", pct]
    if up:
        cmd += ["-l", "1.0"]
    run(cmd)
    show_level("volume")


_level_pending = set()


def show_level(kind):
    """Show the current volume or brightness on screen, once per burst of turning.

    The job reads the level when it runs, not when it was queued, so one waiting job always
    shows the latest value and a fast spin cannot back the action queue up with overlays.
    """
    if not osd_enabled() or kind in _level_pending:
        return
    _level_pending.add(kind)
    ACTIONS.submit(_show_level, kind)


def _show_level(kind):
    wait = MENU_NOTES.turn_wait()
    if wait > 0:  # the overlay takes ~10 readouts a second; this job reads the level when it fires
        threading.Timer(wait, ACTIONS.submit, (_show_level, kind)).start()
        return
    _level_pending.discard(kind)
    if kind == "volume":
        v = MenuUI._volume()
        if v is not None:
            pct, text = v
            if not turn_note("Volume", pct, text):
                osd(icon="volume-muted" if text == "muted" else "volume", progress=pct)
    elif kind == "media":
        r = media_reading(media_player())
        if r is not None and not turn_note("Media", r[0], r[1]):
            osd(message=f"\uf001  {r[1]}")
    elif kind == "window":
        label = window_label()
        if label and not turn_note("Windows", None, label):
            osd(message=label)
    elif kind == "brightness":
        pct = read_brightness()
        if pct is not None and not turn_note("Brightness", pct, f"{pct}%"):
            osd(icon="brightness", progress=pct)


_bright_warned = False
_bright_said = [-1e9]  # when the "no backlight" message was last shown


def set_brightness(mag, up, step=BRIGHT_STEP, device=None):
    """Nudge the screen backlight by `step` percent x magnitude, clamped to 1..100."""
    global _bright_warned
    dev = device or backlight_device()
    cur = read_brightness(dev)
    if cur is None:
        if not _bright_warned:
            _bright_warned = True
            log("brightness: no readable backlight device on this machine")
        # Silence reads as a broken dial: say why nothing happened (at most every few seconds).
        if time.monotonic() - _bright_said[0] > 3.0:
            _bright_said[0] = time.monotonic()
            cant_note("tool", "Brightness can't act", "No screen backlight on this machine")
        return
    delta = int(step) * max(1, int(mag))
    new = max(BRIGHT_MIN, min(100, cur + (delta if up else -delta)))
    if new != cur:
        run(["brightnessctl", "-q", "-d", dev, "set", f"{new}%"])
    show_level("brightness")
