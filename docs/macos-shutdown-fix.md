# macOS shutdown repair — 11 October 2026

## Investigation

The existing `VZVirtualMachine.requestStop()` call did not complete shutdown at
macOS 27's login screen. Repeating it from the desktop exposed the guest's power
choice dialog (Shut Down / Restart / Sleep / Cancel) beneath MacVM's timeout
sheet. A successful request is not an acknowledgment of normal shutdown.

Apple documents the request-only behavior. Lima's current VZ driver similarly
uses a guest-side shutdown path for macOS. MacVM's new path uses a dedicated
virtual socket instead of enabling SSH.

## Implementation

- MacVM Guest runs only on `hw.model` values beginning with `VirtualMac`.
- It is installed under `/Library/Application Support/MacVM/GuestTools` inside
  the guest. A global LaunchAgent starts it in LoginWindow and Aqua sessions.
- Only the active session listens, on AF_VSOCK port 49201. It accepts only the
  host CID (2), one fixed, versioned shutdown command, and bounded frames.
  There is no IP listener, general shell execution, host share of personal
  files, saved credential, or remote-login setting.
- In a signed-in session, the agent asks loginwindow to perform normal shutdown
  using Apple's documented `kAEShutDown` Apple event. Open applications can cancel
  for unsaved documents. In the root-owned pre-login session, it instead invokes
  the fixed `/sbin/shutdown -h now` system command, without a shell, only after
  checking both the console owner and all login records. Existing user sessions
  (including fast user switching), unreadable accounting data, or a missing boot
  record block that path. There is no automatic VM force power-off.
- The host waits for acknowledgment, then for `guestDidStop`. It retains explicit
  Force Stop and timeout recovery. Missing tools produce installation guidance.
- A read-only share exposes only the installer package. Its preinstall script
  refuses installation on physical Macs or an alternate target volume.
- The installer requires authorization inside the VM. No helper is installed
  on the physical host.

## Checks so far

- Optimized Developer ID signed app and nested runner: pass.
- 16 XCTest cases: pass (11 existing, 5 guest-control framing/error and session
  authorization cases, including the fail-closed pre-login shutdown policy).
- Shell and plist syntax: pass.
- Extracted installer payload: guest app passes strict signature verification
  and exact Team ID `66K3EFBVB6`; running its check on the physical host refuses
  execution. The final installer is about 32 KB and contains no OS image.
- Guest installation: passed after the user entered the guest administrator
  password. Installer displayed successful completion.
- Desktop shutdown: passed. One host toolbar click received acknowledgment,
  macOS closed its session, the runner exited, and Runtime.json became stopped
  (session `0F60EF1C-92CE-42A7-B55C-CA94FF83C586`). No force stop was used.
- A second shutdown completed (session `042F455A-738D-41F2-A00C-E7FCABE9B310`),
  but the desktop appeared during the request. This is not counted as a verified
  pre-login shutdown.
- Login-screen shutdown: failed in a separate cold boot with the password field
  visibly empty. Pause and resume both passed there. Shut Down returned Guest
  Tools not connected and correctly left the VM running, rather than hanging in
  Stopping. The original installed helper predates the absent-console-user fix.
- The new product installer was installed and its receipt verified inside the
  guest (version 0.1.0, install-time 1791745693). After restarting, the empty
  password screen was tested without signing in. The absent-console-user fix
  restored the connection, but the Apple event failed with OSStatus -600.
  Guest unified logs identified `loginwindow refused shutdown` from pre-login
  MacVMGuest PID 241. The desktop path was then retested and stopped normally
  (session `85549806-4B8D-45BE-8DC9-75B382BE235D`, runner 52845).
- The guarded system shutdown package was then installed successfully. After
  restarting the guest, one host Shut Down click at the empty password screen
  completed normal shutdown: runner 59877 exited, Runtime.json became stopped
  (session `E2FD297B-8145-4423-A30A-894CA30F63BA`), and the library showed zero
  active machines. No password was entered and no Force Stop was used.
- With that same installed helper, desktop shutdown after pause/resume passed
  (runner 77548, session `8ACF332F-5933-4F6C-972F-B030EF7664A1`). The runner's
  Virtual Machine → Guest Tools guide also opened correctly.
- A second restart-to-login test passed after pausing and resuming at the empty
  password screen. Shut Down acknowledged immediately, runner 78314 exited,
  Runtime.json became stopped (session `A8BD886C-BE03-4CF6-BF1D-D952CD3D196B`),
  and the library again returned to zero active machines.
- Guest unified logs independently confirmed the guarded path on both runs:
  `Started normal pre-login system shutdown` at guest-local 12:35:25.407
  (MacVMGuest PID 240) and 12:39:45.697 (PID 245). This distinguishes the verified
  pre-login shutdowns from the separately tested signed-in Apple-event path.

These checks cover macOS 27.0.1. Fast user switching, locked signed-in sessions,
SSH sessions, and unsaved-document cancellation remain broader live-test cases;
the unit-tested policy refuses the pre-login command if login records indicate
another session or cannot be read reliably.
Cold starts also reached the desktop during this session, so they are not counted
as pre-login validation; the two confirmed pre-login runs followed guest restarts.

The user approved installing Guest Tools from the read-only guest share.
The current source also disables Installer bundle relocation so updates keep
the fixed executable path used by launchd.

The installed helper can be removed from the guest Terminal with
`sudo "/Library/Application Support/MacVM/GuestTools/uninstall.sh"`.
The installed product package contains the absent-console-user fallback,
guarded pre-login system shutdown, fixed installation path, and uninstaller.

## References

- [Apple requestStop](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/requeststop())
- [Apple QA1134: normal shutdown and application cancellation](https://developer.apple.com/library/archive/qa/qa1134/_index.html)
- [Apple TN2083: LoginWindow and Aqua agents](https://developer.apple.com/library/archive/technotes/tn2083/_index.html)
- [Lima VZ driver](https://github.com/lima-vm/lima/blob/master/pkg/driver/vz/vz_driver_darwin.go)
