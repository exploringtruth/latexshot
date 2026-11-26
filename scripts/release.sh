#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$#" -ge 1 && "$#" -le 2 && ( "${2:-}" == '' || "${2:-}" == --push ) ]] || { echo 'Usage: scripts/release.sh MAJOR.MINOR.PATCH [--push]' >&2; exit 1; }
VERSION="$1"
python3 scripts/release-readiness.py "$VERSION"
[[ -z "$(git status --porcelain)" ]] && git symbolic-ref --quiet HEAD >/dev/null || { echo 'Use a clean branch with all release changes committed' >&2; exit 1; }
python3 - "$VERSION" <<'PY'
import plistlib, sys
with open('Info.plist', 'rb') as stream: current = plistlib.load(stream)['CFBundleShortVersionString']
if tuple(map(int, sys.argv[1].split('.'))) < tuple(map(int, current.split('.'))):
    sys.exit('Release version cannot go backwards')
PY
TAG="v$VERSION"
! git show-ref --verify --quiet "refs/tags/$TAG" || { echo "Tag already exists: $TAG" >&2; exit 1; }
if [[ "${2:-}" == --push ]]; then
  git fetch origin main --tags
  git merge-base --is-ancestor FETCH_HEAD HEAD || { echo 'Include origin/main before releasing' >&2; exit 1; }
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" -c "Set :CFBundleShortVersionString $VERSION" Info.plist
if ! git diff --quiet -- Info.plist; then
  git add Info.plist
  git commit -m "Release LaTeXShot $TAG"
fi
git tag -a "$TAG" -m "LaTeXShot $TAG"
if [[ "${2:-}" == --push ]]; then
  git push --atomic origin HEAD:refs/heads/main "refs/tags/$TAG" || { echo "Local commit and $TAG retained. Retry the same atomic push after resolving the error." >&2; exit 1; }
else
  echo "Prepared local $TAG. Publication requires explicit --push or: git push --atomic origin HEAD:refs/heads/main refs/tags/$TAG"
fi
