# MacVM 0.1 validation

Validated on 11 October 2026 using an Apple silicon Mac (14 CPU cores, 24 GB RAM),
macOS 27.0.1 (26A434), Xcode 27.0, and Swift 6.4. Deployment target: macOS 26.

## Automated checks

- Debug and optimized release builds complete.
- The signed `scripts/verify-linux-configuration.sh` integration check passes
  for installed-disk and installer boot: Linux attachments use explicit cached
  I/O and full synchronization, with read-only ISO media. This checks actual
  VZ configurations and is not a guest installation test.
- Eleven XCTest cases pass: four shutdown deadline tests and seven
  storage/configuration tests. The latter cover sparse disk allocation/config round trip, exclusive
  locking, clone identity and independent disk contents, unsupported schemas,
  symlink rejection, invalid resource rejection, and incomplete macOS clone
  rejection, and importing a higher-resource machine before adapting it to the
  current host (several assertions are grouped within a case).
- `scripts/verify-macos-configuration.sh` resolves Apple's latest supported
  restore image metadata, creates real macOS auxiliary storage and a new
  machine identifier, and validates the same VZ configuration used by the app.
  Passed with restore build 26A434, macOS 27.0.1.
- Shell scripts parse and the GitHub Actions workflow parses as YAML.
- App and nested runner pass strict code signature checks, with hardened
  runtime and exact Developer ID TeamIdentifier `66K3EFBVB6`.
- The locally generated DMG passes strict signature and exact publisher checks.

## Exercised through the native UI

- Empty library, new-machine sheet, macOS free-space validation.
- Linux ISO selection, actual sparse disk and EFI creation, and runner launch.
- macOS 27.0.1 (26A434) Local IPSW installation with 4 CPUs, 8 GiB memory,
  and a 64 GiB sparse disk. After fixing the restore-to-first-boot lifecycle,
  a fresh restore entered Setup Assistant automatically. Account setup,
  desktop, NAT/HTTPS browsing, pause/resume, guest restart, guest power-menu
  shutdown, and cold boot without the deleted IPSW passed. The guest had about
  31 GiB available. MacVM's shutdown request at the login screen was ignored;
  the 30-second timeout recovery worked. See
  [macOS installation validation](macos-installation-validation.md).
- Alpine Linux 3.24.2 aarch64 virtual ISO, downloaded from the official Alpine
  mirror and verified against its SHA-256, boots through UEFI to the login prompt.
- Virtual keyboard input successfully logs into the live guest.
- Ubuntu 26.04.1 Desktop ARM64 ISO from Downloads matches the official Ubuntu
  SHA-256 (`c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517`).
  The initial automatic-cache configuration froze during extraction at both
  4 and 2 CPUs. After enabling explicit cached disk/ISO I/O with full flush
  synchronization retained, the same ISO completed installation with 2 CPUs,
  8 GiB RAM, and a 64 GiB sparse disk. The live kernel was `7.0.0-30-generic`;
  online updates installed `7.0.0-38-generic`. Login and first-run setup passed.
  `/etc/os-release` reported Ubuntu 26.04.1 LTS; root was `/dev/vda2` / `ext4`,
  with 48G available. No failed systemd units were listed. DHCP, default routing,
  DNS, and HTTP access to `example.com` passed. MacVM's normal shutdown completed
  within seconds. A subsequent cold boot through the signed release app, with
  installer boot disabled and no serial diagnostic device, reached the desktop
  and again shut down normally; no runner remained and the library showed zero
  active machines. The final kernel-error check contained only a PCI `of_root`
  message, with no oops observed. The live installer's ACPI shutdown was ignored,
  but its Restart Now action succeeded without Force Stop. At the end the disk
  occupied 10.38 GB and 118.61 GB remained free on the host (decimal).
  See [Ubuntu investigation](ubuntu-installation-investigation.md) for evidence,
  the serial-diagnostic difference during installation, and causal limits.
- Ubuntu 26.04.1 follow-up: `stress-ng --iomix 4 --iomix-bytes 256m`
  against `/var/tmp`, with a 10-minute timeout and verification requested,
  completed in 600.18 seconds: four workers passed, zero failed. The subsequent
  kernel-error check showed only the existing PCI message; normal shutdown
  passed again. See the investigation for the full command and test limits.
