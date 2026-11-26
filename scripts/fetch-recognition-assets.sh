#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 1 && "$#" -le 2 && ( -z "${2:-}" || "${2:-}" == --archives-only ) ]] || {
  echo 'Usage: fetch-recognition-assets.sh NEW_DESTINATION [--archives-only]' >&2; exit 1;
}
DESTINATION="$1"
[[ ! -e "$DESTINATION" ]] || { echo 'Use a new asset destination' >&2; exit 1; }
: "${RECOGNITION_RUNTIME_URL:?Set pinned HTTPS runtime archive URL}"
: "${RECOGNITION_RUNTIME_SHA256:?Set runtime archive SHA256}"
: "${RECOGNITION_MODEL_URL:?Set pinned HTTPS model archive URL}"
: "${RECOGNITION_MODEL_SHA256:?Set model archive SHA256}"
mkdir -p "$DESTINATION"
for kind in RUNTIME MODEL; do
  if [[ "$kind" == RUNTIME ]]; then url="$RECOGNITION_RUNTIME_URL"; checksum="$RECOGNITION_RUNTIME_SHA256"; name=runtime; else url="$RECOGNITION_MODEL_URL"; checksum="$RECOGNITION_MODEL_SHA256"; name=model; fi
  [[ "$url" == https://* && "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'Expected HTTPS URL and exact SHA256' >&2; exit 1; }
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$url" -o "$DESTINATION/$name.tar.gz"
  printf '%s  %s\n' "$checksum" "$DESTINATION/$name.tar.gz" | shasum -a 256 -c -
  if [[ "${2:-}" == --archives-only ]]; then continue; fi
  python3 - "$DESTINATION/$name.tar.gz" "$DESTINATION/$name" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2], filter='data')
PY
done
if [[ "${2:-}" != --archives-only && ! -x "$DESTINATION/runtime/bin/python3" ]]; then
  echo 'Runtime archive must contain bin/python3 at its root' >&2; exit 1
fi
echo "Verified pinned runtime and model archives in $DESTINATION"
