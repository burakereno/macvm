# Windows completion work — 2026-10-13

User requested all five remaining areas: portable engine, new Windows creation, Tools onboarding, sound/clipboard/folders, release validation.

## Implementation so far

- Portable bundler stages QEMU, qemu-img, swtpm and swtpm_setup plus 31 libraries, rewrites all external dylibs to loader-relative paths, signs each, and records dependencies/source metadata. Hypervisor entitlement remains; library-validation bypass was removed.
- Main creation wizard supports Windows 11 ARM64 local ISO or Microsoft CDN ISO link downloaded to Downloads; optional SHA-256, PE ARM64 media validation, APFS ISO clone with capacity-checked copy fallback, standalone QCOW2, independently manufactured TPM with Microsoft Secure Boot firmware.
- Windows Tools CD preparation includes matching GPU, network and serial drivers plus source-built ARM64 VDAgent and SPICE WebDAV. Visual C++ is downloaded from Microsoft by the guest only when missing, with signature verification and visible licence installer. It is not redistributed in the ISO. The new source-built payload is still awaiting CI and live acceptance.
- Clipboard integration is opt-in, text only, active-window and active host session only; resets baseline around host sleep/lock. Folder WebDAV uses a private virtio-serial channel, selected folders only, read-only default. All file operations use directory FDs/openat with no-follow checks; no host TCP listener.
- Windows Settings now expose sound output, sharing and installer ejection; runtime Tools status and unavailable reminder added.

## Tests so far

- Portable binaries launched with only system PATH; TPM manufacture passed independently. Fresh VM cold boot found a missing QEMU keymaps resource; bundler was corrected and runtime preflight now requires en-us.
- Four new sharing/media-link tests passed after correcting macOS descriptor-relative file operations. Covers fragmented/oversized clipboard frames, HTTP framing/smuggling bounds, read/write, read-only mutation refusal, traversal/symlink refusal and Microsoft URL allowlist.
- Initial Developer ID development app builds and deep signature verification passed. Full unit suites passed: 57 MacVMCore and 22 Windows tests. Real guest integration and release notarization remain outstanding.
- Official Windows ISO downloaded to Downloads and confirmed SHA-256 8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c, the same official English ARM64 26300.9457 media used in the earlier installation. Microsoft's page still has the documented language/checksum-table discrepancy; no English table-row match is claimed.
- Fresh wizard created Windows 11 ARM Installation Test at ~/Library/Application Support/MacVM/Virtual Machines/8C45ADF3-1200-4AD0-B9CF-028BB7011607.macvm. First boot failed safely on missing keymaps. After including keymaps, the new VM booted Windows Setup. Actual QEMU/TPM vmmap checks showed no /opt/homebrew or /usr/local library mappings. Existing Windows VM remains untouched and stopped.

## Outstanding acceptance

- Boot the new VM from the updated package and complete fresh Windows Setup/OOBE, Tools installation, disk-only boot, sound, clipboard both directions, read-only/read-write folders and resize/fullscreen/lifecycle.
- Use CUA for guest input. Password entry is a required user handoff; licences/new administrator access need confirmation at action time under the computer-use policy.
- Complete distribution pipeline bootstrap for fresh CI (Homebrew build deps + official Secure Boot firmware); dependency/source/licence audit; full tests, updater audits, signed/notarized app+DMG and update manifest.
- Remove only owned installers/Downloads extraction, disposable test artifacts and assertions after acceptance.

## Subsequent acceptance work

- The Microsoft licence for the new test VM was accepted only after the user confirmed at the actual licence screen. Windows 11 Pro is installing on its new 128 GB disk. No hardware checks, UAC or activation protections were bypassed.
- Added a reproducible firmware bootstrap using pinned upstream commits and hashes. It reproduces the exact previously validated Secure Boot code/variable images without downloading the entire UTM app. CI now requires the Windows engine and Tools payload.
- Collected exact archives, installed Homebrew recipes/patches and notices for 28 engine components. Metadata records the actually linked installed version, rather than current formula metadata. Public build receipts exclude personal cache paths. Source archive is a release asset. Guest Tools source/notice audit is still outstanding.
- Added a portable engine release verifier: 35 files passed hashes, Team 66K3EFBVB6 signatures, hardened runtime and loader-relative linkage; qemu-img disk creation and independently manufactured TPM passed with system-only PATH.
- Windows download redirects are rejected before contacting hosts outside the Microsoft allowlist. Added response-origin tests; focused download and sharing tests passed.
- Physical-key mapping fixes Turkish host characters that previously lost i/punctuation. The running app includes this fix. Turkish Q was selected in Windows OOBE and the test account name entered correctly; punctuation and desktop text entry still need live checks.
- Clipboard remembers new host copies locally while the VM is inactive, sends only after it is foreground, and never uploads pre-launch clipboard contents. Message chunks cannot interleave. WebDAV reads are bounded to the advertised file length. These last changes still require live guest checks.

