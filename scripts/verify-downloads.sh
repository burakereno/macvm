#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$(mktemp -d)"
SERVER_PID=''
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -r "$WORK"
}
trap cleanup EXIT
python3 Tests/Fixtures/download-server.py > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
for ((i=0; i<50; i++)); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
[[ -s "$WORK/port" ]]
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
    Sources/MacVMCore/*.swift Tests/Integration/DownloadCheck.swift -o "$WORK/DownloadCheck"
"$WORK/DownloadCheck" "http://127.0.0.1:$(cat "$WORK/port")"
