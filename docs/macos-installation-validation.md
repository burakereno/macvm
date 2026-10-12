# macOS installation validation — 11 October 2026

Status: **full restore, Setup Assistant, desktop, HTTPS networking, pause/resume,
guest restart, guest-initiated shutdown, and cold boot passed with the lifecycle
fix**. MacVM's shutdown request was ignored at the macOS login screen; the
30-second recovery worked, and the guest's own power menu shut it down normally.

- Host: Apple silicon, macOS 27.0.1 (26A434), 14 CPU cores, 24 GB memory.
- Apple's `VZMacOSRestoreImage.latestSupported` resolved macOS 27.0.1,
  build 26A434, on this host.
- Official source: `https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw`.
- Expected size: 26,637,307,067 bytes.
- Apple's HTTPS response header `x-amz-meta-digest-sha256`:
  `2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1`.
- The user requested Downloads for test installers and deletion after use.
  The download was `~/Downloads/MacVM-test-macOS-27.0.1-26A434.ipsw`
  (a `.download` suffix is used until complete). No IPSW is stored in the project.
- The app's Local IPSW flow used that file directly. This run does not
  exercise the creation wizard's automatic download/cache path.
- Tested guest: 4 CPUs, 8 GiB memory, 64 GiB sparse disk, NAT.
- Initial host space: approximately 122.6 GB free (decimal), above the app's
  90 GiB threshold for download plus installation.

## Completed preparation

- Download completed: 26,637,307,067 bytes in 2,388.2 seconds.
- The full SHA-256 matches Apple's HTTPS metadata exactly.
- `VZMacOSRestoreImage.image(from:)` loaded the local IPSW successfully; its
  supported hardware model is valid on this host. Minimum requirements are
  2 CPUs and 4 GiB RAM. The proposed 4 CPU / 8 GiB configuration exceeds them.
- All existing VMs are stopped. The MacVM creation form is set to Local IPSW,
  4 CPUs, 8 GiB memory, and a 64 GiB disk. After the user unlocked the host,
  the IPSW was selected and Create & Start successfully launched installation
  around 20:22 Europe/Istanbul. The package ID is
  `9276A6DF-8CBB-4F6B-A59E-F504BF8A0FFD`; its restore path points to Downloads.
- Host free space after download is approximately 91 GB (85 GiB), above the
  local-image installation threshold of 64 GiB.
- The current app was packaged into a Developer ID signed DMG and passed
  strict signature and publisher checks. Notarization/publication remain
  pending; release readiness still reports a missing GitHub remote.

## Post-install state regression

The first restore completed at approximately 20:26:27. The configuration was
saved with `installationPending = false` and the restore-image reference was
cleared. The installer had already left the virtual machine in `.running`.
The runner then unconditionally called `start`, producing
`Invalid virtual machine state transition. Transition from state “running” to
state “running” is invalid.` This was a runner lifecycle error after successful
restoration, not an IPSW download or compatibility failure.

The first fix made `RunnerDelegate.start()` adopt an already-running guest and
check `canStart` before issuing a start command. It removed the invalid
transition, but the repeat exposed an additional lifecycle detail: the restore
guest shuts down after installation. At 20:36:12 the runner consequently exited
with Stopped, before booting Setup Assistant. No installation error was reported.

The final fix explicitly ends the restore guest after successful installation,
awaits `stop()` (unless already stopped), and then starts the installed system.
The installer stays retained until that shutdown completes, preventing its
`guestDidStop` callback from terminating the runner. If the guest stops on its
own during the stop request, its stopped state is accepted. The start-state
guards remain as defense against another invalid start. The optimized Developer
ID signed build passed. All 11 existing XCTest cases passed during this fix;
these cover existing core behavior, while the real restore is the lifecycle
regression test.

The first test package had no account or user data. Its config/runtime evidence
was preserved in `.build/macos-first-restore-failure/`, and only that disposable
package was removed to free space for a clean repeat. The native Local IPSW
creation flow was repeated with the same verified Downloads image, 4 CPUs,
8 GiB RAM, and a fresh 64 GiB disk. Installation started around 20:31:57 in
package `2BF04ADF-45DF-4B6F-AB48-190085E22189`. Free space before creation was
86.07 GB. Progress/space measurements are recorded in
`.build/macos-install-retest-monitor.jsonl`.