## Fresh installation and subsequent checks

- Windows 11 Pro installation completed on the new disk and reached OOBE. Normal toolbar shutdown at OOBE passed; the guest was restarted after rebuilding the app. The Tools CD's ARM64 network driver installed through Windows' supported Install Driver UI, and OOBE confirmed Network Connected.
- User approved the Microsoft Windows licence at action time. Setup uses Windows Pro's normal work/school → sign-in options → Domain join instead local-account flow. No fake account, hardware bypass or network bypass was used. The user completed password/confirmation/recovery entry. Privacy preferences completed; optional OOBE updates were deferred through Windows' supported Update later action. The new macvmtest desktop opened successfully on 2026-10-14.
- Full updated tests passed: 58 MacVMCore and 24 Windows tests. WebDAV write locks now enforce ownership, expire on a monotonic clock, renew/unlock with valid tokens, normalize encoded paths, protect locked descendants during delete/move, reject unsafe/unsupported lock XML, and report lock discovery. Negative writes left actual files intact.
- Added explicit host lock/unlock notifications alongside independent session and sleep states. Display wake cannot clear the lock state. Source compiles; a live host-lock clipboard test is still required.
- Old ready-made guest-helper binaries lacked complete build provenance. A Windows ARM64 GitHub job now builds pinned upstream VDAgent/VDService and WebDAV against pinned vcpkg sources, producing matching source archives, build recipes, notices and binary hashes. First source build is running at https://github.com/burakereno/macvm/actions/runs/38447211201 (commit 48ea1b1 on codex/windows-completion). It has not yet passed, and the new outputs are not yet installed in the VM.
- Packaging now requires verified ARM64 guest-helper outputs for required-Windows builds. The Windows Tools installer supports the source-built WebDAV service directly. These latest packaging changes are local, syntactically checked, and await the source build, app rebuild and fresh Tools acceptance. No new public release has been published.
- The first helper build reached its 60-minute job timeout while building dependencies, without reaching helper compilation. The replacement job cross-compiles ARM64 on a native x64 Windows runner, builds Release dependencies only and caches source downloads/binaries outside the repository clone. A SPICE MSVC ARM64 detection patch, current libpng CMake target patch and current GLib Windows include directory were required; patches/build recipes ship with original sources. Source build passed at https://github.com/burakereno/macvm/actions/runs/38530424113, commit da8500e. Artifact download and local payload verification are pending.
- Fresh Windows recognized Speakers / High Definition Audio Device as the default output without additional drivers. The Windows stereo speaker test ran; the user confirmed hearing both test sounds on the Mac. Audio output acceptance passed.
- Tools preparation now stages helper cache copies before replacement and commits a receipt last. Required-Windows builds verify that the Tools ISO hash and helper build receipt match; interrupted cache preparation fails preflight.
- The fresh Windows disk consumed about 27 GB after first-boot setup/initial update download. Windows creation now requires 40 GiB (about 43 GB), plus download/non-APFS ISO-copy space, to retain installation/update headroom. QEMU storage-error pauses now have an explicit paused error message rather than appearing as ordinary user pauses; the storage-error branch is not fault-injected against a guest.
- Completed Ubuntu 24.04.3/26.04.1 installer ISO copies were removed through Installation Files; VM disks remained intact. The Trash contained only those two ISO files and was emptied, recovering about 7 GB. Windows source/VM ISO files remain until disk-only boot acceptance. Current free space is about 9 GiB.
- Physical letters and basic punctuation passed in the fresh guest; synthetic modifier chords exposed lost modifier state. Input now synchronizes current event flags while preserving left/right Alt (AltGr), Ctrl, Shift and Command. The modifier regression test passed through the native XCTest runner. Latest checks: 58 MacVMCore tests and 25 Windows tests passed. Live modifier checks await the updated app.
