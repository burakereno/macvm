#!/usr/bin/env bash
# Reproducible real-VM check. Installers stay visible in Downloads.
set -euo pipefail
TASK_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_REPO_DIR"
TASK_PROFILE="${1:-server}"
TASK_RELEASE="${2:-resolute}"
TASK_DEVELOPMENT="${3:-no}"
case "$TASK_PROFILE" in server|gnome|xfce) ;; *) exit 2 ;; esac
case "$TASK_RELEASE" in resolute|noble) ;; *) exit 2 ;; esac
case "$TASK_DEVELOPMENT" in yes|no) ;; *) exit 2 ;; esac
TASK_TEST_ROOT="$TASK_REPO_DIR/.local/UbuntuAutomatic-$(uuidgen)"
mkdir -p .build/integration
mkdir -m 700 -p "$TASK_TEST_ROOT"
for task_check in UbuntuDownloadCheck UbuntuAutomaticCheck; do
    swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
        Sources/MacVMCore/*.swift "Tests/Integration/$task_check.swift" \
        -o ".build/integration/$task_check"
done
codesign --force --sign - --entitlements Resources/MacVM.entitlements .build/integration/UbuntuAutomaticCheck
TASK_DOWNLOAD_OUTPUT="$(.build/integration/UbuntuDownloadCheck "$TASK_RELEASE" "$TASK_TEST_ROOT")"
TASK_IMAGE_PATH="$(printf '%s\n' "$TASK_DOWNLOAD_OUTPUT" | tail -n 1)"
ssh-keygen -q -t ed25519 -N '' -C macvm-disposable-test -f "$TASK_TEST_ROOT/test-key"
.build/integration/UbuntuAutomaticCheck "$TASK_TEST_ROOT" "$TASK_PROFILE" "$TASK_RELEASE" "$TASK_IMAGE_PATH" "$TASK_DEVELOPMENT" > "$TASK_TEST_ROOT/Harness.log" 2>&1 &
TASK_VM_PID=$!
cleanup() {
    touch "$TASK_TEST_ROOT/Stop"
    local task_shutdown_deadline=$((SECONDS + 60))
    while kill -0 "$TASK_VM_PID" 2>/dev/null && [ "$SECONDS" -lt "$task_shutdown_deadline" ]; do sleep 1; done
    if kill -0 "$TASK_VM_PID" 2>/dev/null; then
        printf 'Guest still active; private test files retained at %s\n' "$TASK_TEST_ROOT"
        return
    fi
    wait "$TASK_VM_PID" 2>/dev/null || true
    python3 - "$TASK_TEST_ROOT" <<'PY'
import fcntl, pathlib, shutil, sys
root = pathlib.Path(sys.argv[1]).resolve()
assert root.parent.name == '.local' and root.name.startswith('UbuntuAutomatic-')
path_file = root / 'MachinePath'
if path_file.exists():
    machine = pathlib.Path(path_file.read_text()).resolve()
    assert machine.parent == root and machine.suffix == '.macvm'
    with open(machine / '.lock', 'r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        shutil.rmtree(machine)
for name in ['test-key', 'test-key.pub', 'TestCredential', 'known_hosts', 'ReadyIP', 'MachinePath']:
    (root / name).unlink(missing_ok=True)
PY
}
trap cleanup EXIT
TASK_SETUP_DEADLINE=$((SECONDS + 3600))
while [ ! -f "$TASK_TEST_ROOT/ReadyIP" ]; do
    if ! kill -0 "$TASK_VM_PID" 2>/dev/null || [ "$SECONDS" -ge "$TASK_SETUP_DEADLINE" ]; then
        printf 'Setup did not complete. Inspect %s\n' "$TASK_TEST_ROOT/Harness.log"
        exit 1
    fi
    sleep 3
done
python3 Tests/Integration/verify-ubuntu-guest.py "$TASK_TEST_ROOT"
python3 Tests/Integration/check-ubuntu-profile.py "$TASK_TEST_ROOT"
printf 'PASS: %s / %s / development=%s\n' "$TASK_RELEASE" "$TASK_PROFILE" "$TASK_DEVELOPMENT"
printf 'Installer remains visible in Downloads and Settings → Installation Files.\n'
