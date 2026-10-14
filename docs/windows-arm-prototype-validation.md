# Windows 11 ARM prototype validation

Dates: 2026-10-12–13. Historical record of the separate local prototype. The subsequent [main-library integration](windows-integration-validation.md) supersedes its UI and lifecycle status; installation evidence below is retained.

## Prototype

- App: `dist/MacVM Windows Prototype.app`.
- Swift controller: `Sources/MacVMWindowsPrototype/PrototypeApp.swift`.
- Native display: signed nested `Windows Display.app`, using QEMU Cocoa.
- Local engine dependencies: Homebrew QEMU 11.1.2 and swtpm 0.10.2.
- Firmware: EDK2 ARM Secure Boot code and variable template from UTM 4.7.5's official release. Required code and licence remain in `~/Library/Application Support/MacVM/Engines/Windows Prototype`.
- VM: `~/Library/Application Support/MacVM/Windows Prototypes/Windows 11 ARM`, separate from existing user VMs.
- Resources: 4 vCPU, 8 GiB RAM, sparse 128 GiB qcow2 disk, NVMe, virtio-net, USB keyboard/tablet, RAM framebuffer plus VirtIO display, TPM 2.0.
- Management: private Unix QMP and swtpm sockets; kernel disk lock; installer image leases shared with MacVM's cleanup UI.
- Both prototype apps are locally Developer ID signed. This is not a newly notarized distributable release. The QEMU display uses Homebrew dylibs and permits their loading; production dependency bundling remains separate work.

## Installation media and verification

- ISO was generated from Microsoft's official Windows 11 ARM64 download page, choosing English (United States), and downloaded from `software.download.prss.microsoft.com` into Downloads.
- File: `MacVM-Windows11-ARM64-26300.9457-en-US.iso`, 8,528,523,264 bytes.
- Actual SHA256: `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c`.
- Microsoft's page labels this exact digest as Arabic, while its English row lists `dbf606...`. The downloaded volume label, `sources/lang.ini`, and WIM metadata all identify English (United States), ARM64, build 26300.9457. This is a source-table discrepancy; do not claim the English-row checksum matched.
- The full install WIM passed `wimlib-imagex verify` (all resource SHA1 integrity checks). This verifies internal integrity, not a separate vendor signature for every file.
- `setup.exe` Authenticode signature and timestamp passed osslsigncode verification using Microsoft Root CA 2010 fetched over HTTPS from Microsoft's certificate site. Log: `.build/windows-setup-signature.log`.
- Driver source: official utmapp/qemu release `v10.0.12-utm`, guest tools 0.1.273.
- NetKVM and viogpudo ARM64 driver catalogs both passed Microsoft Hardware Compatibility Publisher signature verification against Microsoft Root CA 2010. Windows subsequently accepted both drivers without a signature warning.
- Original guest tools media contains an Autounattend.xml that disables UAC and bypasses hardware checks. It is NOT attached to the prototype. A small driver-only ISO was built in Downloads containing ARM64 Windows 11 drivers and their licence, without that answer file.

## Completed checks

- 7 focused tests: hardware/resource/path validation and QMP fragmented greetings, events interleaved with replies, command errors, disconnect and response IDs.
- 57 existing core tests passed.
- Real native QEMU/HVF integration: 2 vCPUs, TPM2 enumeration, QMP run/pause/resume and clean engine quit passed on a disposable private disk. This is an engine lifecycle check, not a completed Windows installation/shutdown test.
- Installer devices use explicit USB BOT + SCSI CD-ROM, not an ambiguously typed USB storage disk. A real `query-block` check verified removable CD media and closed tray.
- Native controller Start/Force Stop was exercised for the empty firmware boot probe. Force stop is explicit and displays a warning.
- Source and prototype packaging checks passed before the installation pass.

## Issues resolved during preparation

- ARM TPM PPI RAM is not aligned to this Mac's 16 KiB HVF host page. QEMU 11.1.2 fails `hv_vm_unmap` with `HV_BAD_ARGUMENT` when PPI is enabled. The prototype uses `tpm-tis-device,ppi=off`; TPM2 remains enabled. Physical Presence operations are a prototype limitation.
- UTM's EFI variable template uses qcow2 storage despite its `.fd` suffix. It was edited to enroll Microsoft certificates, then explicitly converted to raw for the prototype's pflash device.
- Host ISO inspection mount initially held a QEMU-incompatible file lock. The inspection mount was detached rather than disabling disk locking.
- A native `.app` wrapper is required to expose QEMU's Cocoa window to macOS application tooling. Its resource directory is explicitly provided with `-L`; the network option ROM is disabled because this prototype does not use PXE boot.

