#!/usr/bin/env bash
set -euo pipefail
# Homebrew is needed to build the distributable bundle, never to run a VM.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'Windows ARM builds require an Apple Silicon host.' >&2; exit 1; }
brew install qemu swtpm sevenzip
python3 "$ROOT_DIR/scripts/prepare-windows-firmware.py"
"$ROOT_DIR/scripts/prepare-windows-display-tools.sh"
