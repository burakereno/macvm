#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" == 2 ]] || { echo 'Usage: verify-update-launch.sh notarized-MacVM.dmg signing-identity' >&2; exit 1; }
mkdir -p .build/integration
swiftc -parse-as-library Sources/MacVMUpdate/UpdateInstallerScript.swift Tests/Integration/InstallerLaunchCheck.swift -o .build/integration/InstallerLaunchCheck
.build/integration/InstallerLaunchCheck "$1" "$2"
