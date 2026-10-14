# Windows library integration — 2026-10-13

The installed Windows 11 ARM test machine is integrated into MacVM’s main library and native runner window. Automatic framebuffer resizing, fullscreen entry/exit and 200% Windows scaling passed live validation at 18:19–18:23 TRT. This is a local development build, not a portable Windows release. Earlier timed diagnosis notes below describe intermediate failures; the final acceptance section records the completed outcome.

## Implemented

- Windows records, package validation and QCOW2 physical disk accounting in the existing library/settings.
- Transactional migration with rollback and active-disk protection. The existing disk, EFI variables, network address and TPM state were moved on the same volume, without copying the disk or reinstalling Windows. Missing permanent TPM state is rejected instead of silently generating a different identity.
- MacVMRunner dispatches to the Windows engine for Windows records. Executable and firmware paths come from the app, never an imported VM package.
- Native AppKit VM window and Windows Dock artwork. The main library keeps its own icon.
- QEMU frames and input over a private Unix RFB socket in a mode-0700 runtime directory. No display TCP listener, shared clipboard, or file transfer. No separate QEMU display window.
- Native pause/resume and shutdown toolbar, full-screen entry/exit with Control–Command–F, close/keep-running and library reopen.
- Shutdown timeout returns to the actual Running/Paused state and offers explicit recovery. No automatic force stop.
- Development packaging includes the signed engine, firmware, QEMU and EDK2 licences. The old prototype build has been moved out of dist into .build/legacy-windows-prototype.

## Checks completed

- 73 unit tests passed: 16 Windows tests and 57 existing core tests. New coverage includes private display arguments, disconnected networking, framebuffer bounds, TPM preservation, active migration rejection and rollback.
- Developer ID build succeeded through script/build_and_run.sh --verify; strict deep code-sign verification passed.
- The real installed VM starts from the main library without installation media and displays its 2560×1600 Windows login screen in MacVM’s window.
- Toolbar pause changed both window and library state; resume continued the guest.
- Control–Command–F entered full screen and the same shortcut exited. Toolbar labels changed between Enter/Exit Full Screen.
- Window close → Keep Running preserved the engine. Main library → Open brought the same window/guest back.
- Pointer clicks and keyboard Return input reached the guest. Windows login-screen Power → Restart completed and returned to the lock screen.
- After that full guest restart, MacVM’s toolbar Shut Down successfully shut Windows down from the login screen. Runtime.json changed to stopped, the main library showed 0 active, and the owned QEMU/swtpm processes exited. This uses QMP system_powerdown; no force stop or guest agent was needed.
- The earlier ACPI/shutdown failure may have involved retained Windows state. Full restart changed the observed result, but this is not proof of the root cause.
- Owned Windows installer and driver ISO files are absent from Downloads. No new installer was downloaded for this integration. Host free space at this check: 42.84 GB.

## Display acceptance

- Signed-in desktop and Device Manager inspection passed: Red Hat VirtIO GPU DOD is active and the earlier Other devices/unknown ACPI entries are absent after the full guest restart.
- Command-key release fix passed in the packaged runner: Win+E opened one Explorer window without repeated input.
- Automatic display resolution implementation is compiled and covered by a real Unix-socket RFB handshake test, including capability negotiation, exact SetDesktopSize bytes, asynchronous/forwarded replies, screen payload consumption, changed framebuffer bounds and duplicate suppression. The view requests backing pixels after a 350 ms resize debounce and after fullscreen transitions; matched pixels render without interpolation.
- Physical Windows validation passed at 18:19–18:23 TRT after the matching-driver and fallback correction below. Both native framebuffer diagnostics and Windows Display Settings confirmed actual resolution changes; fullscreen entry alone was not used as evidence.
- Added Virtual Machine → Install Display Tools… to mount app-owned, read-only helper media. It contains ARM64 viogpuap/vgpusrv from the official UTM 0.1.273 package (viogpudo/2k25/ARM64). Windows installation checks pinned SHA-256 and Authenticode before installing the automatic resolution service. The helper was installed in the test guest at 16:43 TRT; automatic resolution still required a matching driver (see follow-up below).
- Source and payload preparation: scripts/prepare-windows-display-tools.sh downloads into Downloads, checks the helper hashes, builds a small runtime ISO in Application Support and removes the downloaded installer. The app bundles this payload when present. Resources/WindowsDisplayTools contains installation, removal and licence text.
- A second host-requested shutdown after cold boot passed, including a signed-in desktop.

