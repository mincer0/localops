#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
CONFIGURATION="${LOCALOPS_CONFIGURATION:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
OUTPUT_ROOT="$PROJECT_ROOT/build"
APP="$OUTPUT_ROOT/LocalOps.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ICONSET="$OUTPUT_ROOT/AppIcon.iconset"
SOURCE_INFO="$PROJECT_ROOT/Resources/Info.plist"

die() {
  print -u2 "build-app: $*"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$SOURCE_INFO"
}

[[ -f "$SOURCE_INFO" ]] || die "missing $SOURCE_INFO"

# Info.plist is the single version source. Environment values are accepted
# only as assertions so a tag or local invocation cannot silently drift.
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
if [[ -n "${LOCALOPS_VERSION:-}" && "$LOCALOPS_VERSION" != "$VERSION" ]]; then
  die "LOCALOPS_VERSION=$LOCALOPS_VERSION does not match Info.plist $VERSION"
fi
if [[ -n "${LOCALOPS_BUILD_NUMBER:-}" && "$LOCALOPS_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
  die "LOCALOPS_BUILD_NUMBER=$LOCALOPS_BUILD_NUMBER does not match Info.plist $BUILD_NUMBER"
fi
if ! print -r -- "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  die "invalid CFBundleShortVersionString: $VERSION"
fi
if ! print -r -- "$BUILD_NUMBER" | grep -Eq '^[0-9]+$'; then
  die "invalid CFBundleVersion: $BUILD_NUMBER"
fi
[[ "$(plist_value LSMinimumSystemVersion)" == "13.0" ]] \
  || die "LSMinimumSystemVersion must remain 13.0 for the v1 support contract"
[[ "$(uname -m)" == "arm64" ]] \
  || die "release packaging must run on an Apple Silicon (arm64) builder"

cd "$PROJECT_ROOT"
rm -rf "$APP" "$ICONSET" \
  "$OUTPUT_ROOT/LocalOps-${VERSION}-${BUILD_NUMBER}-arm64.dSYM"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
# sips does not create parent directories for an --out path. Create the
# temporary iconset directory before rendering each icon size.
mkdir -p "$ICONSET"

swift build -c "$CONFIGURATION" --product LocalOps
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/LocalOps"
[[ -x "$BINARY" ]] || die "missing executable: $BINARY"

ARCHES="$(lipo -archs "$BINARY")"
[[ "$ARCHES" == "arm64" ]] || die "expected a thin arm64 executable, got: $ARCHES"
print -r -- "$(file "$BINARY")" | grep -q 'arm64' \
  || die "binary does not report arm64 architecture"
BINARY_MIN="$(otool -l "$BINARY" | awk '$1 == "minos" {print $2; exit}')"
[[ "$BINARY_MIN" == "13.0" ]] \
  || die "binary minimum macOS must be 13.0, got: ${BINARY_MIN:-unknown}"

cp "$BINARY" "$MACOS_DIR/LocalOps"
cp "$SOURCE_INFO" "$CONTENTS/Info.plist"
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
rm -rf "$ICONSET"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" && "$APP_BUILD" == "$BUILD_NUMBER" ]] \
  || die "bundled version does not match source Info.plist"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

DSYM_SOURCE="$BIN_DIR/LocalOps.dSYM"
DSYM_DEST="$OUTPUT_ROOT/LocalOps-${VERSION}-${BUILD_NUMBER}-arm64.dSYM"
[[ -d "$DSYM_SOURCE" ]] || die "release dSYM was not produced: $DSYM_SOURCE"
ditto "$DSYM_SOURCE" "$DSYM_DEST"

if [[ "$IDENTITY" == "-" ]]; then
  if spctl --assess --type execute --verbose=4 "$APP"; then
    print -u2 "warning: ad-hoc app unexpectedly accepted by Gatekeeper"
  else
    print "ad-hoc signature verified; Gatekeeper rejection is expected without Developer ID"
  fi
else
  spctl --assess --type execute --verbose=4 "$APP"
fi

print "$APP"
print "$DSYM_DEST"
