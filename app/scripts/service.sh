#!/usr/bin/env bash
# Throwaway Sankalpa services for the UI suites, sourced by uitest.sh and test.sh.
#
# The practice lives in the service now, so a UI test cannot get a private store by pointing at
# its own file. It gets a private service instead: each one runs on its own port with its own
# SQLite database, and both are deleted afterwards. That matters because the API has no delete —
# without a fresh database every run would inherit the last one's sankalpas, and the empty-state
# assertions would never hold again.
#
# Callers use:  service_start <port> <name>;  service_stop_all;  SERVICE_WORK_DIR

SERVICE_PIDS=()
SERVICE_WORK_DIR="$(mktemp -d)"
# The service reads offset-free timestamps in this zone and the app uses the device's. They have
# to be the same zone, or the two ends disagree about what day it is.
SERVICE_TIMEZONE="${SANKALPA_TIMEZONE:-$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')}"

service_backend_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../backend" && pwd
}

# service_start <port> <name> — starts a backend with an empty database and waits for it to answer.
service_start() {
    local port="$1" name="$2" backend
    backend="$(service_backend_dir)"

    ( cd "$backend" && \
      SANKALPA_TIMEZONE="$SERVICE_TIMEZONE" \
      SANKALPA_DB_URL="jdbc:sqlite:$SERVICE_WORK_DIR/$name.db" \
      PORT="$port" \
      mvn -q -Dmaven.repo.local=.m2/repository spring-boot:run \
        > "$SERVICE_WORK_DIR/$name.log" 2>&1 ) &
    SERVICE_PIDS+=($!)

    local waited=0
    until curl -sf --max-time 2 "http://localhost:$port/api/v1/sankalpas" -o /dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge 180 ]; then
            echo "The $name service never answered on port $port:" >&2
            tail -30 "$SERVICE_WORK_DIR/$name.log" >&2
            return 1
        fi
    done
    return 0
}

service_stop_all() {
    for pid in "${SERVICE_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Spring Boot's run goal forks, so the child keeps the port unless it is asked too.
    for port in "$@"; do
        local holder
        holder="$(lsof -ti "tcp:$port" 2>/dev/null || true)"
        [ -n "$holder" ] && kill $holder 2>/dev/null || true
    done
    rm -rf "$SERVICE_WORK_DIR"
}
