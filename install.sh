#!/usr/bin/env bash
# install.sh -- install the Surface Dial (and Surface Pen) daemon and the
# dial.radial Quickshell plugin from this repo.
#
# Run it yourself, in a terminal INSIDE your Hyprland session (it needs the
# session's env for `omarchy-shell`, and it asks for sudo itself -- nothing
# here is ever run with sudo on your behalf).
#
# Safe to re-run. Every change is behind its own y/N prompt (or pass -y for
# all), and anything it would overwrite is copied to
# ~/.local/share/dial-kit-backups/<timestamp>/ first.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/share/dial-kit-backups/$STAMP"
ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

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

echo "-- 1. Dependencies --"
if command -v playerctl >/dev/null; then
    ok "playerctl present (Media tool)"
else
    warn "playerctl missing -- the Media tool needs it (everything else works without)"
    echo "         sudo pacman -S --needed playerctl"
    confirm "Run that now?" && sudo pacman -S --needed playerctl
fi
for b in wtype wpctl hyprctl bluetoothctl notify-send omarchy-shell; do
    command -v "$b" >/dev/null && ok "$b" || warn "$b not found -- the daemon needs it"
done
command -v dbus-monitor >/dev/null && ok "dbus-monitor (Bluetooth auto-recovery on resume)" \
    || warn "dbus-monitor not found -- the dial won't auto-reconnect after suspend/resume (everything else works)"
command -v voxtype >/dev/null && ok "voxtype (double-click dictation)" \
    || warn "voxtype not found -- double-click dictation will do nothing"
command -v brightnessctl >/dev/null && ok "brightnessctl (Brightness tool)" \
    || warn "brightnessctl not found -- the Brightness tool will do nothing"
command -v jq >/dev/null && ok "jq (bar button status line)" \
    || warn "jq not found -- the bar button loses its click summary (everything else works)"

echo
echo "-- 2. Daemon + setup script -> ~/.local/bin --"
mkdir -p "$HOME/.local/bin"
for f in surface-dial-hypr surface-dial-setup surface-dial-bar surface-dial-rise-widget; do
    if cmp -s "$R/bin/$f" "$HOME/.local/bin/$f"; then
        skip "$f already identical"
    elif confirm "Install $f?"; then
        backup "$HOME/.local/bin/$f"
        install -m 755 "$R/bin/$f" "$HOME/.local/bin/$f" && ok "$f installed"
    fi
done

echo
echo "-- 3. dial.radial plugin -> ~/.config/omarchy/plugins --"
DEST="$HOME/.config/omarchy/plugins/dial.radial"
if [[ -d "$DEST" ]] && diff -rq "$R/plugin/dial.radial" "$DEST" >/dev/null 2>&1; then
    skip "plugin already identical"
elif confirm "Install plugin?"; then
    backup "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -a "$R/plugin/dial.radial" "$DEST" && ok "plugin installed"
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
echo "-- 5. Hyprland autostart + tool-picker keybinding --"
AUTOSTART="$HOME/.config/hypr/autostart.lua"
BINDINGS="$HOME/.config/hypr/bindings.lua"
if grep -q 'launch_on_start("surface-dial-hypr")' "$AUTOSTART" 2>/dev/null; then
    skip "autostart entry already present"
elif confirm "Append daemon autostart to $AUTOSTART?"; then
    backup_copy="$BACKUP$AUTOSTART"; mkdir -p "$(dirname "$backup_copy")"; cp -a "$AUTOSTART" "$backup_copy" 2>/dev/null
    cat "$R/config/autostart.snippet.lua" >> "$AUTOSTART" && ok "autostart added"
fi
if grep -q 'dialtools toggle' "$BINDINGS" 2>/dev/null; then
    skip "picker keybinding already present"
elif confirm "Append SUPER+SHIFT+CTRL+D picker binding to $BINDINGS?"; then
    backup_copy="$BACKUP$BINDINGS"; mkdir -p "$(dirname "$backup_copy")"; cp -a "$BINDINGS" "$backup_copy" 2>/dev/null
    cat "$R/config/bindings.snippet.lua" >> "$BINDINGS" && ok "binding added"
fi

echo
echo "-- 6. Enable the Quickshell plugin --"
if command -v omarchy-shell >/dev/null; then
    if [[ "$(omarchy-shell dialmenu ping 2>/dev/null)" == "ok" ]]; then
        skip "plugin already enabled and answering IPC"
    elif confirm "Enable dial.radial and restart the shell?"; then
        omarchy-shell shell setPluginEnabled dial.radial true
        omarchy-restart-shell 2>/dev/null || warn "omarchy-restart-shell failed -- run it by hand"
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
        "$RISE_TOOL" --install && ok "widget installed" || warn "widget install failed -- nothing was left half-applied; see the message above"
    fi
else
    skip "no Quickshell Rise bar here -- tool settings stay on SUPER+SHIFT+CTRL+D"
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
echo "-- 8. Doctor report --"
"$HOME/.local/bin/surface-dial-setup" </dev/null || true

cat <<EOF

== Done. Remaining by hand ==
  * If the 'input' group was just added: log out/in (or reboot) FIRST.
  * Pair the dial: hold its button ~5-7s (LED flashes), then run
        bash $R/scripts/pair-dial.sh
  * Old files (if any) were backed up under: $BACKUP
EOF
