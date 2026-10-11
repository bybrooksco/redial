#!/usr/bin/env bash
# Surface Dial for Omarchy __VERSION__ (beta): self-extracting installer.
#
# One file. It contains the whole release (not Omarchy itself, which you need first:
# https://omarchy.org); run it with:   bash <this file>
# It does nothing until you have read a short notice and said yes, then it unpacks the release to
#   ~/.local/share/redial-beta/redial-__VERSION__/
# and runs that folder's install.sh, which shows its own plan and asks before every change.
# The unpacked folder stays so you can run its uninstall.sh later.
#
#   --extract-only   unpack the release and stop (nothing is installed)
#   --unattended     skip the notice and pass -y to install.sh (for scripts; it will use sudo
#                    for the udev rule and the input group without asking)
#   --version        print the version
set -u

VERSION="__VERSION__"
PAYLOAD_SHA256="__SHA256__"
DEST_ROOT="$HOME/.local/share/redial-beta"
EXTRACT_ONLY=0
UNATTENDED=0
for a in "$@"; do
    case "$a" in
        --extract-only) EXTRACT_ONLY=1 ;;
        --unattended) UNATTENDED=1 ;;
        --version) echo "$VERSION"; exit 0 ;;
        -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done

if [[ "$(id -u)" == 0 ]]; then
    echo "Please run this as your normal user, not root. It asks for sudo itself where needed." >&2
    exit 1
fi
if [[ ! -r "$0" || "$0" == bash || "$0" == -bash ]]; then
    echo "Please save this file and run it as:  bash redial-$VERSION-installer.sh" >&2
    exit 1
fi
for tool in tar base64 sha256sum awk; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "== Surface Dial for Omarchy $VERSION (beta) =="
echo
if ! command -v hyprctl >/dev/null || ! command -v omarchy-shell >/dev/null; then
    echo "  NOTE: this does not look like an Omarchy (Hyprland) session: hyprctl or omarchy-shell is"
    echo "        missing. The software is for Omarchy only and will not work elsewhere."
    echo "        Omarchy is a separate project and is not included here; you can get it at"
    echo "        https://omarchy.org"
    echo
fi

# Pull the payload (a base64 tar.gz after the marker line) out of this file, and check it.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LINE="$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0")"
[[ -n "$LINE" ]] || { echo "this installer is damaged (no payload found); please ask for a new copy" >&2; exit 1; }
tail -n +"$LINE" "$0" | base64 -d > "$WORK/release.tar.gz" 2>/dev/null \
    || { echo "this installer is damaged (payload unreadable); please ask for a new copy" >&2; exit 1; }
GOT="$(sha256sum "$WORK/release.tar.gz" | cut -d' ' -f1)"
if [[ "$GOT" != "$PAYLOAD_SHA256" ]]; then
    echo "this installer was changed or damaged in transit (checksum mismatch); please ask for a new copy" >&2
    exit 1
fi
echo "  [OK]   file is intact"

mkdir -p "$DEST_ROOT"
TARGET="$DEST_ROOT/redial-$VERSION"
if [[ -d "$TARGET" ]]; then
    mv "$TARGET" "$DEST_ROOT/redial-$VERSION.old-$(date +%Y%m%d-%H%M%S)"
fi
tar -xzf "$WORK/release.tar.gz" -C "$DEST_ROOT" || { echo "could not unpack" >&2; exit 1; }
[[ -f "$TARGET/install.sh" ]] || { echo "unexpected package layout; nothing installed" >&2; exit 1; }
echo "  [OK]   unpacked to $TARGET"

if (( EXTRACT_ONLY )); then
    echo
    echo "Unpacked only. Read $TARGET/BETA.md, then run:  bash $TARGET/install.sh"
    exit 0
fi

if (( ! UNATTENDED )); then
    cat <<'NOTICE'

  Before you continue, in plain words:

  * This is a BETA. It has been used on one machine by its author; you are among the first.
  * It installs for your user only. It will ask before using sudo, for two things: a udev
    rule so the dial can be read, and adding you to the 'input' group. Anything in that group
    can read every input device on the computer. SECURITY.md explains this.
  * It sends nothing anywhere. It keeps a small log you can read.
  * One command removes it again (uninstall.sh, kept in the folder above).
  * BETA.md in that folder says what has not been tested, and how to report problems.

NOTICE
    if [[ -r "$TARGET/BETA.md" ]]; then
        read -rp "  Show BETA.md now? [Y/n] " ans
        if [[ ! "$ans" =~ ^[Nn] ]]; then
            if command -v less >/dev/null && [[ -t 1 ]]; then less "$TARGET/BETA.md"; else cat "$TARGET/BETA.md"; fi
        fi
    fi
    read -rp "  I have read this and want to install it [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy] ]]; then
        echo
        echo "  Nothing was installed. The release is unpacked at $TARGET if you want to read it first."
        echo "  To install later:  bash $TARGET/install.sh"
        exit 0
    fi
fi

echo
cd "$TARGET" || exit 1
if (( UNATTENDED )); then
    bash install.sh -y
else
    bash install.sh
fi
rc=$?
echo
if (( rc == 0 )); then
    echo "== Installed. Open the Omarchy menu (SUPER+SPACE) > Setup > Surface Dial. =="
else
    echo "== The installer stopped with an error (code $rc). Nothing is half-installed that it did not tell you about. =="
fi
echo "   To remove it:     bash $TARGET/uninstall.sh"
echo "   To report a problem, see BETA.md and FEEDBACK.md in $TARGET"
exit "$rc"

# shellcheck disable=SC2317  # never reached: bash stops at the exit above; the payload follows
__PAYLOAD_BELOW__
