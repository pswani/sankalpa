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

# Each UI test uses its own store file (SANKALPA_TEST_STORE), so nothing here needs to uninstall
# the app or disturb whatever data is already on this simulator.

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
        # Only our own numbered captures; XCTest also attaches screen recordings and synthesized
        # event dumps when a test fails, and those are not part of the review gallery.
        if not re.match(r"^\d{2}[a-z]?-", clean):
            continue
        shutil.copy(os.path.join(src_dir, exported), os.path.join(out_dir, clean))
PY
  rm -rf "$tmp"
}

run() { # $1 = result bundle, rest = extra xcodebuild args
  local bundle="$1"; shift
  local status=0
  rm -rf "$bundle"
  xcodebuild test \
    -project Sankalpa.xcodeproj \
    -scheme Sankalpa \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$bundle" \
    "$@" \
    > "$bundle.log" 2>&1 || status=$?
  grep -E "error:|Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" "$bundle.log" || true
  if [ "${status:-0}" -ne 0 ]; then
    echo "--- last 60 lines of $bundle.log ---"
    tail -60 "$bundle.log"
  fi
  collect "$bundle"
  return "${status:-0}"
}

# Both passes run even if the first fails, so one broken screen still yields a full gallery to
# review — but the script's own exit status reflects any failure.
worst=0
xcrun simctl ui "$DEVICE" appearance light >/dev/null 2>&1 || true
run /tmp/claude-501/sankalpa-light.xcresult -skip-testing:"$DARK_TEST" || worst=$?
run /tmp/claude-501/sankalpa-dark.xcresult -only-testing:"$DARK_TEST" || worst=$?

# Release catches optimiser and `#if DEBUG` breakage a simulator Debug build hides.
echo "Release build…"
if ! xcodebuild build \
  -project Sankalpa.xcodeproj \
  -scheme Sankalpa \
  -configuration Release \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED-release" \
  > /tmp/claude-501/sankalpa-release.log 2>&1
then
  echo "Release build FAILED"
  tail -40 /tmp/claude-501/sankalpa-release.log
  worst=1
else
  echo "Release build succeeded"
fi

echo "Screens written to $OUT"
ls -1 "$OUT"
exit "$worst"
