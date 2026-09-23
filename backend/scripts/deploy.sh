#!/bin/zsh
emulate -LR zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RUN_DIR="$PROJECT_DIR/run"
LOG_DIR="$PROJECT_DIR/logs"
PID_FILE="$RUN_DIR/server.pid"
SERVER_LOG="$LOG_DIR/server.log"
PORT="${PORT:-8080}"
DATABASE_URL="${SANKALPA_DB_URL:-jdbc:sqlite:$PROJECT_DIR/data/sankalpa.db}"

usage() {
    cat <<'EOF'
Usage: ./scripts/deploy.sh [--skip-verify]

Builds, replaces, and health-checks the local Sankalpa backend.

Environment:
  SANKALPA_TIMEZONE  IANA time zone; defaults to the Mac's configured zone
  SANKALPA_DB_URL    defaults to backend/data/sankalpa.db
  PORT               defaults to 8080
EOF
}

SKIP_VERIFY=0
case "${1:-}" in
    "") ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || {
    echo "PORT must be a number between 1 and 65535." >&2
    exit 2
}

TIMEZONE="${SANKALPA_TIMEZONE:-}"
if [[ -z "$TIMEZONE" ]]; then
    LOCALTIME_TARGET="$(readlink /etc/localtime 2>/dev/null || true)"
    if [[ "$LOCALTIME_TARGET" == *"/zoneinfo/"* ]]; then
        TIMEZONE="${LOCALTIME_TARGET##*/zoneinfo/}"
    else
        echo "Set SANKALPA_TIMEZONE to an IANA zone such as America/Chicago." >&2
        exit 2
    fi
fi

command -v java >/dev/null || { echo "Java is required." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required for the health check." >&2; exit 1; }

mkdir -p "$RUN_DIR" "$LOG_DIR" "$PROJECT_DIR/data"

if ((SKIP_VERIFY == 0)); then
    echo "Verifying backend…"
    "$SCRIPT_DIR/verify.sh"
else
    echo "Skipping verification by request."
fi

JAR="$(find "$PROJECT_DIR/target" -maxdepth 1 -type f \
    -name 'sankalpa-backend-*.jar' ! -name '*.original' -print -quit)"
if [[ -z "$JAR" ]]; then
    echo "No deployable backend jar was found. Run ./scripts/verify.sh first." >&2
    exit 1
fi

is_sankalpa_process() {
    local pid="$1" command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"sankalpa-backend"* || "$command" == *"com.sankalpa.SankalpaApplication"* ]]
}

stop_process() {
    local pid="$1" waited=0
    kill -TERM "$pid" 2>/dev/null || return 0
    while kill -0 "$pid" 2>/dev/null && ((waited < 20)); do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "The previous backend did not stop within 20 seconds; stopping it now."
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(tr -d '[:space:]' < "$PID_FILE")"
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        if ! is_sankalpa_process "$OLD_PID"; then
            echo "Refusing to stop PID $OLD_PID because it is not the Sankalpa backend." >&2
            echo "Remove $PID_FILE only after checking that process." >&2
            exit 1
        fi
        echo "Stopping backend process ${OLD_PID}…"
        stop_process "$OLD_PID"
    fi
    rm -f "$PID_FILE"
fi

# Adopt a backend that was started manually before this script existed. Never stop an unrelated
# process merely because it uses the configured port.
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! is_sankalpa_process "$pid"; then
        echo "Port $PORT is already used by a process that is not the Sankalpa backend (PID $pid)." >&2
        exit 1
    fi
    echo "Stopping existing backend process ${pid} on port ${PORT}…"
    stop_process "$pid"
done < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)

echo "Starting backend on port ${PORT}…"
: > "$SERVER_LOG"
cd "$PROJECT_DIR"
SANKALPA_TIMEZONE="$TIMEZONE" \
SANKALPA_DB_URL="$DATABASE_URL" \
PORT="$PORT" \
java -jar "$JAR" >> "$SERVER_LOG" 2>&1 &!
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"

HEALTH_URL="http://localhost:$PORT/api/v1/sankalpas"
repeat 60; do
    if curl -sf --max-time 2 "$HEALTH_URL" -o /dev/null; then
        echo "Backend deployed successfully."
        echo "PID: $NEW_PID"
        echo "Health: $HEALTH_URL"
        echo "Log: $SERVER_LOG"
        exit 0
    fi
    if ! kill -0 "$NEW_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

echo "The backend did not become healthy. Recent log output:" >&2
tail -40 "$SERVER_LOG" >&2 || true
if kill -0 "$NEW_PID" 2>/dev/null; then
    stop_process "$NEW_PID"
fi
rm -f "$PID_FILE"
exit 1
