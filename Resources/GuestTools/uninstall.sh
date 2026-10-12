#!/bin/sh
set -eu
case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) echo 'Run only inside the guest VM.' >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run this script with sudo inside the VM.' >&2; exit 1; }
guest_uid="$(/usr/bin/stat -f %u /dev/console)"
/bin/rm -f /Library/LaunchAgents/com.burakerenoglu.macvm.guest.plist
if [ "$guest_uid" -ge 500 ]; then
    /bin/launchctl bootout "gui/$guest_uid/com.burakerenoglu.macvm.guest" 2>/dev/null || true
fi
/usr/bin/pkill -x MacVMGuest 2>/dev/null || true
/bin/rm -rf '/Library/Application Support/MacVM/GuestTools/MacVM Guest.app'
/bin/rm -f '/Library/Application Support/MacVM/GuestTools/uninstall.sh'
/usr/sbin/pkgutil --forget com.burakerenoglu.macvm.guest >/dev/null
echo 'MacVM Guest Tools removed. Log out or restart to clear any remaining login-screen registration.'
