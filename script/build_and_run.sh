#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
pkill -x MacVM >/dev/null 2>&1 || true
./scripts/build-app.sh
APP_BUNDLE="$ROOT_DIR/dist/MacVM.app"
case "$MODE" in
    run) open -n "$APP_BUNDLE" ;;
    --verify|verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x MacVM >/dev/null; echo "MacVM is running." ;;
    --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/MacVM" ;;
    --logs|logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MacVM" OR process == "MacVMRunner"' ;;
    --telemetry|telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.burakerenoglu.macvm"' ;;
    *) echo "Usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
