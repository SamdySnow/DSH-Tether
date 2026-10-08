#!/bin/bash
#
# Builds Tether.app.
#
# Two things are non-obvious here:
#
#  1. `DEVELOPER_DIR` points at Xcode. The SwiftUI macro plugin
#     (libSwiftUIMacros.dylib) ships with Xcode and is NOT part of the bare
#     Command Line Tools, so building against CLT alone fails with
#     "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found".
#
#  2. The bundle is assembled by hand rather than with Xcode, so `Package.swift`
#     stays usable from a plain terminal.
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Tether"
# Own namespace: the previous `dev.deepseek.*` identifier claimed a domain this
# project does not own, which would be misread as an official DeepSeek product.
BUNDLE_ID="dev.tether.dsh"
MIN_MACOS="27.0"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
  echo "error: built binary not found at $BINARY" >&2
  exit 1
fi

APP_DIR="$PROJECT_ROOT/dist/$APP_NAME.app"
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# ---- Info.plist ----
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <!-- Names the thing being tethered, and keeps this from reading as an
         official DeepSeek product. -->
    <key>CFBundleDisplayName</key>
    <string>Tether for DeepSeek Harness</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Regular app that also owns a menu bar item. -->
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# ---- Icon ----
# The .icns is generated from the source bitmap rather than committed, so the
# artwork stays the single source of truth. Regeneration happens when the source
# is newer than the built icon, or when the icon is missing.
#
# The source is discovered rather than hardcoded. A hardcoded name silently
# stopped matching when the artwork was replaced under a different filename
# (`IMG_2124.PNG` -> `IMG_2,124.png`), and the build then kept shipping the stale
# icon with no error — which is indistinguishable from the icon being wrong.
# Override with ICON_SOURCE=/path/to/image.png if you have several candidates.
BITMAP_DIR="$PROJECT_ROOT/Sources/bitmap"

