#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$PROJECT_DIR/logs"
RAW_LOG="$LOG_DIR/test-$RUN_ID.log"
SUMMARY="$LOG_DIR/test-$RUN_ID-summary.md"

mkdir -p "$LOG_DIR"
cd "$PROJECT_DIR"

set +e
mvn -Dmaven.repo.local=.m2/repository clean verify 2>&1 | tee "$RAW_LOG"
STATUS=${PIPESTATUS[0]}
set -e

RESULT_LINE="$(grep -E 'Tests run: [0-9]+, Failures:' "$RAW_LOG" | tail -1 || true)"
FAILURE_LINES="$(grep -E '^\[ERROR\]|<<< FAILURE|<<< ERROR' "$RAW_LOG" | tail -80 || true)"

{
  echo "# Sankalpa backend verification"
  echo
  echo "- Run: $RUN_ID"
  echo "- Command: mvn clean verify"
  echo "- Exit code: $STATUS"
  if [[ $STATUS -eq 0 ]]; then
    echo "- Verdict: PASS"
  else
    echo "- Verdict: FAIL"
  fi
  echo "- Test result: ${RESULT_LINE:-No aggregate test result found}"
  echo "- Raw log: $(basename "$RAW_LOG")"
  echo
  echo "## Failure evidence"
  echo
  if [[ -n "$FAILURE_LINES" ]]; then
    echo '```text'
    echo "$FAILURE_LINES"
    echo '```'
  else
    echo "No Maven or test failure lines were reported."
  fi
} > "$SUMMARY"

cp "$RAW_LOG" "$LOG_DIR/latest.log"
cp "$SUMMARY" "$LOG_DIR/latest-summary.md"
echo "LLM summary: $SUMMARY"
echo "Raw log: $RAW_LOG"
exit "$STATUS"
