#!/usr/bin/env bash
# install.sh -- install the Surface Dial (and Surface Pen) daemon and the
# dial.radial Quickshell plugin from this repo.
#
# Run it yourself, in a terminal INSIDE your Hyprland session (it needs the
# session's env for `omarchy-shell`, and it asks for sudo itself -- nothing
# here is ever run with sudo on your behalf).
#
# The shortest path on Omarchy:
#     omarchy plugin add https://github.com/bybrooksco/surface-dial.git --enable
#     ~/.config/omarchy/plugins/dial.radial/install.sh
#
# Safe to re-run. It shows what it will do and asks once; the steps that restart the
# shell, use sudo, or touch another project's files are asked about separately. Pass -y to
# accept everything. Anything it would overwrite is copied to
# ~/.local/share/dial-kit-backups/<timestamp>/ first.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/share/dial-kit-backups/$STAMP"
ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

CHANGED_DAEMON=0   # a new daemon file was installed: the running process still has the old one
CHANGED_PLUGIN=0   # new plugin files were copied: the shell keeps the old QML until restarted
SHELL_RESTARTED=0
ok()   { printf '  [OK]   %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
confirm() {
    (( ASSUME_YES )) && return 0
    read -rp "  $1 [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}
# backup_then <path>: move an existing path into the backup dir.
backup() {
    local t="$1"
    [[ -e "$t" || -L "$t" ]] || return 0
    mkdir -p "$BACKUP$(dirname "$t")"
    mv "$t" "$BACKUP$t" && printf '         backed up old %s -> %s\n' "$t" "$BACKUP$t"
}

echo "== Surface Dial install ($(hostname), $STAMP) =="
echo "   repo: $R"
echo

# Installed with `omarchy plugin add`? Then this checkout already IS the plugin folder.
PLUGIN_HOME="$HOME/.config/omarchy/plugins/dial.radial"
IN_PLUGIN_DIR=0
[[ -d "$PLUGIN_HOME" && "$(realpath "$R")" == "$(realpath "$PLUGIN_HOME")" ]] && IN_PLUGIN_DIR=1

cat <<PLAN
For your user only, no sudo:
  * the daemon and helper scripts      -> ~/.local/bin
  * the dial.radial plugin             -> ~/.config/omarchy/plugins (already there if you used 'omarchy plugin add')
  * start the daemon at login          -> one line in ~/.config/hypr/autostart.lua
  * a "Surface Dial" menu entry        -> Omarchy menu > Setup
Asked about separately: enabling the plugin (restarts the shell for a few seconds), the udev
rule and 'input' group (sudo), and the Rise bar widget if you use that bar.
Anything overwritten is copied to $BACKUP first.

PLAN
confirm "Go ahead?" || { echo "Nothing changed."; exit 0; }
echo

echo "-- 1. Dependencies --"
if command -v playerctl >/dev/null; then
    ok "playerctl present (Media tool)"
else
    warn "playerctl missing -- the Media tool needs it (everything else works without)"
    if command -v omarchy-pkg-add >/dev/null; then
        confirm "Install it now (omarchy-pkg-add playerctl)?" && omarchy-pkg-add playerctl
    else
        confirm "Install it now (sudo pacman -S --needed playerctl)?" && sudo pacman -S --needed playerctl
    fi
fi
# have CMD OK-TEXT WARN-TEXT -- report whether an optional tool is installed.
have() {
    if command -v "$1" >/dev/null; then ok "$2"; else warn "$3"; fi
}
for b in wtype wpctl hyprctl bluetoothctl omarchy-shell; do
    have "$b" "$b" "$b not found -- the daemon needs it"
done
if command -v omarchy-notification-send >/dev/null; then
    ok "omarchy-notification-send (on-screen messages)"
else
    have notify-send "notify-send (on-screen messages)" \
        "no notifier found -- the dial's on-screen messages won't show (everything else works)"
fi
have dbus-monitor "dbus-monitor (Bluetooth auto-recovery on resume)" \
    "dbus-monitor not found -- the dial won't auto-reconnect after suspend/resume (everything else works)"
have voxtype "voxtype (double-click dictation)" \
    "voxtype not found -- double-click dictation will do nothing"
have brightnessctl "brightnessctl (Brightness tool)" \
    "brightnessctl not found -- the Brightness tool will do nothing"
have jq "jq (bar button status line)" \
    "jq not found -- the bar button loses its click summary (everything else works)"

echo
echo "-- 2. Daemon + setup script -> ~/.local/bin --"
mkdir -p "$HOME/.local/bin"
for f in surface-dial-hypr surface-dial-setup surface-dial-bar surface-dial-rise-widget; do
    if cmp -s "$R/bin/$f" "$HOME/.local/bin/$f"; then
        skip "$f already identical"
    else
        backup "$HOME/.local/bin/$f"
        install -m 755 "$R/bin/$f" "$HOME/.local/bin/$f" && ok "$f installed"
        [[ "$f" == surface-dial-hypr ]] && CHANGED_DAEMON=1
    fi
done

echo
echo "-- 3. dial.radial plugin -> ~/.config/omarchy/plugins --"
DEST="$PLUGIN_HOME"
if (( IN_PLUGIN_DIR )); then
    skip "this checkout is the plugin folder (added with 'omarchy plugin add'); update it with: omarchy plugin update dial.radial"
elif [[ -d "$DEST" ]] && diff -rq "$R/plugin/dial.radial" "$DEST" >/dev/null 2>&1; then
    skip "plugin already identical"
else
    backup "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -a "$R/plugin/dial.radial" "$DEST" && ok "plugin installed" && CHANGED_PLUGIN=1
fi

echo
echo "-- 4. Config (~/.config/dial-radial/config.json) --"
CFG="$HOME/.config/dial-radial/config.json"
if [[ -f "$CFG" ]]; then
    skip "config exists -- leaving it alone"
else
    skip "no config -- every value has a default, the plugin runs fine with none"
    echo "         to customize, see $R/plugin/dial.radial/config.example.json"
fi

echo
echo "-- 5. Start at login + Omarchy menu entry --"
AUTOSTART="$HOME/.config/hypr/autostart.lua"
if grep -q 'launch_on_start("surface-dial-hypr")' "$AUTOSTART" 2>/dev/null; then
    skip "autostart entry already present"
else
    backup_copy="$BACKUP$AUTOSTART"; mkdir -p "$(dirname "$backup_copy")"; cp -a "$AUTOSTART" "$backup_copy" 2>/dev/null
    cat "$R/config/autostart.snippet.lua" >> "$AUTOSTART" && ok "autostart added"
fi
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if grep -q '"setup.surface-dial"' "$MENU_EXT" 2>/dev/null; then
    skip "menu entry already present"
else
    backup_copy="$BACKUP$MENU_EXT"; mkdir -p "$(dirname "$backup_copy")"; cp -a "$MENU_EXT" "$backup_copy" 2>/dev/null
    if python3 "$R/scripts/add-menu-entry.py" "$MENU_EXT"; then
        ok "added Setup > Surface Dial to the Omarchy menu"
    else
        warn "could not edit $MENU_EXT -- your file was left untouched; open settings with: omarchy-shell dialtools toggle"
    fi
fi

echo
echo "-- 6. Enable the Quickshell plugin --"
if command -v omarchy-shell >/dev/null; then
    if [[ "$(omarchy-shell dialmenu ping 2>/dev/null)" == "ok" ]]; then
        skip "plugin already enabled and answering IPC"
    elif confirm "Enable dial.radial and restart the shell?"; then
        omarchy-shell shell setPluginEnabled dial.radial true
        omarchy-restart-shell 2>/dev/null || warn "omarchy-restart-shell failed -- run it by hand"
        SHELL_RESTARTED=1
        # A freshly copied plugin is only discovered once the restarted shell is up,
        # and an enable sent before that is silently dropped. So keep asking until
        # the plugin actually answers.
        enabled=0
        for _ in $(seq 1 15); do
            omarchy-shell shell setPluginEnabled dial.radial true >/dev/null 2>&1
            if [[ "$(omarchy-shell dialmenu ping 2>/dev/null)" == "ok" ]]; then enabled=1; break; fi
            sleep 1
        done
        if (( enabled )); then ok "enabled and answering IPC"
        else warn "plugin still not answering -- run: omarchy-shell shell setPluginEnabled dial.radial true"; fi
    fi
fi

echo
echo "-- 6b. Surface Dial button in the bar (Quickshell Rise) --"
RISE_TOOL="$HOME/.local/bin/surface-dial-rise-widget"
if [[ -f "$HOME/.config/quickshell/bar/variants/V2/BarSlot.qml" ]]; then
    if "$RISE_TOOL" --check; then
        skip "widget already in the Rise bar"
    elif confirm "Add the Surface Dial widget to the Rise bar (patches its V2 files, restarts the bar for a few seconds; switch it on afterwards in the control panel -> WIDGETS)?"; then
        if "$RISE_TOOL" --install; then
            ok "widget installed"
        else
            warn "widget install failed -- nothing was left half-applied; see the message above"
        fi
    fi
else
    skip "no Quickshell Rise bar here -- open settings from the Omarchy menu: Setup > Surface Dial"
fi

echo
echo "-- 7. Permissions (sudo) --"
UDEV=/etc/udev/rules.d/70-surface-dial.rules
if cmp -s "$R/udev/70-surface-dial.rules" "$UDEV" 2>/dev/null; then
    skip "udev rule already installed"
elif confirm "Install udev rule (sudo)?"; then
    sudo install -m 644 "$R/udev/70-surface-dial.rules" "$UDEV" \
        && sudo udevadm control --reload-rules && sudo udevadm trigger && ok "udev rule installed"
fi
if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
    ok "already in 'input' group (in this session)"
elif getent group input | grep -qw "$USER"; then
    warn "in 'input' per /etc/group but THIS SESSION predates it -- log out/in (or reboot)"
elif confirm "Add $USER to 'input' (sudo usermod -aG -- append, never bare -G)?"; then
    sudo usermod -aG input "$USER" \
        && warn "added. It only takes effect after you LOG OUT/IN or reboot -- do that before testing"
fi

echo
echo "-- 7b. Load the new version --"
# Replacing files does not change what is already running. The daemon is a long-lived process,
# and the shell ignores a changed DialMenu.qml until it restarts (its own "reloading" message
# notwithstanding), so an update would otherwise look installed but still run the old code.
DAEMON_RE='^python3 .*surface-dial-hypr'
start_daemon() {
    # Start it the way Omarchy's autostart does (through Hyprland, with the session's real
    # environment), not from this shell.
    if command -v hyprctl >/dev/null; then
        hyprctl dispatch "hl.dsp.exec_cmd(\"uwsm-app -- $HOME/.local/bin/surface-dial-hypr\")" >/dev/null
    else
        "$HOME/.local/bin/surface-dial-bar" restart
    fi
}
if pgrep -f "$DAEMON_RE" >/dev/null; then
    if (( CHANGED_DAEMON )); then
        if confirm "The daemon changed. Restart it now (the dial is unresponsive for a second or two)?"; then
            pkill -TERM -f "$DAEMON_RE"
            for _ in $(seq 1 15); do pgrep -f "$DAEMON_RE" >/dev/null || break; sleep 0.2; done
            start_daemon && ok "daemon restarted on the new version"
        else
            warn "daemon not restarted -- it is still running the old version until you do"
        fi
    else
        skip "daemon already on this version"
    fi
elif confirm "The daemon is not running. Start it now (it also starts at login)?"; then
    start_daemon && ok "daemon started"
fi
# No ping check here: right after the plugin files change the shell may be mid-reload and not answer,
# which is exactly when the restart is needed (an earlier version skipped it silently then).
if (( CHANGED_PLUGIN && ! SHELL_RESTARTED )) && command -v omarchy-restart-shell >/dev/null; then
    if confirm "The plugin changed. Restart the shell (a few seconds) to load it?"; then
        if omarchy-restart-shell 2>/dev/null; then
            ok "shell restarted"
        else
            warn "omarchy-restart-shell failed -- run it by hand"
        fi
    else
        warn "shell not restarted -- the overlay keeps the old version until you run: omarchy-restart-shell"
    fi
fi

echo
echo "-- 8. Doctor report --"
"$HOME/.local/bin/surface-dial-setup" </dev/null || true

cat <<EOF

== Done. Open the settings: Omarchy menu (SUPER+SPACE) > Setup > Surface Dial ==
Remaining by hand:
  * If the 'input' group was just added: log out/in (or reboot) FIRST.
  * Pair the dial: hold its button ~5-7s (LED flashes), then run
        bash $R/scripts/pair-dial.sh
  * Old files (if any) were backed up under: $BACKUP
EOF
