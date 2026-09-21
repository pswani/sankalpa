#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
mkdir -p build
RUN="$PWD/build/verification-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
xcrun swift test --package-path SankalpaCore --scratch-path "$RUN/core" > "$RUN/core.log" 2>&1 || { tail -80 "$RUN/core.log"; exit 1; }
DEVICE_ID=$(xcrun simctl create "Sankalpa2 verification" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
cleanup() {
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
if ! xcodebuild test -project Sankalpa.xcodeproj -scheme Sankalpa \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath "$RUN/DerivedData" -resultBundlePath "$RUN/UI.xcresult" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO > "$RUN/ui.log" 2>&1; then
    tail -100 "$RUN/ui.log"
    exit 1
fi
xcrun xcresulttool export attachments --path "$RUN/UI.xcresult" --output-path "$RUN/screens" > "$RUN/screens.log"
if ! xcodebuild build -project Sankalpa.xcodeproj -scheme Sankalpa -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$RUN/Release" \
    CODE_SIGNING_ALLOWED=NO > "$RUN/release.log" 2>&1; then
    tail -80 "$RUN/release.log"
    exit 1
fi
printf 'Core tests, UI tests, and release build passed. Reports: %s\n' "$RUN"
