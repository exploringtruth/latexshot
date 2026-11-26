#!/usr/bin/env bash
# Package an already-signed app with a compact native Finder layout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" != 2 || "$1" != /*/LaTeXShot.app || "$2" != /* || "$2" != *.dmg || ! -d "$1" ]]; then
  echo 'Usage: scripts/create-installer-dmg.sh /absolute/LaTeXShot.app /absolute/LaTeXShot.dmg' >&2
  exit 1
fi
APP="$1"
OUTPUT="$2"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

WORK="$(mktemp -d "$(dirname "$OUTPUT")/.latexshot-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/staging"
ditto "$APP" "$WORK/staging/LaTeXShot.app"
ln -s /Applications "$WORK/staging/Applications"
cp "$ROOT/scripts/dmg/FinderLayout.dsstore" "$WORK/staging/.DS_Store"

hdiutil create -volname LaTeXShot -fs HFS+ -format UDZO -srcfolder "$WORK/staging" "$WORK/installer.dmg"
hdiutil verify "$WORK/installer.dmg"
mv -n "$WORK/installer.dmg" "$OUTPUT"
[[ ! -e "$WORK/installer.dmg" ]] || { echo "Output appeared during packaging: $OUTPUT" >&2; exit 1; }