- Ubuntu 24.04.3 Desktop ARM64 control image matches its official SHA-256
  (`cdbf0f83ab4f7d46be767e73c59b5cbca9743dd5fb887142c96f4b2df38fa5ad`).
  Installation completed with 2 CPUs, 8 GiB RAM, and a fresh sparse 64 GiB disk.
  The live installer ran kernel `6.14.0-27-generic`; online installation updates
  installed `7.0.0-38-generic`. With installer boot disabled, the VM booted the
  installed disk, logged into the test account, and completed first-run setup.
  `findmnt` confirmed `/dev/vda2` / `ext4`; `df -h /` showed 49G available.
  DHCP/default routing and DNS worked; an HTTP request to `example.com` returned
  `200 OK`. No failed systemd services were listed. MacVM's Shut Down button
  stopped this installed guest within a few seconds, exited the runner, and
  restored zero active machines. The live installer session's earlier shutdown
  stalled and required Force Stop; see the investigation for that limitation
  and the installed guest's single PCI error message.
- Pause and resume update both the VM window and the library.
- VM full screen: Ubuntu 26.04.1 enters native full screen using the toolbar
  button. The toolbar remains visible with Exit Full Screen, and that button
  restores the window. Repeated transitions also worked with guest HiDPI enabled.
  Control–Command–F was corrected with an app-local event monitor after the
  window-level handler failed. The user confirmed the updated shortcuts work.
- Display scaling: the lower-resolution mode made Ubuntu controls larger but
  visibly softer, so the Display menu and custom resolution code were removed.
  Full pixel density is now automatic for all guests. At 3456 × 1804 guest pixels, Ubuntu's
  Displays → Scale → 200% enlarged the UI while retaining the full resolution.
  Apply / Keep Changes were completed and the setting persisted across a cold
  boot. See [display validation](display-validation.md).
- Guest shutdown request transitions to Stopping. Alpine's minimal live image
  does not service the ACPI request; confirmed Force Stop exits the helper and
  releases the disk lock. Guest power-menu support depends on the OS.
- Shutdown recovery: the original stuck Alpine session was shut down normally
  from inside the guest. In a fresh session, an ignored shutdown request timed
  out after 30 seconds and restored Running with an explanatory message and
  Keep Running / Force Stop / Try Shutdown Again choices. Repeated power clicks
  opened options without resetting the deadline; Pause was disabled while
  waiting. Keep Running, subsequent Pause, retry from Paused (which resumes the
  guest first), and explicit Force Stop were exercised successfully.
- Relaunching the Developer ID signed app restores the library; the same VM
  can be started again.
- After a second boot, `poweroff` inside the guest cleanly stops the VM, exits
  the helper, and records Stopped in the library.
- Duplicate creates an independent package with a new UUID and MAC address.
- Renaming and editing CPU/RAM persist and update the row.
- Adding a second location and moving a stopped machine update the actual
  package path while preserving its identity.

## Limits of this validation

- macOS's guest power menu is the verified normal shutdown path. The MacVM
  toolbar request was ignored at its login screen and was not separately
  exercised while logged in. The test used Local IPSW; the creation wizard's
  automatic download/cache flow and long-term macOS stability remain unverified.
  The 26.64 GB test IPSW was deleted from Downloads after successful restore.
- Alpine and Ubuntu live boots, plus Ubuntu 24.04.3 and 26.04.1 installation,
  installed-disk boot, desktop, networking, and normal shutdown are verified.
  Ubuntu 26.04.1 passed after the caching change; a controlled single-variable
  reproduction of the earlier failures is still needed to establish precise
  causality. Fedora and long-term guest stability remain unverified.
- Automated host text injection into a guest with a different keyboard layout
  did not preserve punctuation. Configure the guest keyboard layout; this
  release has no clipboard bridge. Even with matching Turkish layouts,
  automated modifier-key injection did not reliably preserve Ctrl+C or colon
  input. Both installed Ubuntu guests passed NAT/DNS and HTTP access; the request to
  `ubuntu.com` timed out and HTTPS was not separately verified.
- Notarization, stapling, Gatekeeper acceptance of a downloaded artifact, and
  GitHub publication have not been completed. No GitHub remote is configured;
  the checked `notarytool` Keychain profile does not exist. The DMG is a locally
  signed preview, not a notarized public release.
- CI is prepared but has not run remotely. Windows, snapshots, shared folders,
  clipboard/drag-and-drop, automated accounts, and MCP are outside this version.

Build logs and local integration output are in ignored `.build/` files. Test
ISOs are in ignored `.local/test-images/`; no operating-system image, virtual
disk, certificate, or generated distribution artifact is tracked in Git.
