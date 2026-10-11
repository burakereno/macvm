#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a
source .github/release-contract.env
set +a
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "dist/$APP_BUNDLE_NAME/Contents/Info.plist")"
SHA256="$(shasum -a 256 "dist/$DMG_ASSET_NAME" | awk '{print $1}')"
export APP_VERSION SHA256
python3 - <<'PY'
import json, os
manifest = {'version': os.environ['APP_VERSION'], 'asset': os.environ['DMG_ASSET_NAME'],
            'sha256': os.environ['SHA256'], 'bundleIdentifier': os.environ['BUNDLE_IDENTIFIER'],
            'teamIdentifier': os.environ['TEAM_IDENTIFIER']}
with open('dist/' + os.environ['MANIFEST_ASSET_NAME'], 'w') as file:
    json.dump(manifest, file, indent=2)
    file.write('\n')
PY
