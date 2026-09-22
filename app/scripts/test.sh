#!/bin/bash
# The one command that runs everything and leaves a report an LLM can read.
#
#   ./app/scripts/test.sh              every suite
#   ./app/scripts/test.sh --core       domain, application and storage only (no simulator)
#   ./app/scripts/test.sh --ui         the simulator suites only
#   ./app/scripts/test.sh --quick      core + UI, skipping the Release build
#   ./app/scripts/test.sh --clean      discard the shared build products first
#   ./app/scripts/test.sh --only testPauseAndResume                one UI test
#
# Every suite runs even when an earlier one fails, so one broken thing still yields a full
# picture; the exit status is the worst result. Output lands in
# app/build/test-runs/<timestamp>/, and app/build/test-runs/latest points at the newest run.
# The last KEEP_RUNS (default 5) of those directories are kept; older ones are removed.

set -uo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
APP_DIR="$PWD"

DEVICE_NAME="${DEVICE_NAME:-Sankalpa-Tests}"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
RUNTIME="${RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"

run_core=1
run_ui=1
run_release=1
only_test=""
clean=0

while [ $# -gt 0 ]; do
    case "$1" in
        --core)    run_ui=0; run_release=0 ;;
        --ui)      run_core=0; run_release=0 ;;
        --quick)   run_release=0 ;;
        --clean)   clean=1 ;;
        --only)    shift; only_test="${1:-}" ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# Build products are shared across runs and the results are not. A fresh derived-data
# directory per run would mean a full rebuild every time, which turns a two-minute check into a
# five-minute one and makes the suite something people stop running. Pass --clean to discard it.
DERIVED="${DERIVED:-$APP_DIR/build/DerivedData}"
CORE_BUILD="${CORE_BUILD:-$APP_DIR/build/core-build}"
[ "$clean" = 1 ] && rm -rf "$DERIVED" "$CORE_BUILD"

STAMP="$(date +%Y-%m-%d-%H%M%S)"
RUN="$APP_DIR/build/test-runs/$STAMP"
mkdir -p "$RUN/logs" "$RUN/raw" "$RUN/screens"
ln -sfn "$RUN" "$APP_DIR/build/test-runs/latest"

