import Foundation

/// One installer implementation, passed only positional arguments.
enum UpdateInstallerScript {
    static let source = #"""
#!/bin/bash
set -euo pipefail
WORK=$1
TARGET=$2
VERSION=$3
SHA256=$4
BUNDLE_ID=$5
TEAM_ID=$6
PARENT_PID=$7
DMG="$WORK/MacVM.dmg"
MOUNT="$WORK/mount"
STAGING=''
BACKUP_APP=''
MOUNTED=0
REPLACED=0
launchConfirmation=0
cleanup_and_rollback() {
    local result=$?
    if [[ "$MOUNTED" == 1 ]]; then /usr/bin/hdiutil detach "$MOUNT" -quiet -force || true; fi
    if [[ "$REPLACED" == 1 && "$launchConfirmation" == 0 && -d "$BACKUP_APP" ]]; then
        if [[ -d "$TARGET" ]]; then /bin/mv "$TARGET" "$STAGING/failed.app"; fi
        /bin/mv "$BACKUP_APP" "$TARGET"
        /usr/bin/open "$TARGET" || true
    fi
    if [[ -n "$STAGING" && -d "$STAGING" ]]; then /bin/rm -r "$STAGING"; fi
    if [[ -d "$WORK" ]]; then /bin/rm -r "$WORK"; fi
    exit "$result"
}
trap cleanup_and_rollback EXIT
trap 'exit 130' INT TERM
[[ "$TEAM_ID" == '66K3EFBVB6' && "$BUNDLE_ID" == 'com.burakerenoglu.macvm' ]]
[[ "$PARENT_PID" =~ ^[0-9]+$ && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$SHA256" =~ ^[a-f0-9]{64}$ ]]
[[ -d "$WORK" && ! -L "$WORK" && -d "$TARGET" && ! -L "$TARGET" && "${TARGET##*/}" == MacVM.app ]]
! /usr/bin/pgrep -x MacVMRunner >/dev/null
[[ "$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')" == "$SHA256" ]]
/usr/bin/codesign --verify --strict --verbose=2 "$DMG"
[[ "$(/usr/bin/codesign -dv --verbose=4 "$DMG" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')" == "$TEAM_ID" ]]
/usr/sbin/spctl --assess --type open --context context:primary-signature "$DMG"
/bin/mkdir "$MOUNT"
/usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -quiet -mountpoint "$MOUNT"
MOUNTED=1
STAGED_APP_SOURCE="$MOUNT/MacVM.app"
[[ -d "$STAGED_APP_SOURCE" && ! -L "$STAGED_APP_SOURCE" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP_SOURCE/Contents/Info.plist")" == "$BUNDLE_ID" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP_SOURCE/Contents/Info.plist")" == "$VERSION" ]]
[[ -x "$STAGED_APP_SOURCE/Contents/MacOS/MacVM" ]]
REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
/usr/bin/codesign --verify --deep --strict --verbose=2 -R="$REQUIREMENT" "$STAGED_APP_SOURCE"
SIGNATURE="$(/usr/bin/codesign -dv --verbose=4 "$STAGED_APP_SOURCE" 2>&1)"
[[ "$SIGNATURE" == *"TeamIdentifier=$TEAM_ID"* && "$SIGNATURE" == *runtime* ]]
/usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP_SOURCE"
STAGING=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$TARGET")/.MacVM-update.XXXXXX")
/bin/chmod 700 "$STAGING"
/usr/bin/ditto "$STAGED_APP_SOURCE" "$STAGING/MacVM.app"
/usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT" "$STAGING/MacVM.app"
BACKUP_APP="$STAGING/previous.app"
# The old app stays intact throughout download, assessment and staging.
/usr/bin/touch "$WORK/ready"
for ((i=0; i<120; i++)); do
    [[ -f "$WORK/quit-approved" ]] && break
    /bin/sleep 0.5
done
[[ -f "$WORK/quit-approved" ]]
for ((i=0; i<120; i++)); do
    ! /bin/kill -0 "$PARENT_PID" 2>/dev/null && break
    /bin/sleep 0.5
done
! /bin/kill -0 "$PARENT_PID" 2>/dev/null
! /usr/bin/pgrep -x MacVMRunner >/dev/null
/bin/mv "$TARGET" "$BACKUP_APP"
REPLACED=1
/bin/mv "$STAGING/MacVM.app" "$TARGET"
/usr/bin/open -n "$TARGET" --args --macvm-update-confirm "$WORK/started"
for ((i=0; i<60; i++)); do
    [[ -f "$WORK/started" ]] && break
    /bin/sleep 0.5
done
[[ -f "$WORK/started" ]]
# Confirmation is written after the new executable has initialized its library.
launchConfirmation=1

"""#
}