## Installation pass

- 2026-10-12: host unlocked; owned two-hour caffeinate assertion prevents display/idle sleep during the active test.
- Windows Setup booted successfully from the English ARM64 ISO. Selected Windows 11 Pro without entering a product key.
- Accepted Microsoft software licence terms after the user's action-time confirmation. Setup reached disk selection without any TPM, CPU, RAM or Secure Boot bypass.
- Native QEMU View > Enter Fullscreen toggled into full screen and back; window controls disappeared/reappeared. QEMU's menu label stays “Enter Fullscreen” in both modes, a prototype UI limitation to fix in the main-app integration.
- Disk installation completed its first phase, automatically restarted and booted the installed Windows kernel into system preparation/OOBE. The installer ISO was attached during installation; both installation discs were subsequently detached in the controller after a normal guest shutdown. Disk-only boot and subsequent desktop sign-in passed on October 13.
- OOBE initially had no network driver. Its official Install driver flow loaded `E:\Drivers\NetKVM` from the driver-only ISO without a signature warning; network changed to Connected and Next became enabled. No OOBE/network requirement bypass was used.
- OOBE updated/restarted successfully, named the device `macvmwin11`, and used the built-in Pro Work or school > Sign-in options > Domain join instead path to create the local test account `macvmtest`. No external domain or Microsoft account was joined. The user completed password and recovery questions; the VM reached privacy settings. Native coordinate actions subsequently returned noWindowsAvailable despite a readable image/AX tree. Resetting the CUA session did not repair coordinate input, but targeted keyboard input worked and continued setup. Privacy was completed with optional sharing disabled and required diagnostic data only.
- CUA rapid typing drops/reorders synthetic key strokes in the native QEMU display (UEFI and Windows). Per-key `pressKey` with 250 ms holds plus a state observation between keys correctly entered `macvmwin11`. Physical keyboard input must also be confirmed by the user at the password handoff. Mouse input works after the first click captures the pointer; Ctrl–Option–G releases capture.

## Windows desktop acceptance (2026-10-13)

