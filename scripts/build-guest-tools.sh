#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
GUEST_BINARY="$1"
OUTPUT_DIR="$2"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
if [[ "${REQUIRE_GUEST_TOOLS_RELEASE_TRUST:-0}" == 1 ]]; then
    : "${INSTALLER_SIGN_IDENTITY:?A Developer ID Installer identity is required for release Guest Tools.}"
    : "${GUEST_TOOLS_NOTARY_PROFILE:?Notarize Guest Tools before signing the containing app.}"
fi
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
PAYLOAD="$STAGING/payload"
TOOLS="$PAYLOAD/Library/Application Support/MacVM/GuestTools"
GUEST_APP="$TOOLS/MacVM Guest.app"
mkdir -p "$GUEST_APP/Contents/MacOS" "$PAYLOAD/Library/LaunchAgents" "$OUTPUT_DIR"
cp "$GUEST_BINARY" "$GUEST_APP/Contents/MacOS/MacVMGuest"
cp Resources/GuestTools/Info.plist "$GUEST_APP/Contents/Info.plist"
python3 - "$GUEST_APP/Contents/Info.plist" "$APP_VERSION" "$APP_BUILD_NUMBER" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
info['CFBundleShortVersionString'], info['CFBundleVersion'] = sys.argv[2:]
with open(sys.argv[1], 'wb') as file:
    plistlib.dump(info, file)
PY
cp Resources/GuestTools/uninstall.sh "$TOOLS/uninstall.sh"
chmod 755 "$TOOLS/uninstall.sh"
cp Resources/GuestTools/com.burakerenoglu.macvm.guest.plist "$PAYLOAD/Library/LaunchAgents/"
chmod 755 "$GUEST_APP/Contents/MacOS/MacVMGuest"
chmod 644 "$PAYLOAD/Library/LaunchAgents/com.burakerenoglu.macvm.guest.plist"
FLAGS=(--force --sign "${CODESIGN_IDENTITY:--}" --options runtime --identifier com.burakerenoglu.macvm.guest --entitlements Resources/MacVMGuest.entitlements)
if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then FLAGS+=(--timestamp); fi
codesign "${FLAGS[@]}" "$GUEST_APP"
codesign --verify --strict "$GUEST_APP"
if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
    signature="$(codesign -dv --verbose=4 "$GUEST_APP" 2>&1)"
    [[ "$signature" == *"TeamIdentifier=66K3EFBVB6"* && "$signature" == *"runtime"* ]] || { echo 'Invalid Guest Tools publisher.' >&2; exit 1; }
fi
pkgbuild --analyze --root "$PAYLOAD" "$STAGING/components.plist"
python3 - "$STAGING/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as file:
    components = plistlib.load(file)
for component in components:
    # launchd uses a fixed path; Installer must not relocate an update to a copy.
    component['BundleIsRelocatable'] = False
with open(path, 'wb') as file:
    plistlib.dump(components, file)
PY
pkgbuild --root "$PAYLOAD" --ownership recommended --scripts Resources/GuestTools/scripts \
    --component-plist "$STAGING/components.plist" \
    --identifier com.burakerenoglu.macvm.guest --version "$APP_VERSION" \
    --install-location / "$STAGING/GuestToolsComponent.pkg"
cat > "$STAGING/Distribution.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MacVM Guest Tools</title>
  <welcome file="Welcome.html"/>
  <conclusion file="Conclusion.html"/>
  <options customize="never" hostArchitectures="arm64"/>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
  <choices-outline><line choice="tools"/></choices-outline>
  <choice id="tools" visible="false"><pkg-ref id="com.burakerenoglu.macvm.guest"/></choice>
  <pkg-ref id="com.burakerenoglu.macvm.guest">GuestToolsComponent.pkg</pkg-ref>
</installer-gui-script>
XML
PACKAGE="$OUTPUT_DIR/Install MacVM Guest Tools.pkg"
PRODUCT_FLAGS=(--distribution "$STAGING/Distribution.xml" --resources Resources/GuestTools/Installer --package-path "$STAGING")
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    PRODUCT_FLAGS+=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
    if [[ -n "${INSTALLER_KEYCHAIN:-}" ]]; then PRODUCT_FLAGS+=(--keychain "$INSTALLER_KEYCHAIN"); fi
fi
productbuild "${PRODUCT_FLAGS[@]}" "$PACKAGE"
[[ -s "$PACKAGE" ]] || { echo 'Guest Tools installer was not created.' >&2; exit 1; }
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    package_signature="$(pkgutil --check-signature "$PACKAGE")"
    [[ "$package_signature" == *"Developer ID Installer:"* && "$package_signature" == *"(66K3EFBVB6)"* ]] || { echo 'Invalid installer publisher.' >&2; exit 1; }
else
    echo 'Development package: payload is code-signed; Installer signature and notarization are not configured.'
fi
if [[ -n "${GUEST_TOOLS_NOTARY_PROFILE:-}" ]]; then
    : "${INSTALLER_SIGN_IDENTITY:?Sign the installer before notarizing it.}"
    NOTARY_ARGS=(--keychain-profile "$GUEST_TOOLS_NOTARY_PROFILE" --wait)
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
    xcrun notarytool submit "$PACKAGE" "${NOTARY_ARGS[@]}"
    xcrun stapler staple "$PACKAGE"
    xcrun stapler validate "$PACKAGE"
    spctl --assess --type install --verbose=4 "$PACKAGE"
fi
cp 'Resources/GuestTools/Read Me.html' "$OUTPUT_DIR/Read Me.html"
