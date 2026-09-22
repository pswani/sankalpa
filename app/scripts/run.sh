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

# The practice lives in the service, so the app is pointed at one rather than given a store.
# SIMCTL_CHILD_ is how simctl passes an environment variable through to the app.
SERVICE_URL="${SANKALPA_API_BASE_URL:-http://localhost:8080}"
if ! curl -sf --max-time 2 "$SERVICE_URL/api/v1/sankalpas" -o /dev/null; then
  echo
  echo "The Sankalpa service is not answering at $SERVICE_URL." >&2
  echo "Start it first, with the same time zone this Mac is in:" >&2
  echo "  cd backend && SANKALPA_TIMEZONE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||') mvn spring-boot:run" >&2
  echo >&2
  echo "The app will launch anyway and show its recovery screen." >&2
fi

SIMCTL_CHILD_SANKALPA_API_BASE_URL="$SERVICE_URL" \
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

echo
echo "Sankalpa is running on $DEVICE, against $SERVICE_URL."
echo "To see it, open Xcode's simulator window, or capture the screens with:"
echo "  ./app/scripts/test.sh --ui        # gallery lands in app/build/screens"
echo "For example content, seed a throwaway service:"
echo "  ./app/scripts/seed-demo.py --base-url $SERVICE_URL"
