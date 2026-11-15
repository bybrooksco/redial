#!/usr/bin/env bash
# install-generic.sh -- install the re:dial daemon on a desktop that is not Omarchy
# (KDE Plasma, GNOME/Ubuntu, COSMIC, plain Hyprland, Sway, niri, ...).
#
# You get the dial, haptics, tools and pen buttons, and (except on GNOME) redial-overlay, the tool
# ring drawn in your desktop's theme; redial-settings, a small window for the tools on the ring
# and the ring's style (in your app launcher as "re:dial settings"); and redial-bar, a Waybar
# module (config/waybar.snippet.jsonc). Levels show as notifications. Other settings live in
# ~/.config/redial/config.json.
# See docs/PLATFORMS.md for what works where.
#
#   bash install-generic.sh              install (asks before each sudo step)
#   bash install-generic.sh --uninstall  remove it again (keeps your settings)
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin/redial-hypr"
OVERLAY="$HOME/.local/bin/redial-overlay"
UNIT="$HOME/.config/systemd/user/redial.service"
OVERLAY_UNIT="$HOME/.config/systemd/user/redial-overlay.service"
DESKTOP="$HOME/.local/share/applications/redial-settings.desktop"
EXTRAS=(redial-settings redial-bar redial-restart)
UDEV=/etc/udev/rules.d/70-redial.rules
ok()   { printf '  [OK]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
confirm() { read -rp "  $1 [y/N] " ans; [[ "$ans" =~ ^[Yy] ]]; }

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl --user disable --now redial.service redial-overlay.service 2>/dev/null && ok "daemon stopped"
    rm -f "$UNIT" "$OVERLAY_UNIT" "$BIN" "$OVERLAY" "$DESKTOP" "${EXTRAS[@]/#/$HOME/.local/bin/}" \
        && systemctl --user daemon-reload \
        && ok "daemon, overlay and services removed"
    if [[ -e "$UDEV" ]] && confirm "Remove the udev rule $UDEV (sudo)?"; then
        sudo rm "$UDEV" && sudo udevadm control --reload-rules && ok "udev rule removed"
    fi
    echo "Your settings in ~/.config/redial were kept. You are still in the 'input' group."
    exit 0
fi

if [[ -d "$HOME/.config/omarchy" ]]; then
    warn "this looks like Omarchy -- use install.sh instead, which also installs the overlay"
    confirm "Continue with the daemon-only install anyway?" || exit 0
fi

echo "== re:dial daemon-only install =="
echo "-- 1. What this desktop has --"
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || { echo "python3 3.10 or newer is required"; exit 1; }
ok "python3 $(python3 -c 'import platform; print(platform.python_version())')"
# have CMD WHAT-IT-DOES -- report an optional tool and the package that provides it.
have() {
    if command -v "$1" >/dev/null; then ok "$1 ($2)"; else warn "$1 missing -- $2 won't work (package: ${3:-$1})"; fi
}
have bluetoothctl "pairing the dial" bluez
have wpctl "the Volume tool" "wireplumber"
have playerctl "the Media tool"
have brightnessctl "the Brightness tool"
have notify-send "on-screen messages" "libnotify-bin on Ubuntu/Debian, libnotify on Fedora/Arch"
OVERLAY_OK=0
if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
    warn "GNOME has no layer-shell, so the tool ring shows as notifications instead of an overlay"
elif python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("GtkLayerShell", "0.1")' 2>/dev/null; then
    ok "GTK and gtk-layer-shell (the tool ring overlay)"
    OVERLAY_OK=1
else
    warn "gtk-layer-shell missing -- the tool ring shows as notifications (package:"
    warn "  gir1.2-gtklayershell-0.1 on Ubuntu/Debian, gtk-layer-shell on Fedora/Arch); re-run after"
fi

echo "-- 2. Daemon -> ~/.local/bin, started at login by systemd --"
install -Dm755 "$R/bin/redial-hypr" "$BIN" && ok "redial-hypr installed"
mkdir -p "$(dirname "$UNIT")"
grep -v '^#' "$R/systemd/redial.service" > "$UNIT" && ok "user service written"
for f in "${EXTRAS[@]}"; do
    install -Dm755 "$R/bin/$f" "$HOME/.local/bin/$f" && ok "$f installed"
done
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<DESK
[Desktop Entry]
Type=Application
Name=re:dial settings
Comment=Choose the Surface Dial's tools and ring style
Exec=$HOME/.local/bin/redial-settings
Icon=preferences-desktop-peripherals
Categories=Settings;HardwareSettings;
DESK
ok "re:dial settings added to the app launcher"
have jq "the Waybar module's click summary"
if (( OVERLAY_OK )); then
    install -Dm755 "$R/bin/redial-overlay" "$OVERLAY" && ok "redial-overlay installed"
    grep -v '^#' "$R/systemd/redial-overlay.service" > "$OVERLAY_UNIT"
fi
systemctl --user daemon-reload
systemctl --user enable redial.service >/dev/null 2>&1 && ok "starts at login"
(( OVERLAY_OK )) && systemctl --user enable redial-overlay.service >/dev/null 2>&1 \
    && ok "overlay starts at login"

echo "-- 3. Permissions (sudo) --"
echo "   The dial is read from /dev/input and its haptics are written through /dev/hidraw;"
echo "   scroll and keys go through /dev/uinput. SECURITY.md says what this access means."
if cmp -s "$R/udev/70-redial.rules" "$UDEV" 2>/dev/null; then
    ok "udev rule already installed"
elif confirm "Install the udev rule (sudo)?"; then
    sudo install -m 644 "$R/udev/70-redial.rules" "$UDEV" \
        && sudo udevadm control --reload-rules && sudo udevadm trigger && ok "udev rule installed"
fi
WAKE=/etc/udev/rules.d/71-redial-wake.rules
if cmp -s "$R/udev/71-redial-wake.rules" "$WAKE" 2>/dev/null; then
    ok "wake-from-dial rule already installed"
elif confirm "Let the dial wake this computer from sleep (sudo; any paired Bluetooth keyboard or mouse can then wake it too)?"; then
    sudo install -m 644 "$R/udev/71-redial-wake.rules" "$WAKE" \
        && sudo udevadm control --reload-rules && sudo udevadm trigger -s usb && ok "wake-from-dial rule installed"
fi
NEED_RELOGIN=0
if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
    ok "already in the 'input' group"
elif confirm "Add $USER to the 'input' group (sudo usermod -aG input)?"; then
    sudo usermod -aG input "$USER" && NEED_RELOGIN=1
fi

echo
if (( NEED_RELOGIN )); then
    echo "Log out and back in (the group change needs a new session); the daemon starts by itself."
else
    systemctl --user restart redial.service && ok "daemon running"
    (( OVERLAY_OK )) && systemctl --user restart redial-overlay.service && ok "overlay running"
fi
echo "Pair the dial with: bash $R/scripts/pair-dial.sh"
echo "Its log: ~/.local/state/redial/daemon.log"
echo "Using Waybar? Add the module in $R/config/waybar.snippet.jsonc to your Waybar config."
