#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
CONFIGURATION="${LOCALOPS_CONFIGURATION:-release}"
VERSION="${LOCALOPS_VERSION:-0.4.0}"
BUILD_NUMBER="${LOCALOPS_BUILD_NUMBER:-4}"
IDENTITY="${CODESIGN_IDENTITY:--}"
OUTPUT_ROOT="$PROJECT_ROOT/build"
APP="$OUTPUT_ROOT/LocalOps.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ICONSET="$OUTPUT_ROOT/AppIcon.iconset"

cd "$PROJECT_ROOT"
swift build -c "$CONFIGURATION" --product LocalOps
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET"
cp "$BIN_DIR/LocalOps" "$MACOS_DIR/LocalOps"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"

for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$RESOURCES_DIR/${bundle:t}"
done

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -s format png -z "$size" "$size" "$PROJECT_ROOT/Resources/AppIcon.svg" \
    --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

echo "$APP"
