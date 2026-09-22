#!/usr/bin/env bash
# Runs the UI suite against throwaway Sankalpa services.
#
# The two test classes want opposite fixtures, which is why each gets its own service:
#   ScreenTour   — the demo practice, seeded through the API by seed-demo.py
#   JourneyTests — nothing at all; every journey builds what it needs through the interface
#
# See service.sh for why a private service is what isolation means now.
#
# Usage: ./scripts/uitest.sh [simulator name]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${1:-iPhone 17 Pro}"
TOUR_PORT=8181
JOURNEY_PORT=8182

# shellcheck source=service.sh
source "$APP_DIR/scripts/service.sh"
trap 'service_stop_all "$TOUR_PORT" "$JOURNEY_PORT"' EXIT

run_class() {
    local class="$1" port="$2"
    echo "==> Running $class against http://localhost:$port"
    # The prefix is stripped and the rest handed to the test runner process, which is where
    # UITestCase reads it. It has to be in xcodebuild's environment: passed as an argument it
    # would be taken for a build setting and never reach the runner.
    TEST_RUNNER_SANKALPA_API_BASE_URL="http://localhost:$port" \
    xcodebuild test \
        -project "$APP_DIR/Sankalpa.xcodeproj" \
        -scheme Sankalpa \
        -destination "platform=iOS Simulator,name=$SIMULATOR" \
        -derivedDataPath "$APP_DIR/build/dd" \
        -parallel-testing-enabled NO \
        -only-testing:"SankalpaUITests/$class"
}

service_start "$TOUR_PORT" screentour
echo "==> screentour service ready on port $TOUR_PORT"
service_start "$JOURNEY_PORT" journeys
echo "==> journeys service ready on port $JOURNEY_PORT"

"$APP_DIR/scripts/seed-demo.py" --base-url "http://localhost:$TOUR_PORT"

failed=0
run_class ScreenTour "$TOUR_PORT" || failed=1
run_class JourneyTests "$JOURNEY_PORT" || failed=1

exit "$failed"
