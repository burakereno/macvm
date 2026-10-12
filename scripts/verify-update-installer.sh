#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/integration
swiftc -parse-as-library Sources/MacVMUpdate/UpdateInstallerScript.swift Tests/Integration/InstallerFailureCheck.swift -o .build/integration/InstallerFailureCheck
.build/integration/InstallerFailureCheck