## Remaining scope

Windows engine dependencies still use local Homebrew QEMU/swtpm. New Windows ISO installation in the creation wizard, portable dependency packaging, independent TPM-aware duplication, audio, accelerated 3D and Windows clipboard/folder sharing are not implemented. Firmware/recovery uses a secondary RAMFB console; switching consoles is not yet exposed in the native window. Existing macOS/Linux creation and runtime remain on Apple Virtualization.

References: [RFB protocol](https://www.rfc-editor.org/rfc/rfc6143), [QEMU ARM ACPI implementation](https://github.com/qemu/qemu/blob/master/hw/arm/virt-acpi-build.c).

## Display resize references

- [RFB SetDesktopSize / ExtendedDesktopSize](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst)
- [VirtIO GPU maintainer instructions for the resolution helper](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1391)
- [Official helper binary source release](https://github.com/utmapp/qemu/releases/tag/v10.0.12-utm)

### Follow-up, 16:16 TRT

- A second cold-boot session shut down from the host toolbar normally, including a signed-in desktop.
- New runner and helper ISO built, Developer ID signature verified, main library launch passed.
- Win+E opened one Explorer window without the earlier stuck/repeating Command key.
- Found a live-media enumeration race: attaching usb-bot before its scsi-cd LUN makes Windows enumerate an empty bridge. The bridge is now created detached, populated with its CD, then attached via QOM. Live guest inspection passed: Explorer shows CD Drive (D:) MacVM Tools and all five installer payload files.
- At 16:42 TRT, the helper installer is at Windows UAC, awaiting action-time user approval to install the automatic resolution service. The helper has not yet been installed, and dynamic resolution is not yet verified.

### Display driver diagnosis, 17:20 TRT

- Helper SHA-256 and Authenticode passed; vgpusrv installed and started, and viogpuap started in the signed-in session after a cold boot.
- The installed 22.7.38.43 display driver came from the UTM fork (w11/ARM64). The helper from 2k25/ARM64 uses the upstream VirtIO resolution-event protocol. Its guest log (vgpusvp.log) reported `Cannot open event Global\VioGpuResolutionEvent0 Error = 2`.
- Native runner diagnostics confirmed physical viewport requests of 2560×1664 and 3456×2064 reached QEMU. ExtendedDesktopSize status 4 reported forwarding, while the guest remained 2560×1600. Thus window/fullscreen geometry alone was not the blocker.
- Prepared matching 100.100.104.27100 ARM64 driver from the same official UTM 0.1.273 payload. Catalog Authenticode passed as Microsoft Windows Hardware Compatibility Publisher. Original oem4.inf exported in the guest; replacement staged as oem9.inf. The first preparation stopped safely on an incorrect service name (the actual name is VioGpuDod), before disabling anything.
- Driver replacement and dynamic-resolution acceptance are still in progress. No successful resize is claimed yet.

### Matching driver installed; acceptance still pending

- The test guest now reports Red Hat VirtIO GPU DOD 100.100.104.27100 with ConfigManagerErrorCode 0. The first new framebuffer matched the window at 2560×1664; a subsequent fullscreen request did not yet change that framebuffer. This is not a passing fullscreen test.
- The old driver's VioGpuDod service was disabled before a full Windows Restart and removed only when stopped. PnPUtil's reboot-required result must be accepted as 3010, not treated as failure. A pre-migration APFS clone remains at `.build/windows-display-backup-20261013` until display acceptance succeeds.
- New driver activation exposed two Windows displays: RAMFB 800×600 still owned the login screen, while VirtIO GPU had the 2560×1664 secondary screen. An experiment removed RAMFB after installer detachment, but the Basic Display adapter still owned the login screen and the GPU stayed black. This change was reverted; the current app retains the recovery RAMFB console.
- 16 Windows unit tests passed during the experiment and again after restoring the two-console configuration at 18:17 TRT. Shell syntax and diff whitespace checks passed.
- Display Tools payload preparation now includes the matching INF/SYS/catalog and both helpers. All five pinned hashes passed. The full downloaded UTM ISO was removed from Downloads after preparation. The revised installer exports the known legacy driver and requires a real Restart before removal, verifies matching version and running service, and accepts PnPUtil 3010. The revised installer itself still needs a live Windows run; do not publish it as validated.
- Windows was restarted again with the matching driver. Signed-in acceptance is waiting on the user's login, requested in the conversation. Next: inspect helper logs, validate a single active display, fullscreen/window resize and 200% scaling; then remove owned repair files/clone after success.
- ARM64 duplicate boot-display reference: https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1102 (see osy's December 5, 2024 comment).

### Duplicate fallback correction, 18:18 TRT

- The ARM64 Basic Display fallback remained adapter zero. The upstream helper stopped enumeration before reaching the VirtIO adapter. UTM's own installer sets `DisableBasicDisplayFallback=1`; MacVM's installer now applies this only after matching driver/PnP health and running service checks. Its Read Me describes restoring the fallback before manual driver removal.
- After the RAMFB experiment, only the test guest's EFI variable file was restored from the pre-test clone while the guest was stopped. Windows disk and TPM were preserved. Normal ACPI shutdown continued to work. The experimental EFI file remains as `.build/windows-display-efi-before-restore.fd` pending acceptance.
- Live installer testing found and fixed three repeat-install issues: PowerShell singleton CIM results needed explicit array wrapping; PnPUtil returned 259 when the matching driver was already current (now skipped); the per-user helper outlived its service and held its EXE open (the installer now stops only its own path and avoids copying identical files).
- At 18:16 TRT, the revised script completed in the actual guest: all payload hashes/signatures passed, matching driver and running service verified, fallback setting applied. Windows Restart returned to the login screen on the VirtIO GPU at 2560×1664. Before this correction the login screen was on RAMFB at 800×600.
- The same corrected script and recovery instructions were rebuilt into the cached DisplayTools ISO. The currently running app still contains the previous ISO until the next app build; the test used the corrected local script with its original read-only CD payloads.
- Signed-in dynamic resize/fullscreen and 200% acceptance subsequently passed; see the final acceptance below.

### Display acceptance passed, 18:19–18:29 TRT

- With the matching driver and fallback correction, the signed-in guest exposed one active display. Fullscreen changed the actual framebuffer to **3456×2064**; leaving fullscreen restored **2560×1664**.
- Runner diagnostics recorded request 3456×2064 at 18:19:30.298 and actual ExtendedDesktopSize layout 3456×2064, reason 0/status 0, at 18:19:30.326. The return to 2560×1664 was acknowledged at 18:19:45.024. Evidence: `.build/windows-display-success.log`.
- Windows Settings → System → Display was set to **200% scale**. A second fullscreen cycle kept 200% while Windows itself reported 3456×2064; windowed mode reported 2560×1664. Text and icons remained readable and the desktop filled the viewport without the previous black borders/stretching.
- Free window resizing also worked: native framebuffer and Windows Settings agreed on **2214×1476**. Control–Command–F and the toolbar Exit Full Screen action both passed.
- The matching-driver repeat-install path completed successfully in the guest. The scripted two-restart migration from the old driver remains separately unverified end to end; the test guest's original driver migration was performed during diagnosis.
- The five owned temporary repair/download items were moved to the Windows Recycle Bin; Explorer then showed Downloads empty. Installed runtime drivers/helpers remain in place.

### Final packaging and cleanup, 18:30 TRT

- Host toolbar Shut Down stopped Windows normally again. Runtime state became `stopped` and both runner and engine processes exited; no force stop was used.
- Rebuilt using Developer ID via `script/build_and_run.sh --verify`. Strict deep code-sign verification passed and the rebuilt MacVM opened with five machines and zero active.
- Bundled `DisplayTools.iso` matches the corrected cache (SHA-256 `56d2521c95705f98e1c3a850c3ad665aa23af877460af0d83b37397e1e9a283e`). A read-only mount confirmed Install.cmd, Install.ps1, Read Me.txt and LICENSE.txt byte-for-byte against their sources.
- Removed the owned host Downloads repair folder, stopped its localhost HTTP server and temporary caffeinate process, and removed the disposable APFS backup clone and experimental EFI copy after successful shutdown/build. The live VM disk, EFI and TPM remain intact. No owned display-tools installer ISO is left in Downloads.
- Sixteen Windows unit tests passed in the final code configuration; `git diff --check` passed after documentation updates. No public release/notarization was performed in this display-fix pass.
