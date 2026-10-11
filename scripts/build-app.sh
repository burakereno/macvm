#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.burakerenoglu.macvm}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_BUNDLE="$ROOT_DIR/dist/MacVM.app"

if pgrep -x MacVMRunner >/dev/null; then
    echo "Shut down running MacVM machines before rebuilding the app bundle." >&2
    exit 1
fi
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
if [[ ! -f .build/MacVM.icns || scripts/generate-icon.swift -nt .build/MacVM.icns ]]; then
    swift scripts/generate-icon.swift "$ROOT_DIR/.build"
    iconutil -c icns .build/MacVM.iconset -o .build/MacVM.icns
fi
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Helpers"
cp "$BIN_DIR/MacVM" "$APP_BUNDLE/Contents/MacOS/MacVM"
cp .build/MacVM.icns "$APP_BUNDLE/Contents/Resources/MacVM.icns"
RUNNER="$APP_BUNDLE/Contents/Resources/Helpers/MacVMRunner.app"
mkdir -p "$RUNNER/Contents/MacOS" "$RUNNER/Contents/Resources"
cp "$BIN_DIR/MacVMRunner" "$RUNNER/Contents/MacOS/MacVMRunner"
cp .build/MacVM.icns "$RUNNER/Contents/Resources/MacVM.icns"
export APP_BUNDLE RUNNER APP_VERSION APP_BUILD_NUMBER BUNDLE_IDENTIFIER
python3 - <<'PY'
import os, plistlib
for path, executable, identifier in [
    (os.environ['APP_BUNDLE'], 'MacVM', os.environ['BUNDLE_IDENTIFIER']),
    (os.environ['RUNNER'], 'MacVMRunner', os.environ['BUNDLE_IDENTIFIER'] + '.runner')
]:
    info = {
        'CFBundleExecutable': executable, 'CFBundleIdentifier': identifier,
        'CFBundleName': executable, 'CFBundleDisplayName': 'MacVM' if executable == 'MacVM' else 'MacVM Machine',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': os.environ['APP_VERSION'],
        'CFBundleVersion': os.environ['APP_BUILD_NUMBER'], 'LSMinimumSystemVersion': '26.0',
        'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
        'CFBundleIconFile': 'MacVM', 'LSApplicationCategoryType': 'public.app-category.developer-tools',
        'NSHumanReadableCopyright': 'Copyright © 2026 Burak Erenoğlu.'
    }
    if executable == 'MacVM':
        info['UTExportedTypeDeclarations'] = [{
            'UTTypeIdentifier': identifier + '.machine', 'UTTypeDescription': 'MacVM Virtual Machine',
            'UTTypeConformsTo': ['com.apple.package'], 'UTTypeTagSpecification': {'public.filename-extension': ['macvm']}
        }]
        info['CFBundleDocumentTypes'] = [{
            'CFBundleTypeName': 'MacVM Virtual Machine', 'CFBundleTypeRole': 'Editor',
            'LSHandlerRank': 'Owner', 'LSItemContentTypes': [identifier + '.machine'], 'LSTypeIsPackage': True
        }]
    with open(path + '/Contents/Info.plist', 'wb') as file:
        plistlib.dump(info, file)
PY
SIGN_FLAGS=(--force --sign "$CODESIGN_IDENTITY" --options runtime --entitlements Resources/MacVM.entitlements)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$RUNNER"
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    for target in "$RUNNER" "$APP_BUNDLE"; do
        TEAM="$(codesign -dv --verbose=4 "$target" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
        [[ "$TEAM" == "66K3EFBVB6" ]] || { echo "Unexpected signing TeamIdentifier: $TEAM" >&2; exit 1; }
    done
fi
echo "Built $APP_BUNDLE"
