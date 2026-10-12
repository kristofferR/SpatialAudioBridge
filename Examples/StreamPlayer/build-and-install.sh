#!/bin/bash
set -euo pipefail

# Usage: ./build-and-install.sh DEVICE_ID
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_ID="${1:?Usage: ./build-and-install.sh DEVICE_ID}"
BUILD_USER="$(id -un)"
USER="${USER:-$BUILD_USER}" LOGNAME="${LOGNAME:-$BUILD_USER}" \
  xcodegen generate --spec "$APP_DIR/project.yml"
xcodebuild -project "$APP_DIR/StreamPlayer.xcodeproj" -scheme StreamPlayer \
  -destination "id=$DEVICE_ID" -derivedDataPath "$APP_DIR/DerivedData" \
  -jobs 1 -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${SAB_DEVELOPMENT_TEAM:-S5Q742QZEL}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build > "$APP_DIR/build.log" 2>&1 \
  || { tail -n 30 "$APP_DIR/build.log"; echo "Build failed; see $APP_DIR/build.log" >&2; exit 1; }
# The app was just built for this device's platform: Apple TV or iPhone and iPad.
APP="$(ls -td "$APP_DIR"/DerivedData/Build/Products/Debug-*os/StreamPlayer.app | head -n 1)"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" --json-output "$APP_DIR/install.json"
