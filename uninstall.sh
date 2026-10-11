#!/usr/bin/env bash
# uninstall.sh -- remove what install.sh put on this machine.
#
# Run it yourself, in a terminal inside your Hyprland session. It shows what it will do and
# asks once. Everything it removes is moved to ~/.local/share/redial-backups/uninstall-<time>/
# first, so nothing is lost. It never edits system files without asking, and it never touches
# your settings unless you pass --purge.
#
#   ./uninstall.sh            remove the program, keep your settings (~/.config/redial)
#   ./uninstall.sh --purge    also move your settings and the daemon log to the backup
#   ./uninstall.sh -y         do not ask (the sudo step is then skipped and printed instead)
#
# Safe to re-run: anything already gone is skipped.
set -u

R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/share/redial-backups/uninstall-$STAMP"
ASSUME_YES=0
PURGE=0
for a in "$@"; do
    case "$a" in
        -y) ASSUME_YES=1 ;;
        --purge) PURGE=1 ;;
        -h | --help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done

ok()   { printf '  [OK]   %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
confirm() {
    (( ASSUME_YES )) && return 0
    read -rp "  $1 [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}
# stash <path>: move it into the backup folder (keeping its path), so removal is reversible.
stash() {
    local t="$1"
    [[ -e "$t" || -L "$t" ]] || return 1
    mkdir -p "$BACKUP$(dirname "$t")"
    mv "$t" "$BACKUP$t"
}

BINS=(redial-hypr redial-setup redial-restart redial-bar redial-rise-widget)
PLUGIN="$HOME/.config/omarchy/plugins/redial"
AUTOSTART="$HOME/.config/hypr/autostart.lua"
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
UNIT="$HOME/.config/systemd/user/redial.service"
UDEV="${DIAL_UDEV_RULE:-/etc/udev/rules.d/70-redial.rules}"  # the override is for tests

echo "== re:dial uninstall ($(hostname), $STAMP) =="
cat <<PLAN

This will, for your user only (no sudo):
  * stop the daemon
  * remove ${BINS[*]// /, } from ~/.local/bin
  * remove the plugin folder ~/.config/omarchy/plugins/redial
  * remove the start-at-login lines from ~/.config/hypr/autostart.lua
  * remove Setup > re:dial from the Omarchy menu
Everything removed is moved to $BACKUP first.
Your settings (~/.config/redial) are $( ((PURGE)) && echo "moved to the backup too (--purge)" || echo "kept; pass --purge to remove them as well" ).
The udev rule and 'input' group (system-wide) are asked about separately.

PLAN
confirm "Go ahead?" || { echo "  Nothing changed."; exit 0; }

echo
echo "-- 1. Stop the daemon --"
RE='^python3 .*redial-hypr'
if pgrep -f "$RE" >/dev/null; then
    pkill -TERM -f "$RE"
    for _ in $(seq 1 15); do pgrep -f "$RE" >/dev/null || break; sleep 0.2; done
    if pgrep -f "$RE" >/dev/null; then
        warn "daemon still running -- stop it by hand: pkill -f redial-hypr"
    else
        ok "daemon stopped"
    fi
else
    skip "daemon not running"
fi
if command -v systemctl >/dev/null && systemctl --user is-enabled redial.service >/dev/null 2>&1; then
    systemctl --user disable --now redial.service >/dev/null 2>&1 && ok "systemd unit disabled"
fi
[[ -f "$UNIT" ]] && stash "$UNIT" && ok "systemd unit file removed"

echo
echo "-- 2. Programs in ~/.local/bin --"
# Ask the Rise-bar tool before it is removed whether it patched that bar.
RISE_INSTALLED=0
if [[ -x "$HOME/.local/bin/redial-rise-widget" ]] \
    && "$HOME/.local/bin/redial-rise-widget" --check >/dev/null 2>&1; then
    RISE_INSTALLED=1
fi
for f in "${BINS[@]}"; do
    if stash "$HOME/.local/bin/$f"; then ok "$f removed"; else skip "$f not installed"; fi
done

echo
echo "-- 3. Plugin --"
if [[ -d "$PLUGIN" || -L "$PLUGIN" ]]; then
    if command -v omarchy-shell >/dev/null; then
        omarchy-shell shell setPluginEnabled redial false >/dev/null 2>&1 || true
    fi
    stash "$PLUGIN" && ok "plugin folder removed (the shell lets go of it the next time it restarts)"
else
    skip "plugin not installed"
fi

echo
echo "-- 4. Start at login + menu entry --"
if grep -q 'launch_on_start("redial-hypr")' "$AUTOSTART" 2>/dev/null; then
    mkdir -p "$BACKUP$(dirname "$AUTOSTART")" && cp -a "$AUTOSTART" "$BACKUP$AUTOSTART"
    tmp="$(mktemp)"
    # Drop only what install.sh added: a blank line, its comment line, and the launch line.
    awk '
        $0 == "" { if (held) print ""; held = 1; next }
        {
            if (held) {
                held = 0
                if (index($0, "-- re:dial daemon. Source:") == 1) next
                print ""
            }
            if (index($0, "launch_on_start(\"redial-hypr\")")) next
            print
        }
        END { if (held) print "" }
    ' "$AUTOSTART" > "$tmp" && cat "$tmp" > "$AUTOSTART" && ok "autostart lines removed"
    rm -f "$tmp"
else
    skip "no autostart entry"
fi
if grep -q '"setup.redial"' "$MENU_EXT" 2>/dev/null; then
    mkdir -p "$BACKUP$(dirname "$MENU_EXT")" && cp -a "$MENU_EXT" "$BACKUP$MENU_EXT"
    if python3 "$R/scripts/add-menu-entry.py" --remove "$MENU_EXT"; then
        ok "menu entry removed"
    else
        warn "could not remove the menu entry automatically; delete the \"setup.redial\" lines from $MENU_EXT"
    fi
else
    skip "no menu entry"
fi

echo
echo "-- 5. Your settings --"
if (( PURGE )); then
    stash "$HOME/.config/redial" && ok "settings moved to the backup"
    stash "$HOME/.local/state/redial" && ok "daemon log moved to the backup"
else
    skip "settings kept in ~/.config/redial (use --purge to remove them)"
fi

echo
echo "-- 6. Bar widget (Quickshell Rise) --"
if (( RISE_INSTALLED )); then
    warn "the Rise bar widget is installed; it patches that bar's own files, so it is left alone. Your install made backups under ~/.local/share/redial-backups/ to restore from"
else
    skip "no Rise bar widget"
fi

echo
echo "-- 7. Permissions (sudo, system-wide) --"
if [[ -f "$UDEV" ]]; then
    if (( ASSUME_YES )); then
        warn "udev rule left in place (-y never uses sudo). To remove it: sudo rm $UDEV && sudo udevadm control --reload-rules"
    elif confirm "Remove the udev rule $UDEV (sudo)?"; then
        sudo rm -f "$UDEV" && sudo udevadm control --reload-rules && ok "udev rule removed"
    else
        skip "udev rule kept"
    fi
else
    skip "no udev rule"
fi
echo "         (Your membership of the 'input' group is not changed; other things may need it.)"

echo
echo "== Done. =="
echo "   Removed items are in $BACKUP (move them back to undo)."
echo "   If the dial overlay is still on screen, run: omarchy-restart-shell"
