#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-iPhone 17 Pro}"
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b
xcodebuild build -project Sankalpa.xcodeproj -scheme Sankalpa \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$PWD/build/Run" \
    CODE_SIGNING_ALLOWED=NO > /tmp/sankalpa2-run-build.log 2>&1 || { tail -80 /tmp/sankalpa2-run-build.log; exit 1; }
xcrun simctl install "$DEVICE" "$PWD/build/Run/Build/Products/Debug-iphonesimulator/Sankalpa.app"
if [[ "${1:-}" == "--demo" ]]; then
    SIMCTL_CHILD_PRACTICE_TEST_STORE=preview xcrun simctl launch --terminate-running-process "$DEVICE" com.sankalpa.practice -demo
else
    xcrun simctl launch --terminate-running-process "$DEVICE" com.sankalpa.practice
fi
if [[ -d "$DEVELOPER_DIR/Applications/Simulator.app" ]]; then
    open "$DEVELOPER_DIR/Applications/Simulator.app"
else
    printf 'App installed and running. Simulator GUI is not bundled with this Xcode installation; screenshots are in %s/Preview.\n' "$PWD"
fi
