#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$(mktemp -d)"
SERVER_PID=''
cleanup() {
    local result=$?
    if [[ "$result" != 0 && -f "$WORK/server.log" ]]; then cat "$WORK/server.log" >&2; fi
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -r "$WORK"
}
trap cleanup EXIT
python3 Tests/Fixtures/download-server.py > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
for ((i=0; i<120; i++)); do [[ -s "$WORK/port" ]] && break; sleep 0.5; done
if [[ ! -s "$WORK/port" ]]; then
    echo "Loopback fixture did not become ready within 60 seconds." >&2
    ps -p "$SERVER_PID" -o pid,command >&2 || true
    exit 1
fi
read -r TASK_HTTP_PORT < "$WORK/port"
[[ "$TASK_HTTP_PORT" =~ ^[0-9]+$ ]] || { echo "Loopback fixture returned an invalid port." >&2; exit 1; }
kill -0 "$SERVER_PID"
curl --noproxy '*' --fail --silent --show-error --max-time 5 "http://127.0.0.1:$TASK_HTTP_PORT/health" > /dev/null || {
    ps -p "$SERVER_PID" -o pid,command >&2
    lsof -Pan -p "$SERVER_PID" -iTCP -sTCP:LISTEN >&2 || true
    exit 1
}
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
    Sources/MacVMCore/*.swift Tests/Integration/DownloadCheck.swift -o "$WORK/DownloadCheck"
"$WORK/DownloadCheck" "http://127.0.0.1:$TASK_HTTP_PORT"
