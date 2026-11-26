#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:---local}"
[[ "$#" -le 1 && ( "$MODE" == --local || "$MODE" == --release ) ]] || { echo 'Usage: scripts/build-dmg.sh [--local|--release]' >&2; exit 1; }
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid version' >&2; exit 1; }
if [[ "$MODE" == --release ]]; then
  python3 scripts/release-readiness.py "$VERSION"
  python3 - <<'PY'
import os, sys
sys.path.insert(0, 'scripts')
import runpy
runpy.run_path('scripts/release-readiness.py')['public_key'](os.environ.get('SPARKLE_PUBLIC_ED_KEY', ''))
PY
  if [[ "$VERSION" == 1.0.0 ]]; then
    : "${RECOGNITION_ASSET_DIR:?Set the directory containing the pinned runtime.tar.gz and model.tar.gz archives}"
  else
    [[ -n "${RECOGNITION_RUNTIME_DIR:-}" && -n "${RECOGNITION_MODEL_DIR:-}" ]] || { echo 'Release requires pinned RECOGNITION_RUNTIME_DIR and RECOGNITION_MODEL_DIR' >&2; exit 1; }
  fi
  for field in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$field" Info.plist)" == "$VERSION" ]] || { echo "Release version must match Info.plist $field" >&2; exit 1; }
  done