discover_icon_source() {
  if [[ -n "${ICON_SOURCE:-}" ]]; then
    printf '%s' "$ICON_SOURCE"
    return
  fi

  # Conventional location first: a finished 1024x1024 icon supplied directly.
  if [[ -f "$PROJECT_ROOT/Resources/icon.png" ]]; then
    printf '%s' "$PROJECT_ROOT/Resources/icon.png"
    return
  fi

  # Otherwise take the first image-looking file in the artwork folder,
  # case-insensitively by extension. The `[[ -f ]]` guard keeps a missing
  # directory from expanding to a literal path.
  local candidate
  for candidate in "$BITMAP_DIR"/*.png "$BITMAP_DIR"/*.PNG \
                   "$BITMAP_DIR"/*.jpg "$BITMAP_DIR"/*.jpeg \
                   "$BITMAP_DIR"/*.heic "$BITMAP_DIR"/*.tif \
                   "$BITMAP_DIR"/*.tiff "$BITMAP_DIR"/*.bmp; do
    [[ -f "$candidate" ]] || continue
    printf '%s' "$candidate"
    return
  done
}

SOURCE_ICON="$(discover_icon_source)"
BUILT_ICON="$PROJECT_ROOT/Resources/AppIcon.icns"

if [[ -z "$SOURCE_ICON" || ! -f "$SOURCE_ICON" ]]; then
  echo "warning: no source image in $BITMAP_DIR; keeping the existing icon"
elif [[ -n "${ICON_SOURCE:-}" && ! -f "$SOURCE_ICON" ]]; then
  echo "warning: ICON_SOURCE=$ICON_SOURCE does not exist; keeping the existing icon"
fi

# `full`  = artwork fills the entire icon (no transparent margin)
# `inset` = Apple's stock layout (artwork inset with a rounded transparent margin)
# `sharp` = fills the icon with square corners
ICON_GEOMETRY="${ICON_GEOMETRY:-full}"

# Trimming removes a transparent border from the source before it is scaled, so
# the *visible* artwork fills the icon. Set ICON_TRIM=0 for artwork that is meant
# to float with its own padding.
TRIM_ARGUMENT="trim"
if [[ "${ICON_TRIM:-1}" == "0" ]]; then
  TRIM_ARGUMENT="no-trim"
fi

# The geometry and trim mode are baked into the generated file, so a change to
# either must also trigger regeneration — hence the stamp file.
GEOMETRY_STAMP="$PROJECT_ROOT/Resources/.icon-geometry"
STORED_GEOMETRY="$(cat "$GEOMETRY_STAMP" 2>/dev/null || echo "")"
REQUESTED_ICON="$ICON_GEOMETRY/$TRIM_ARGUMENT"

# Record which source produced the icon. Without this, swapping the artwork under
# a different filename can regenerate nothing and the stale icon ships silently,
# which is exactly how the earlier hardcoded filename failed.
SOURCE_STAMP="$(cat "$PROJECT_ROOT/Resources/.icon-source" 2>/dev/null || echo "")"

if [[ -f "$SOURCE_ICON" ]] && { [[ ! -f "$BUILT_ICON" ]] \
    || [[ "$SOURCE_ICON" -nt "$BUILT_ICON" ]] \
    || [[ "$STORED_GEOMETRY" != "$REQUESTED_ICON" ]] \
    || [[ "$SOURCE_STAMP" != "$(basename "$SOURCE_ICON")" ]]; }; then
  echo "==> Generating AppIcon.icns from $(basename "$SOURCE_ICON") ($REQUESTED_ICON)"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$PROJECT_ROOT/Resources"
  # Runs under Xcode's toolchain, like the rest of the build, because the default
  # Command Line Tools toolchain is not the one used elsewhere.
  swift "$PROJECT_ROOT/Scripts/make-icon.swift" \
    "$SOURCE_ICON" "$ICONSET" "$ICON_GEOMETRY" "$TRIM_ARGUMENT" >/dev/null
  iconutil -c icns "$ICONSET" -o "$BUILT_ICON"
  rm -rf "$(dirname "$ICONSET")"
  printf '%s' "$REQUESTED_ICON" > "$GEOMETRY_STAMP"
  printf '%s' "$(basename "$SOURCE_ICON")" > "$PROJECT_ROOT/Resources/.icon-source"
elif [[ -f "$BUILT_ICON" && -n "$SOURCE_ICON" && -f "$SOURCE_ICON" ]]; then
  echo "==> Icon up to date ($(basename "$SOURCE_ICON"), $REQUESTED_ICON)"
fi

if [[ -f "$BUILT_ICON" ]]; then
  echo "==> Copying AppIcon.icns"
  cp "$BUILT_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "note: no icon source found; the app will use the generic icon"
fi

# ---- Sign ----
# Ad-hoc signing keeps the app launchable locally and, importantly, keeps it
# recognisable to macOS so the runtime icon override sticks.
#
# Ad-hoc is sufficient on the machine that built it, but it is not a distributable
# signature: a copy that acquires com.apple.quarantine (AirDrop, a download, most
# zip transfers) is refused by Gatekeeper on the receiving Mac with a "damaged and
# can't be opened" dialog. Set SIGN_IDENTITY (and optionally NOTARY_PROFILE) to
# produce a build that travels.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing as $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
    echo "note: codesign unavailable; the app still runs unsigned"
fi

# A quarantine flag inherited from the build directory makes LaunchServices refuse
# the app on first open, which is indistinguishable from a broken signature.
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

# Finder caches icons per bundle path and per modification date. Without bumping
# the bundle and clearing the cached entry, the old (or generic) icon keeps being
# displayed even though the bundle on disk is correct.
touch "$APP_DIR"
/usr/bin/GetFileInfo "$APP_DIR" >/dev/null 2>&1 || true

# ---- Notarize (optional) ----
if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: NOTARY_PROFILE requires SIGN_IDENTITY (notarization needs a Developer ID)" >&2
    exit 1
  fi
  echo "==> Notarizing (keychain profile: $NOTARY_PROFILE)"
  NOTARY_DIR="$(mktemp -d)"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_DIR/Tether.zip"
  xcrun notarytool submit "$NOTARY_DIR/Tether.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  rm -rf "$NOTARY_DIR"
fi

# ---- Verify ----
# The bundle itself can be perfectly intact and still be refused by Gatekeeper, so
# the two checks are reported separately. Conflating them is how a signing problem
# gets misread as a code problem.
echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Assessing Gatekeeper"
if spctl -a -t exec "$APP_DIR" >/dev/null 2>&1; then
  echo "    accepted"
else
  cat <<'WARNING'
    WARNING: Gatekeeper rejects this build.

    Expected for an ad-hoc signature; not a defect in the app. It launches
    normally on this machine, but a copy carrying com.apple.quarantine (AirDrop,
    download, most zip transfers) is refused on another Mac as "damaged".

    On the receiving Mac, clear the quarantine flag:
        xattr -dr com.apple.quarantine /Applications/Tether.app

    To build something that travels without that step, sign with a Developer ID
    and notarize:
        SIGN_IDENTITY="Developer ID Application: …" \
        NOTARY_PROFILE=tether-notary ./Scripts/build-app.sh
WARNING
fi

echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
echo "Pack:  ./Scripts/package-app.sh   (for handing the app to another Mac)"
