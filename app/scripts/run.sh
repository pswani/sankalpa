#!/bin/bash
# Builds Sankalpa, boots the simulator, installs and launches it.
#
# Sets DEVELOPER_DIR itself, so it works whether or not `xcode-select` points at Xcode.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-iPhone 17 Pro}"
DERIVED="${DERIVED:-$PWD/build/DerivedData}"
BUNDLE_ID="com.sankalpa.app"

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "Xcode not found at $DEVELOPER_DIR" >&2
  exit 1
fi

# Create the device if this machine does not have one yet.
if ! xcrun simctl list devices | grep -q "^    $DEVICE ("; then
  echo "Creating $DEVICE…"
  xcrun simctl create "$DEVICE" "com.apple.CoreSimulator.SimDeviceType.${DEVICE// /-}"
fi

echo "Building…"
xcodebuild build \
  -project Sankalpa.xcodeproj \
  -scheme Sankalpa \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  | grep -E "error:|warning: .*Swift|BUILD (SUCCEEDED|FAILED)"

echo "Booting $DEVICE…"
xcrun simctl boot "$DEVICE" 2>/dev/null || true

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Sankalpa.app"
xcrun simctl install "$DEVICE" "$APP"

# Demo content is opt-in: a normal launch starts empty, like a real install.
if [ "${DEMO:-0}" = "1" ]; then
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -demo >/dev/null
else
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
fi

echo
echo "Sankalpa is running on $DEVICE."
echo "To see it, open Xcode's simulator window, or capture the screens with:"
echo "  ./app/scripts/screen-tour.sh"
