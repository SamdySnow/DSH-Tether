#!/bin/bash
#
# Packages dist/Tether.app into a distributable zip.
#
# `ditto` is used rather than `zip` on purpose. A plain archive of a bundle records
# resource forks as `__MACOSX/._*` siblings, and extracting that form can leave the
# bundle's sealed resources disagreeing with its signature — one of the ways an app
# ends up reported as "damaged and can't be opened". `--sequesterRsrc` stores the
# same information the way Archive Utility expects to reassemble it.
#
# Usage: ./Scripts/package-app.sh [output.zip]
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_ROOT/dist/Tether.app"
OUTPUT="${1:-$PROJECT_ROOT/dist/Tether.zip}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found; run ./Scripts/build-app.sh first" >&2
  exit 1
fi

echo "==> Packaging $(basename "$APP_DIR")"
rm -f "$OUTPUT"
ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 "$APP_DIR" "$OUTPUT"

echo "==> Verifying archive"
unzip -t "$OUTPUT" >/dev/null

echo
echo "Packaged: $OUTPUT"
echo
echo "The receiving Mac still has to clear the quarantine flag, because this build"
echo "is ad-hoc signed rather than notarized:"
echo "    xattr -dr com.apple.quarantine /Applications/Tether.app"
