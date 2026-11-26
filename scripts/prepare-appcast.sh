#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:?Set VERSION}"
: "${SPARKLE_PRIVATE_ED_KEY:?Set SPARKLE_PRIVATE_ED_KEY in the release environment}"
: "${SPARKLE_PUBLIC_ED_KEY:?Set SPARKLE_PUBLIC_ED_KEY}"
python3 scripts/release-readiness.py "$VERSION"
OUT="$ROOT/.build/dist/--release/$VERSION"
[[ -f "$OUT/LaTeXShot-$VERSION.zip" && ! -f "$OUT/appcast.xml" ]] || { echo 'Expected fresh release ZIP without an existing appcast' >&2; exit 1; }
TOOLS="$ROOT/.build/packaging/artifacts/sparkle/Sparkle/bin"
FEED_STAGE="$(mktemp -d)"
trap 'rm -rf "$FEED_STAGE"' EXIT
cp "$OUT/LaTeXShot-$VERSION.zip" "$FEED_STAGE/"
# Embed Markdown notes in the feed so publication has no release-note dependency.
cp ".github/release-notes/v$VERSION.md" "$FEED_STAGE/LaTeXShot-$VERSION.md"
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$TOOLS/generate_appcast" --ed-key-file - \
  --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/exploringtruth/latexshot/releases/download/v$VERSION/" \
  "$FEED_STAGE"
python3 scripts/verify-appcast.py "$FEED_STAGE/appcast.xml" "$OUT/LaTeXShot-$VERSION.zip" "$OUT/LaTeXShot.app" "$VERSION"
cp "$FEED_STAGE/appcast.xml" "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "LaTeXShot-$VERSION.dmg" LaTeXShot.dmg "LaTeXShot-$VERSION.zip" appcast.xml > SHA256SUMS)
echo "Verified signed assets in $OUT"
