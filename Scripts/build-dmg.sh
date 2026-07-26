#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
VERSION="${LOCALOPS_VERSION:-0.4.0}"
RELEASE_ROOT="$PROJECT_ROOT/release"
STAGING_ROOT="$(mktemp -d)/LocalOps"
APP="$PROJECT_ROOT/build/LocalOps.app"
DMG="$RELEASE_ROOT/LocalOps-${VERSION}-arm64.dmg"

mkdir -p "$RELEASE_ROOT" "$STAGING_ROOT"
"$SCRIPT_DIR/build-app.sh"
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
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)

echo "$APP"
echo "$DMG"
