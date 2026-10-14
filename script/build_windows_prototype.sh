#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if pgrep -x MacVMWindowsPrototype >/dev/null || pgrep -x MacVMWindowsDisplay >/dev/null; then
  echo "Quit the Windows prototype controller before rebuilding." >&2
  exit 1
fi
swift build --product MacVMWindowsPrototype
BIN_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/MacVM Windows Prototype.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/MacVMWindowsPrototype" "$APP_BUNDLE/Contents/MacOS/"
if [[ -f .build/MacVM.icns ]]; then cp .build/MacVM.icns "$APP_BUNDLE/Contents/Resources/"; fi
QEMU_DISPLAY="$APP_BUNDLE/Contents/Resources/Helpers/Windows Display.app"
mkdir -p "$QEMU_DISPLAY/Contents/MacOS" "$QEMU_DISPLAY/Contents/Resources"
export QEMU_DISPLAY
python3 - <<'PY'
import os
from pathlib import Path
binary = Path(os.environ['QEMU_DISPLAY'])/'Contents/MacOS/MacVMWindowsDisplay'
binary.unlink(missing_ok=True)
PY
cp /opt/homebrew/bin/qemu-system-aarch64 "$QEMU_DISPLAY/Contents/MacOS/MacVMWindowsDisplay"
cp /opt/homebrew/opt/qemu/COPYING "$QEMU_DISPLAY/Contents/Resources/QEMU-COPYING"
cp /opt/homebrew/opt/qemu/COPYING.LIB "$QEMU_DISPLAY/Contents/Resources/QEMU-COPYING.LIB"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -I "$BIN_DIR" \
  Tests/Manual/WindowsPrototypeIcon.swift "$BIN_DIR/MacVMUI.o" "$BIN_DIR/MacVMCore.o" -o .build/WindowsPrototypeIcon
.build/WindowsPrototypeIcon .build/WindowsPrototype.iconset
iconutil -c icns .build/WindowsPrototype.iconset -o "$QEMU_DISPLAY/Contents/Resources/Windows.icns"
export APP_BUNDLE QEMU_DISPLAY
python3 - <<'PY'
import os,plistlib
from pathlib import Path
info = {'CFBundleExecutable':'MacVMWindowsPrototype','CFBundleIdentifier':'com.burakerenoglu.macvm.windows-prototype',
        'CFBundleName':'MacVM Windows Prototype','CFBundlePackageType':'APPL','CFBundleVersion':'1',
        'CFBundleShortVersionString':'0.1','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,
        'NSPrincipalClass':'NSApplication','CFBundleIconFile':'MacVM'}
with (Path(os.environ['APP_BUNDLE'])/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
display = dict(info, CFBundleExecutable='MacVMWindowsDisplay', CFBundleIdentifier='com.burakerenoglu.macvm.windows-display',
               CFBundleName='Windows 11 ARM', CFBundleDisplayName='Windows 11 ARM', CFBundleIconFile='Windows')
with (Path(os.environ['QEMU_DISPLAY'])/'Contents/Info.plist').open('wb') as f: plistlib.dump(display,f)
PY
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime --entitlements Resources/WindowsPrototypeEngine.entitlements "$QEMU_DISPLAY"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "${1:-}" == "--run" ]]; then open "$APP_BUNDLE"; fi
echo "Built $APP_BUNDLE"
