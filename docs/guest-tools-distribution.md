# Guest Tools distribution — 11 October 2026

Guest Tools are now discoverable in Settings, the library's Virtual Machine
menu, each macOS machine's action menu, and the running macOS VM's menu. A
shared SwiftUI guide keeps installation, updating, removal, and compatibility
instructions consistent. It shows the included version, not an inferred guest
installation status. Compatibility text names macOS 27.0.1 as the live-tested
guest version for both desktop and login-screen shutdown.

The installer and an offline Read Me ship in the runner's read-only guest share.
Save Installer uses a native save panel defaulting to Downloads, exports only
the package, and does not execute it on the host. The product installer includes
welcome and completion instructions, a macOS 26/ARM64 requirement, the existing
physical-host guard, and a fixed system-volume installation destination.

## Verified

- Release configuration built and launched through `script/build_and_run.sh`.
- Developer ID Application signature on app, runner, and extracted guest payload
  verified for Team ID `66K3EFBVB6` with hardened runtime.
- 16 XCTest cases passed, including pre-login session safety policy.
- Settings → Guest Tools, a macOS machine's Guest Tools action, and the running
  VM's Virtual Machine → Guest Tools menu opened the guide. Compatibility and
  uninstall details expanded successfully.
- Save Installer opened in Downloads. Its exported package was byte-identical
  to the standalone build artifact. Only that test export was removed afterward.
- Expanded product package contained welcome/conclusion resources, correct guest
  version, LaunchAgent, and uninstaller. The guest executable refused to run on
  the physical host.
- Shell syntax, workflow YAML, and git whitespace checks passed. A release build
  with a missing Installer identity failed before writing any artifacts.
- Final optimized app rebuilt after the successful login-screen tests. Settings
  visibly shows the optional export explanation and updated macOS 27.0.1 test
  status. The DMG was regenerated and its Developer ID signature verified.
- Final 32 KB package was expanded again: its payload passed strict signature
  and publisher checks, refused execution on the physical host, and contained
  the updated installer text. Temporary extraction files were cleaned up.

## Release boundary

The local Keychain has a Developer ID Application identity but no Developer ID
Installer identity. The local product package is therefore a development
installer with a signed payload; it is not an Installer-signed/notarized public
release. The workflow now requires the separate Installer P12 secrets, exact
publisher verification, package notarization/stapling/Gatekeeper assessment
before signing the outer app, and publishes that verified package beside the
DMG. No public release was dispatched.

The new product installer was installed inside the macOS 27 test guest and its
receipt verified. The subsequent guarded pre-login fix was installed and two
restart-to-login shutdown tests passed, including pause/resume before shutdown.
Desktop shutdown with that helper also passed. See
[shutdown investigation](macos-shutdown-fix.md).

## Automatic setup reminder — 12 October 2026

Only running macOS guests are checked for the private Guest Tools connection.
Checks open and close the existing socket without sending a shutdown command,
so the already-installed helper remains compatible. Boot and login transitions
have a 45-second failure grace period; paused, restoring, and busy VM time does
not count. Linux guests are excluded.

If the connection stays unavailable, the active VM window offers Set Up Guest
Tools and Later. Set Up opens the shared installation guide. Later suppresses
automatic reminders for that VM session; a toolbar warning still opens the
guide. A successful connection clears the warning. Explicit shutdown connection
errors also offer setup instructions immediately.

Validation:

- All 21 XCTest cases passed, including five reminder-policy tests covering
  guest eligibility, the grace period, recovery, deferral, and pause behavior.
- The actual AppKit reminder was exercised with the manual preview harness:
  Set Up invoked its guide callback and Later dismissed the sheet.
- The optimized, signed build ran the macOS 27 test guest for more than two
  minutes at the login screen with the previously installed helper. No setup
  alert or warning appeared. MacVM's Shut Down button then stopped the guest;
  Runtime.json reported stopped, the runner exited, and the library showed
  zero active machines.
- The unavailable-helper timing path was checked in policy tests and the alert
  preview, without uninstalling the working helper from the test guest.
