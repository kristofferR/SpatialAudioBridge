#!/bin/bash
set -euo pipefail

# Signs a cloud-built app without rebuilding it or exporting signing credentials.
ARCHIVE="${1:?Usage: $0 APP_ZIP PROFILE SIGNING_IDENTITY DEVICE_UDID}"
PROFILE="${2:?Supply a tvOS development provisioning profile}"
IDENTITY="${3:?Supply a signing identity name or SHA-1 fingerprint}"
DEVICE_ID="${4:?Supply the paired Apple TV UDID}"
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sab-stream-player.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PLIST_BUDDY=/usr/libexec/PlistBuddy

ditto -x -k "$ARCHIVE" "$WORK"
APP="$WORK/StreamPlayer.app"
BUNDLE_ID="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[[ "$BUNDLE_ID" == com.kristofferr.SpatialAudioBridge.StreamPlayer ]] || {
  echo 'Expected the StreamPlayer app from Core CI' >&2; exit 1;
}
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
[[ "$("$PLIST_BUDDY" -c 'Print :Platform:0' "$WORK/profile.plist")" == tvOS ]] || {
  echo 'The profile must target tvOS' >&2; exit 1;
}
[[ "$("$PLIST_BUDDY" -c 'Print :Entitlements:get-task-allow' "$WORK/profile.plist")" == true ]] || {
  echo 'Use a development profile for this device validation app' >&2; exit 1;
}
"$PLIST_BUDDY" -c 'Print :ProvisionedDevices' "$WORK/profile.plist" | grep -Fqx "    $DEVICE_ID" || {
  echo 'The profile does not include this Apple TV UDID' >&2; exit 1;
}
TEAM="$("$PLIST_BUDDY" -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
APP_ID="$TEAM.$BUNDLE_ID"
PROFILE_APP_ID="$("$PLIST_BUDDY" -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")"
[[ "$PROFILE_APP_ID" == "$APP_ID" || "$PROFILE_APP_ID" == "$TEAM.*" ]] || {
  echo 'The profile does not permit the StreamPlayer bundle identifier' >&2; exit 1;
}

# StreamPlayer needs only its development identity, not any optional app capabilities.
ENTITLEMENTS="$WORK/entitlements.plist"
"$PLIST_BUDDY" -c 'Clear dict' "$ENTITLEMENTS"
"$PLIST_BUDDY" -c "Add :application-identifier string $APP_ID" "$ENTITLEMENTS"
"$PLIST_BUDDY" -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
"$PLIST_BUDDY" -c 'Add :get-task-allow bool true' "$ENTITLEMENTS"
"$PLIST_BUDDY" -c 'Add :keychain-access-groups array' "$ENTITLEMENTS"
"$PLIST_BUDDY" -c "Add :keychain-access-groups:0 string $APP_ID" "$ENTITLEMENTS"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# Sign embedded code before the containing app; framework code gets no app entitlements.
while IFS= read -r -d '' code; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$code"
done < <(find "$APP" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
