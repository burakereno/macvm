#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/integration
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
    Sources/MacVMCore/*.swift Tests/Integration/MacOSConfigurationCheck.swift \
    -o .build/integration/MacOSConfigurationCheck
codesign --force --sign - --entitlements Resources/MacVM.entitlements .build/integration/MacOSConfigurationCheck
.build/integration/MacOSConfigurationCheck