- Local account and OOBE completed; Windows 11 Pro build 26300.9457 reached the desktop as `macvmtest`.
- Network driver installed through OOBE; online system preparation and Windows updates ran successfully.
- `msinfo32` confirms ARM64-based PC, 4 cores / 4 logical processors, 8 GiB RAM, BIOS Mode UEFI and Secure Boot State On.
- Device Manager's Add drivers wizard successfully imported all seven ARM64 driver packages from `E:\Drivers`. The display package `viogpudo.inf` attached to one device; the network driver was already installed. The other packages were staged but matched no devices in this configuration.
- Display adapters now lists Red Hat VirtIO GPU DOD controller, with status “This device is working properly”. Installing it moves Windows output from the `ramfb` console to `gpu`; View > gpu was selected for the initial driver session. The desktop initially appeared at 1024×768. Windows Settings > System > Display was changed to 2560×1600 with native 200% scaling, visibly verified together. The Cocoa window then displayed a 2560×1600 framebuffer (about 1280×800 macOS points), without stretching a low-resolution image. The prototype now advertises 2560×1600 as its preferred VirtIO mode. Full-screen entry/exit and controller pause/resume were exercised on the installed desktop.
- Other devices still has unknown ACPI devices (Code 28). The inspected instance is `ACPI\LNRO0005\0`. QEMU exposes 32 empty VirtIO MMIO transports by default. The prototype uses PCI VirtIO devices, so the configuration now sets `virtio-mmio-transports=0`, supported by the installed QEMU 11.1.2. This follows the [upstream QEMU change](https://github.com/qemu/qemu/commit/ee4d1ff3af85418a1dd946647658b954649e43ae). After rebuilding and confirming this option in the running engine arguments, Device Manager still showed multiple unknown devices; the inspected instance remained `ACPI\LNRO0005\0`, Code 28. This attempt did not resolve the warnings. Firmware enumeration and Windows retained device state need further investigation.
- `tpmtool getdeviceinformation` in Windows reports TPM Present True, version 2.0, Initialized True, Ready For Storage True, PCR7 Binding Possible, not locked out and no recovery clear needed.
- Remote attestation is NOT ready/capable: the software TPM has no endorsement-key certificate. PPI remains disabled for the documented HVF page-alignment issue. Do not describe this as full physical-TPM/attestation support.
- Native input automation sometimes needs an explicit drag/motion before clicking because the guest pointer otherwise stays at its previous location; slow per-key input works after focusing the guest text control. These are automation observations, not proof that physical user input is defective.
- The user approved an administrator Windows Command Processor for driver installation and TPM/Secure Boot diagnostics. The first UAC prompt expired before acceptance; an ordinary user terminal was subsequently used for read-only diagnostics.
- After ISO-free cold boot and user sign-in, Settings > System > Display still explicitly showed 2560×1600 resolution and 200% scaling. No display-setting change was needed after restart.

## Lifecycle results (2026-10-13)

- Windows Start > Power > Restart displayed Restarting, rebooted and returned to the lock/login screen with 2560×1600 output. The same QEMU engine remained alive through guest reboot.
- The Windows login screen's Power > Shut down completed normally. The controller changed to Stopped, and both owned QEMU and swtpm processes exited. No force stop was used for this test.
- Windows desktop Start > Power > Shut down also completed normally after the final Settings/Device Manager inspection. The controller reported Stopped / Windows is shut down.
- The controller's QMP `system_powerdown` request did **not** shut down the locked Windows session. After 45 seconds it correctly displayed its timeout guidance, but remained Stopping until Windows was shut down through its own power menu. Host-requested graceful shutdown is an unresolved prototype limitation, not a passing acceptance check.
- With Windows stopped, Detach Installation Media cleared both installer and driver ISO paths in Prototype.json. The app was rebuilt and locally signed with the unused MMIO transport fix and preferred 2560×1600 mode; strict deep code-sign verification passed.
- The final build places the VirtIO GPU console first when no installer is attached, while retaining RAMFB in View for firmware/recovery. With an installer, RAMFB remains first for Windows Setup. A fresh engine start without either ISO displayed the 2560×1600 Windows lock/login screen automatically, without manually selecting View > gpu.
- The final disk-only start was followed by another normal login-screen shutdown. Controller status returned to Stopped, with no owned QEMU or swtpm process left. Final build/signature checks and `git diff --check` passed; the 7 focused tests passed after the final source change.

## Remaining prototype limitations

- Unknown ACPI devices remain visible in Device Manager; this is not a clean driver acceptance result.
- A reliable host-requested graceful shutdown path is still needed. Windows' own desktop and login-screen shutdown paths both work.
- Audio, accelerated 3D, Windows clipboard/folder sharing, portable dependency packaging and integration into the main MacVM library are not implemented by this prototype.


Windows installation, first sign-in, native display scaling, restart and guest-controlled shutdown are complete. Host-controlled shutdown and remaining ACPI driver warnings prevent treating this prototype as production-ready. The computer-use tool explicitly reported a locked host during earlier post-driver checks on October 13; testing resumed after the user unlocked it, without an unlock or login workaround.

## Cleanup completed during preparation

- Detached the owned host inspection mounts.
- Deleted the downloaded UTM firmware DMG, original 140 MB guest tools ISO and temporary driver extraction folder after the required firmware and signed ARM64 drivers were retained.
- Deleted the completed range-download parts, temporary URL manifest and temporary EFI inspection file.
- Stopped the owned firmware-only QEMU/TPM probe and the temporary caffeinate assertion.
- On October 13, the rebuilt configuration cold-booted from the installed disk to the Windows login screen at 2560×1600. Both ISO paths were absent from the saved configuration and the running QEMU arguments; no CD device was attached.
- After that successful disk-only boot, checked both owned ISO files had no open handles and removed them from Downloads: Windows ISO 8,528,523,264 bytes and driver ISO 3,956,736 bytes (8,532,480,000 bytes total).
- Post-cleanup host free space: 41.41 GiB (about 44.46 GB). The retained Windows qcow2 disk uses 16.58 GiB physically out of its 128 GiB virtual capacity.
- Final post-test free space: 44.33 GB; retained disk allocation: 16.59 GiB. The final owned test caffeinate assertion was stopped.
- Free space after preparation: approximately 52 GiB. Existing user VMs were not modified or started.
