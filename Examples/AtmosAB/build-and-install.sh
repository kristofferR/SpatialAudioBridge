#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_ID="${1:?Usage: ./build-and-install.sh DEVICE_ID [prepared-media-directory]}"
"$APP_DIR/prepare-media.sh" "${2:-${SAB_AB_MEDIA_DIR:-$APP_DIR/Media}}"
BUILD_USER="$(id -un)"
USER="${USER:-$BUILD_USER}" LOGNAME="${LOGNAME:-$BUILD_USER}" \
  xcodegen generate --spec "$APP_DIR/project.yml"
xcodebuild -project "$APP_DIR/AtmosAB.xcodeproj" -scheme AtmosAB \
  -destination "id=$DEVICE_ID" -derivedDataPath "$APP_DIR/DerivedData" \
  -jobs 1 -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${SAB_DEVELOPMENT_TEAM:-S5Q742QZEL}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build > "$APP_DIR/build.log" 2>&1
xcrun devicectl device install app --device "$DEVICE_ID" \
  "$APP_DIR/DerivedData/Build/Products/Debug-appletvos/AtmosAB.app" \
  --json-output "$APP_DIR/install.json"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
  com.kristofferr.SpatialAudioBridge.AtmosAB --json-output "$APP_DIR/launch.json"
