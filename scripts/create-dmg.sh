#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source .github/release-contract.env
[[ -d "dist/$APP_BUNDLE_NAME" ]] || { echo "Build the app first." >&2; exit 1; }
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "dist/$APP_BUNDLE_NAME" "$STAGING/$APP_BUNDLE_NAME"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "dist/$DMG_ASSET_NAME"
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "dist/$DMG_ASSET_NAME"
    codesign --verify --strict --verbose=2 "dist/$DMG_ASSET_NAME"
    TEAM="$(codesign -dv --verbose=4 "dist/$DMG_ASSET_NAME" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$TEAM" == "$TEAM_IDENTIFIER" ]] || { echo "Unexpected DMG publisher." >&2; exit 1; }
fi
echo "Created dist/$DMG_ASSET_NAME"
