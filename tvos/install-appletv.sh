#!/bin/bash
# Build, sign and install the app on a paired Apple TV, then launch it. No Xcode UI needed.
#   tvos/install-appletv.sh ["Apple TV name"]     (default: Entertainment Room)
# Also the way to renew the free-team install when it expires after 7 days.
set -euo pipefail
cd "$(dirname "$0")"
DEVICE_NAME="${1:-Entertainment Room}"
BUILD_DIR="${TMPDIR:-/tmp}/tablotv-device-build"
BUNDLE_ID=$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $2}' project.yml)

xcodegen generate >/dev/null
xcodebuild -project TabloTV.xcodeproj -scheme TabloTV -configuration Debug \
  -destination "platform=tvOS,name=$DEVICE_NAME" -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
DEVICE_ID=$(xcrun devicectl list devices | awk -v n="$DEVICE_NAME" 'index($0, n) == 1 {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F-]{36}$/) print $i}' | head -1)
[ -n "$DEVICE_ID" ] || { echo "Apple TV '$DEVICE_NAME' not found; is it paired and awake?" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE_ID" "$BUILD_DIR/Build/Products/Debug-appletvos/TabloTV.app" >/dev/null
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null
echo "Installed and launched $BUNDLE_ID on $DEVICE_NAME"
