#!/bin/bash
# Builds the app, drives every screen with the UI tour, and writes numbered screenshots to
# app/build/screens. Used for design review.
#
# Dark Mode runs as a second pass: the simulator's appearance is set with simctl, which is the only
# way that reliably affects the first rendered frame.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-iPhone 17 Pro}"
DERIVED="${DERIVED:-/tmp/claude-501/sankalpa-dd}"
OUT="${OUT:-$PWD/build/screens}"
DARK_TEST="SankalpaUITests/ScreenTour/testDarkMode"

rm -rf "$OUT"
mkdir -p "$OUT"
xcrun simctl boot "$DEVICE" 2>/dev/null || true

# The app container survives a reinstall, so its seeded sample data would otherwise outlive any
# change to SampleData and the tour would review stale content.
xcrun simctl uninstall "$DEVICE" com.sankalpa.app 2>/dev/null || true

collect() { # $1 = result bundle
  local tmp
  tmp=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$1" --output-path "$tmp" >/dev/null
  python3 - "$tmp" "$OUT" <<'PY'
import json, os, re, shutil, sys
src_dir, out_dir = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(src_dir, "manifest.json"))):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName") or ""
        exported = attachment.get("exportedFileName")
        if not exported or not name:
            continue
        clean = re.sub(r"_\d+_[0-9A-F-]{36}", "", name)          # 01-today_0_<uuid>.png
        if not clean.endswith(".png"):
            clean += ".png"
        shutil.copy(os.path.join(src_dir, exported), os.path.join(out_dir, clean))
PY
  rm -rf "$tmp"
}

run() { # $1 = result bundle, rest = extra xcodebuild args
  local bundle="$1"; shift
  rm -rf "$bundle"
  xcodebuild test \
    -project Sankalpa.xcodeproj \
    -scheme Sankalpa \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$bundle" \
    "$@" \
    | grep -E "error:|Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" || true
  collect "$bundle"
}

xcrun simctl ui "$DEVICE" appearance light >/dev/null 2>&1 || true
run /tmp/claude-501/sankalpa-light.xcresult -skip-testing:"$DARK_TEST"


run /tmp/claude-501/sankalpa-dark.xcresult -only-testing:"$DARK_TEST"


echo "Screens written to $OUT"
ls -1 "$OUT"