fi
command -v hdiutil >/dev/null || { echo 'Packaging requires macOS' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Build and smoke-test on an Apple silicon Mac' >&2; exit 1; }
if [[ "$MODE" == --release && ( -n "${PACKAGE_OUTPUT_DIR:-}" || -n "${SWIFT_BUILD_DIR:-}" ) ]]; then
  echo 'Output overrides are for local smoke builds only' >&2; exit 1
fi
SCRATCH="${SWIFT_BUILD_DIR:-$ROOT/.build/packaging}"
OUT="${PACKAGE_OUTPUT_DIR:-$ROOT/.build/dist/$MODE/$VERSION}"
[[ "$SCRATCH" == /* && "$OUT" == /* ]] || { echo 'Build/output paths must be absolute' >&2; exit 1; }
mkdir -p "$SCRATCH" "$OUT"
ASSET_STAGE=''
cleanup() {
  if [[ -n "$ASSET_STAGE" ]]; then rm -rf "$ASSET_STAGE"; fi
}
trap cleanup EXIT
APP="$OUT/LaTeXShot.app"
[[ ! -e "$APP" ]] || { echo "Output already exists: $APP; archive or remove this local output before rebuilding" >&2; exit 1; }
if [[ "$MODE" == --release && "$VERSION" == 1.0.0 ]]; then
  ASSET_STAGE="$(mktemp -d "$SCRATCH/recognition-stage.XXXXXX")"
  python3 scripts/release-readiness.py "$VERSION" --stage-archives "$RECOGNITION_ASSET_DIR" "$ASSET_STAGE"
  RECOGNITION_RUNTIME_DIR="$ASSET_STAGE/runtime"
  RECOGNITION_MODEL_DIR="$ASSET_STAGE/model"
  [[ -x "$RECOGNITION_RUNTIME_DIR/bin/python3" ]] || { echo 'Runtime archive must contain executable bin/python3 at its root' >&2; exit 1; }
fi
BUILD_ARGS=(build -c release --arch arm64 --scratch-path "$SCRATCH")
if [[ "$MODE" == --release ]]; then BUILD_ARGS+=(--disable-automatic-resolution); fi
swift "${BUILD_ARGS[@]}"
BIN="$(swift "${BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/LaTeXShot" "$APP/Contents/MacOS/LaTeXShot"
cp Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
[[ -d "$APP/Contents/Resources/LaTeXShot_LaTeXShotApp.bundle" ]] || { echo 'Missing app resource bundle' >&2; exit 1; }
SPARKLE="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "Missing resolved Sparkle framework: $SPARKLE" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# Ensure a packaged run does not depend on the SwiftPM build directory.
if ! otool -l "$APP/Contents/MacOS/LaTeXShot" | grep -F '@executable_path/../Frameworks' >/dev/null; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/LaTeXShot"
fi
APP_PATH="$APP" BUILD_VERSION="$VERSION" BUILD_MODE="$MODE" python3 - <<'PY'
import os, plistlib
from pathlib import Path
path = Path(os.environ['APP_PATH']) / 'Contents/Info.plist'
with path.open('rb') as stream: data = plistlib.load(stream)
data['CFBundleVersion'] = data['CFBundleShortVersionString'] = os.environ['BUILD_VERSION']
if os.environ['BUILD_VERSION'] == '1.0.0':
    data['LaTeXShotRecognitionBackend'] = 'pix2text'
if os.environ['BUILD_MODE'] == '--release':
    data['SUPublicEDKey'] = os.environ['SPARKLE_PUBLIC_ED_KEY']
else:
    data['SUEnableAutomaticChecks'] = False
    data.pop('SUFeedURL', None)
    data.pop('SUPublicEDKey', None)
with path.open('wb') as stream: plistlib.dump(data, stream)
PY
if [[ -f Assets/Icon/LaTeXShot.icns ]]; then
  cp Assets/Icon/LaTeXShot.icns "$APP/Contents/Resources/LaTeXShot.icns"
else
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist"
  echo 'Local trial: artwork pending user selection.'
fi
if [[ -f Assets/Icon/LaTeXShotMenuBar.pdf ]]; then
  cp Assets/Icon/LaTeXShotMenuBar.pdf "$APP/Contents/Resources/LaTeXShotMenuBar.pdf"
fi
for kind in RUNTIME MODEL; do
  if [[ "$kind" == RUNTIME ]]; then source="${RECOGNITION_RUNTIME_DIR:-}"; destination=RecognitionRuntime; else source="${RECOGNITION_MODEL_DIR:-}"; destination=RecognitionModel; fi
  if [[ -n "$source" ]]; then
    [[ -d "$source" ]] || { echo "Missing recognition directory: $source" >&2; exit 1; }
    ditto "$source" "$APP/Contents/Resources/$destination"
  fi
done
if [[ "$MODE" == --release ]]; then
  [[ -x "$APP/Contents/Resources/RecognitionRuntime/bin/python3" ]] || { echo 'Missing bundled executable Python runtime' >&2; exit 1; }
  if [[ "$VERSION" == 0.1.0 ]]; then
    python3 - "$APP/Contents/Resources/RecognitionModel" <<'PY'
from pathlib import Path
import runpy
import sys

try:
    runpy.run_path('scripts/release-readiness.py')['validate_staged_plus_s'](Path.cwd(), Path(sys.argv[1]))
except (OSError, ValueError) as exc:
    sys.exit(str(exc))
PY
  elif [[ "$VERSION" == 1.0.0 ]]; then
    python3 - "$APP/Contents/Resources" <<'PY'
from pathlib import Path
import runpy
import sys

try:
    runpy.run_path('scripts/release-readiness.py')['validate_staged_pix2text'](Path.cwd(), Path(sys.argv[1]))
except (OSError, ValueError, TypeError) as exc:
    sys.exit(str(exc))
PY
  fi
fi
# Sparkle's signed nested helpers remain intact; sign the outer app ad hoc.
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
[[ "$(lipo -archs "$APP/Contents/MacOS/LaTeXShot")" == arm64 ]] || { echo 'Unexpected executable architecture' >&2; exit 1; }
bash scripts/create-installer-dmg.sh "$APP" "$OUT/LaTeXShot-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/LaTeXShot-$VERSION.zip"
cp "$OUT/LaTeXShot-$VERSION.dmg" "$OUT/LaTeXShot.dmg"
echo "Created $OUT (ad-hoc signed, not notarized; mode $MODE)"
