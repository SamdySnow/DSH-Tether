#!/bin/bash
#
# Lists the SwiftUI declarations that are gated at macOS 27.0 in the installed SDK.
#
# Used to ground "new OS feature" claims in the actual SDK rather than in
# recollection. Several plausible candidates turned out to be macOS 26 or to not
# exist at all, and this is what settled it.
#
# Usage: ./Scripts/check-macos27-api.sh [path-to-sdk]
#
set -euo pipefail

SDK="${1:-}"
if [[ -z "$SDK" ]]; then
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  else
    SDK="$(xcrun --show-sdk-path)"
  fi
fi

SI="$SDK/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface"

if [[ ! -f "$SI" ]]; then
  echo "error: SwiftUI swiftinterface not found under $SDK" >&2
  echo "hint: point at an Xcode SDK, e.g. $0 /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk" >&2
  exit 1
fi

echo "SDK: $SDK"
echo "Interface: $(wc -l < "$SI" | tr -d ' ') lines"
echo

echo "=== Declarations gated at macOS 27.0 ==="
# A line mentioning macOS 27.0 is followed by zero or more further @available
# lines, then the declaration itself.
awk '
  /macOS 27\.0/ { pending = 1; next }
  pending && /^[[:space:]]*@available/ { next }
  pending && /^[[:space:]]*#/ { next }
  pending && /^[[:space:]]*$/ { next }
  pending {
    line = $0
    gsub(/^[[:space:]]+/, "", line)
    if (line != "") print "  " line
    pending = 0
  }
' "$SI" | sort -u | grep -vE '^\s*(public static var _propertyStorageSize|public typealias Body)' | head -60

echo
echo "=== Spot-check known candidates ==="
for name in reorderContainer TabsPickerStyle glassEffect safeAreaBar ToolbarSpacer DialogSeverity; do
  printf '  %-22s %s occurrence(s)\n' "$name" "$(grep -c "$name" "$SI" || true)"
done
