#!/usr/bin/env bash
# make-installer.sh -- build the single-file installer for a release.
#
#   scripts/make-installer.sh <git-ref> <output-file>
#   e.g. scripts/make-installer.sh v0.8.4 redial-0.8.4-installer.sh
#
# The version is read from that ref's own redial/__init__.py, so the installer can never
# disagree with what is inside it. Also writes <output-file>.sha256.
set -eu
REF="${1:?usage: make-installer.sh <git-ref> <output-file>}"
OUT="${2:?usage: make-installer.sh <git-ref> <output-file>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

VERSION="$(git show "$REF:redial/__init__.py" | sed -n 's/^__version__ = "\(.*\)"$/\1/p')"
[[ -n "$VERSION" ]] || { echo "could not read the version at $REF" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git archive --prefix="redial-$VERSION/" "$REF" | gzip -n > "$TMP/release.tar.gz"
SHA="$(sha256sum "$TMP/release.tar.gz" | cut -d' ' -f1)"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/" scripts/installer-template.sh > "$OUT"
base64 -w 76 "$TMP/release.tar.gz" >> "$OUT"
chmod 755 "$OUT"
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
echo "built $OUT ($(wc -c < "$OUT") bytes) for version $VERSION, payload sha256 $SHA"
