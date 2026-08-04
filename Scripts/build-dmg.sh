#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SOURCE_INFO="$PROJECT_ROOT/Resources/Info.plist"
RELEASE_ROOT="$PROJECT_ROOT/release"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localops-dmg.XXXXXX")"
STAGING_ROOT="$TEMP_ROOT/LocalOps"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

die() {
  print -u2 "build-dmg: $*"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$SOURCE_INFO"
}

[[ -f "$SOURCE_INFO" ]] || die "missing $SOURCE_INFO"
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
if [[ -n "${LOCALOPS_VERSION:-}" && "$LOCALOPS_VERSION" != "$VERSION" ]]; then
  die "LOCALOPS_VERSION=$LOCALOPS_VERSION does not match Info.plist $VERSION"
fi
if [[ -n "${LOCALOPS_BUILD_NUMBER:-}" && "$LOCALOPS_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
  die "LOCALOPS_BUILD_NUMBER=$LOCALOPS_BUILD_NUMBER does not match Info.plist $BUILD_NUMBER"
fi
[[ "$(uname -m)" == "arm64" ]] || die "DMG packaging requires an arm64 builder"

RELEASE_NAME="LocalOps-${VERSION}-arm64"
DMG="$RELEASE_ROOT/${RELEASE_NAME}.dmg"
SHA256="$RELEASE_ROOT/${RELEASE_NAME}.dmg.sha256"
APP="$PROJECT_ROOT/build/LocalOps.app"

mkdir -p "$RELEASE_ROOT" "$STAGING_ROOT"
rm -rf "$DMG" "$SHA256"
"$SCRIPT_DIR/build-app.sh"
[[ -d "$APP" ]] || die "build-app.sh did not produce $APP"
ARCHES="$(lipo -archs "$APP/Contents/MacOS/LocalOps")"
[[ "$ARCHES" == "arm64" ]] || die "candidate app is not a thin arm64 binary: $ARCHES"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto "$APP" "$STAGING_ROOT/LocalOps.app"
ln -s /Applications "$STAGING_ROOT/Applications"
cp "$PROJECT_ROOT/Resources/INSTALL.txt" "$STAGING_ROOT/安装说明.txt"

hdiutil create \
  -volname "LocalOps" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$DMG"
hdiutil verify "$DMG"
(
  cd "$RELEASE_ROOT"
  shasum -a 256 "${DMG:t}" > "${SHA256:t}"
)

print "$DMG"
print "$SHA256"