worst=0
note() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31m    %s\033[0m\n' "$*"; }

# xcodebuild can hang after its tests have already finished — resolving the package graph, or
# waiting on a file-system watcher that never fires. A harness whose whole purpose is to leave a
# report behind must not be the thing that never returns, so every long step runs under a limit
# and a step that exceeds it is reported as a failure like any other.
CORE_TIMEOUT="${CORE_TIMEOUT:-600}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
UI_TIMEOUT="${UI_TIMEOUT:-1800}"
# Ports for the throwaway services the UI suites run against.
TOUR_PORT="${TOUR_PORT:-8181}"
JOURNEY_PORT="${JOURNEY_PORT:-8182}"
RELEASE_TIMEOUT="${RELEASE_TIMEOUT:-900}"

limited() { # $1 = seconds, rest = command
    local seconds="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$seconds"; kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"
    local status=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$status"
}

# ---------------------------------------------------------------- environment

{
    printf 'xcode_version=%s\n' "$(xcodebuild -version | head -1 | awk '{print $2}')"
    printf 'xcode_build=%s\n' "$(xcodebuild -version | tail -1 | awk '{print $3}')"
    printf 'macos_version=%s\n' "$(sw_vers -productVersion)"
    printf 'device_name=%s\n' "$DEVICE_NAME"
    printf 'device_type=%s\n' "${DEVICE_TYPE##*.}"
    printf 'runtime=%s\n' "${RUNTIME##*.}"
    printf 'git_commit=%s\n' "$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'git_branch=%s\n' "$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'git_dirty=%s\n' "$(test -n "$(git -C "$APP_DIR" status --porcelain 2>/dev/null)" && echo yes || echo no)"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RUN/environment.txt"

# ------------------------------------------------------------- core (no simulator)
#
# The domain, application and storage suites are pure Swift and run on the macOS toolchain in
# seconds. --event-stream-output-path is what makes the report readable: it carries each test's
# own sentence-long name and the exact source location of every failure, which neither the
# console log nor the JUnit file gives in full.

if [ "$run_core" = 1 ]; then
    note "Core: domain, application and storage"
    limited "$CORE_TIMEOUT" xcrun swift test \
        --package-path SankalpaCore \
        --scratch-path "$CORE_BUILD" \
        --event-stream-output-path "$RUN/raw/core-events.jsonl" \
        --event-stream-version 0 \
        > "$RUN/logs/core.log" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        worst=1
        [ "$status" -ge 128 ] \
            && fail "core suites did not finish within ${CORE_TIMEOUT}s and were stopped" \
            || fail "core suites failed (see logs/core.log)"
    fi
fi

# ---------------------------------------------------------------------- simulator

boot_device() {
    local id
    id=$(xcrun simctl list devices -j \
        | python3 -c "
import json,sys
want = sys.argv[1]
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for device in devices:
        if device['name'] == want and device['isAvailable']:
            print(device['udid']); raise SystemExit
" "$DEVICE_NAME")

    if [ -z "$id" ]; then
        # A dedicated simulator, so a run never touches whatever is on the user's own devices
        # and never has to uninstall an app that is not ours.
        id=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME") || return 1
    fi
    xcrun simctl bootstatus "$id" -b > /dev/null 2>&1 || xcrun simctl boot "$id" > /dev/null 2>&1
    xcrun simctl bootstatus "$id" -b > /dev/null 2>&1
    # A run must not inherit the appearance or text size the last one left behind.
    xcrun simctl ui "$id" appearance light > /dev/null 2>&1
    printf '%s' "$id"
}

if [ "$run_ui" = 1 ]; then
    note "Booting $DEVICE_NAME"
    DEVICE_ID=$(boot_device)
    if [ -z "$DEVICE_ID" ]; then
        fail "no simulator available; skipping the UI suites"
        worst=1
        run_ui=0
    else
        printf 'device_id=%s\n' "$DEVICE_ID" >> "$RUN/environment.txt"
    fi
fi

# Building and testing are two steps rather than one `xcodebuild test`, for two reasons. A
# combined run reliably hangs here after its tests have finished — never writing the result
# bundle, so the run has evidence of nothing — while the split exits cleanly and leaves a
# complete bundle. And a build failure and a test failure are different findings that deserve
# different words in the report, which a single step cannot tell apart.

if [ "$run_ui" = 1 ]; then
    note "Building the UI suites"
    limited "$BUILD_TIMEOUT" xcodebuild build-for-testing \
        -project Sankalpa.xcodeproj \
        -scheme Sankalpa \
        -destination "platform=iOS Simulator,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED" \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        > "$RUN/logs/ui-build.log" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        worst=1
        fail "the UI suites did not build (see logs/ui-build.log)"
        run_ui=0
    fi
fi

# The practice lives in the service, so the UI suites need one — and the two classes need
# opposite fixtures, so they get one each. See scripts/service.sh.
if [ "$run_ui" = 1 ]; then
    # shellcheck source=service.sh
    source "$APP_DIR/scripts/service.sh"
    trap 'service_stop_all "$TOUR_PORT" "$JOURNEY_PORT"' EXIT

    note "Starting throwaway services for the UI suites"
    if ! service_start "$TOUR_PORT" screentour || ! service_start "$JOURNEY_PORT" journeys; then
        worst=1
        fail "the UI suites need the backend service, which did not start"
        run_ui=0
    elif ! "$APP_DIR/scripts/seed-demo.py" --base-url "http://localhost:$TOUR_PORT" \
            > "$RUN/logs/seed.log" 2>&1; then
        worst=1
        fail "the demo fixture could not be seeded (see logs/seed.log)"
        run_ui=0
    fi
fi

# Each class runs against its own service: ScreenTour walks the seeded demo practice, JourneyTests
# builds everything it needs through the interface and asserts on empty states. One `xcodebuild
# test` run could not give them different fixtures.
run_ui_class() {
    local class="$1" port="$2"
    local only_args=()
    if [ -n "$only_test" ]; then
        case "$only_test" in
            "$class"|"$class"/*) only_args=(-only-testing:"SankalpaUITests/$only_test") ;;
            */*) return 0 ;;
            # A bare test name could belong to either class; -only-testing simply matches nothing
            # in the one it is not in, which xcodebuild reports rather than passing silently.
            *) only_args=(-only-testing:"SankalpaUITests/$class/$only_test") ;;
        esac
    else
        only_args=(-only-testing:"SankalpaUITests/$class")
    fi

    # The prefix is stripped and the rest handed to the test runner process, which is where
    # UITestCase reads it. It has to be in xcodebuild's environment: passed as an argument it
    # would be taken for a build setting and never reach the runner.
    TEST_RUNNER_SANKALPA_API_BASE_URL="http://localhost:$port" \
    limited "$UI_TIMEOUT" xcodebuild test-without-building \
        -project Sankalpa.xcodeproj \
        -scheme Sankalpa \
        -destination "platform=iOS Simulator,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED" \
        -resultBundlePath "$RUN/raw/$class.xcresult" \
        -parallel-testing-enabled NO \
        "${only_args[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        >> "$RUN/logs/ui.log" 2>&1
}

if [ "$run_ui" = 1 ]; then
    note "UI: journeys, screens and recovery"
    status=0
    run_ui_class ScreenTour "$TOUR_PORT" || status=$?
    run_ui_class JourneyTests "$JOURNEY_PORT" || status=$?
    if [ "$status" -ne 0 ]; then
        worst=1
        if [ "$status" -ge 128 ]; then
            fail "UI suites did not finish within ${UI_TIMEOUT}s and were stopped"
            printf 'ui_timed_out=yes\n' >> "$RUN/environment.txt"
        else
            fail "UI suites failed (see logs/ui.log)"
        fi
    fi

    # Screenshots are evidence: a failure report that names a screen is worth far more with the
    # picture beside it. Exported whether the run passed or failed.
    for bundle in "$RUN"/raw/*.xcresult; do
        [ -f "$bundle/Info.plist" ] || continue
        xcrun xcresulttool export attachments \
            --path "$bundle" \
            --output-path "$RUN/raw/attachments" \
            >> "$RUN/logs/attachments.log" 2>&1
    done
fi

# ------------------------------------------------------------------------ release
#
# Where an optimiser difference or a mistaken `#if DEBUG` shows up. The test launch arguments
# are all debug-only, so a Release build is the only thing that proves the app still compiles
# without them.

if [ "$run_release" = 1 ]; then
    note "Release build for a generic device"
    limited "$RELEASE_TIMEOUT" xcodebuild build \
        -project Sankalpa.xcodeproj \
        -scheme Sankalpa \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED-Release" \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        > "$RUN/logs/release.log" 2>&1
    status=$?
    [ "$status" -ne 0 ] && { worst=1; fail "release build failed (see logs/release.log)"; }
fi

# ------------------------------------------------------------------------- report

printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RUN/environment.txt"
printf 'ran_core=%s\nran_ui=%s\nran_release=%s\n' "$run_core" "$run_ui" "$run_release" \
    >> "$RUN/environment.txt"

python3 "$APP_DIR/scripts/report.py" "$RUN" || worst=1

# A run leaves about a hundred megabytes behind, nearly all of it the result bundle. Keeping
# every one of them turns a suite people run often into a disk problem, so only the most recent
# few are kept — the reports themselves are small, but they live inside the run directory, so
# the whole thing goes together rather than leaving reports that point at nothing.
KEEP_RUNS="${KEEP_RUNS:-5}"
if [ "$KEEP_RUNS" -gt 0 ]; then
    ls -1d "$APP_DIR/build/test-runs"/20* 2>/dev/null \
        | sort -r \
        | tail -n "+$((KEEP_RUNS + 1))" \
        | while read -r old; do rm -rf "$old"; done
fi

note "Report: $RUN/report.md"
printf '     also: %s/results.json\n' "$RUN"
cat "$RUN/summary.txt" 2>/dev/null

exit "$worst"