The account-free second test package was also removed after preserving its
config/runtime evidence in `.build/macos-second-restore-result/`. At 20:38:55,
the same native flow and hardware settings created the final regression-test
package `AC45D1FF-55E7-491C-89C3-F51D18CE722A`. Its monitor samples once per second
in `.build/macos-install-final-monitor.jsonl` to capture the completion transition.

## Successful final restore and cleanup

- The final run transitioned from Installing to Starting at 20:42:34, then
  Running at 20:42:35, without an error or runner exit. The same runner process
  (88186) booted the installed disk into the macOS welcome screen and language
  selection in Setup Assistant. The prior running-to-running exception and
  premature helper exit did not recur.
- The persisted config has `installationPending = false` and no
  `restoreImagePath`. Disk allocation after restore was about 28.17 GB, within
  the 64 GiB virtual capacity. The lowest one-second sampled host free space
  during this restore was 47.47 GB (decimal).
- Pause changed the window to Paused; Resume returned it to Running and the
  welcome animation continued.
- After this successful restore and first boot, the exact 26,637,307,067-byte
  test IPSW in Downloads was deleted as requested. Its absence was checked and
  host free space was 82.86 GB. No test IPSW was downloaded into the project.
  Other Downloads files and the Ubuntu guests were left intact.
- The latest app and DMG both pass strict Developer ID signature checks. They
  include the complete first-boot fix, not just the intermediate start guard.
- The user explicitly approved accepting the macOS license and continuing.
  Setup Assistant proceeded with Turkish language, Türkiye region, Turkish Q
  keyboard, and a fresh-device setup with no data migration. Accessibility
  customization was deferred. The local test account name `macvmtest` was
  prepared; the user entered and submitted the new password, as the computer-use
  tool requires. Setup Assistant displayed “Hesap yaratılıyor…” (creating account).

## Installed system and lifecycle checks

- After entering the password, the user completed the remaining Setup Assistant
  screens. The test reached the desktop with local account `macvmtest` (display
  name `macvm test`). The unobserved final setup preferences are not asserted.
- About This Mac displayed Apple Virtual Machine 1, Apple M4 Pro (Virtual),
  8 GB memory, and macOS Golden Gate 27.0.1.
- Guest Terminal `df -h` reported a 59 GiB APFS system/data container with about
  31 GiB available. The configured virtual disk capacity is 64 GiB.
- `ipconfig getifaddr en0` returned `192.168.64.5`. Safari loaded
  `https://example.com`; the address field confirmed HTTPS, with no certificate
  warning or bypass. This exercises NAT, name resolution, and HTTPS browsing.
- Restart from the guest Apple menu returned to the login screen with the test
  account visible. The runner process remained alive across that guest restart.
- At the login screen, MacVM's Shut Down toolbar action did not stop macOS.
  Runtime moved to Stopping, then returned to Running with the timeout message
  after 30 seconds. Keep Running dismissed the recovery sheet. The guest login
  screen's power menu > Shut Down stopped the VM normally, exited the runner,
  and returned the library to zero active machines. Force Stop was not used.
  The host toolbar request was not separately tested while logged into macOS.
- Starting the same VM again from the library created a new runner process
  (99316, session `739F6665-18A2-4417-9604-066EF2D8C77F`) and reached the login
  screen with the same account. The IPSW was already absent and the config has
  no restore-image path, confirming a cold boot from the installed disk.
  A second login/password check was not needed for this boot test.
- After cold boot, the guest power menu shut the VM down again. The final
  runtime is Stopped, no MacVMRunner process remains, and the library reports
  four machines / zero active. At 20:57 Europe/Istanbul the disk occupied
  30.89 GB and host free space was 81.40 GB (decimal). The installer remains
  absent. The final read-only measurement is in
  `.build/macos-final-validation-state.json`.

This is a single-host installation and lifecycle smoke test, not long-term
stability coverage. The guest power menu is currently the verified normal
shutdown path for this macOS guest. The ignored host request remains a known
limitation; it is not recorded as a successful host-controlled shutdown.
