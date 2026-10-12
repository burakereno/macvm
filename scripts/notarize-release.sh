#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source .github/release-contract.env
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile.}"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity.}"
APP="dist/$APP_BUNDLE_NAME"
GUEST_PACKAGE="$APP/Contents/Resources/Helpers/MacVMRunner.app/Contents/Resources/GuestTools/Install MacVM Guest Tools.pkg"
package_signature="$(pkgutil --check-signature "$GUEST_PACKAGE")"
[[ "$package_signature" == *"Developer ID Installer:"* && "$package_signature" == *"($TEAM_IDENTIFIER)"* ]] || {
    echo 'Build with INSTALLER_SIGN_IDENTITY and GUEST_TOOLS_NOTARY_PROFILE before releasing Guest Tools.' >&2; exit 1;
}
xcrun stapler validate "$GUEST_PACKAGE"
spctl --assess --type install --verbose=4 "$GUEST_PACKAGE"
cp "$GUEST_PACKAGE" "dist/$GUEST_TOOLS_ASSET_NAME"
codesign --verify --deep --strict --verbose=2 "$APP"
for target in "$APP" "$APP/Contents/Resources/Helpers/MacVMRunner.app"; do
    signature="$(codesign -dv --verbose=4 "$target" 2>&1)"
    [[ "$signature" == *"TeamIdentifier=$TEAM_IDENTIFIER"* && "$signature" == *"runtime"* ]] || { echo "Invalid app publisher or missing hardened runtime." >&2; exit 1; }
done
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ditto -c -k --keepParent "$APP" "$TMP_DIR/$APP_NAME.zip"
xcrun notarytool submit "$TMP_DIR/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
./scripts/create-dmg.sh
xcrun notarytool submit "dist/$DMG_ASSET_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "dist/$DMG_ASSET_NAME"
xcrun stapler validate "dist/$DMG_ASSET_NAME"
codesign --verify --strict --verbose=2 "dist/$DMG_ASSET_NAME"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/$DMG_ASSET_NAME"
./scripts/create-update-manifest.sh
