# MacVM 0.1 validation

Validated on 11 October 2026 using an Apple silicon Mac (14 CPU cores, 24 GB RAM),
macOS 27.0.1 (26A434), Xcode 27.0, and Swift 6.4. Deployment target: macOS 26.

## Automated checks

- Debug and optimized release builds complete.
- Seven XCTest cases pass: sparse disk allocation/config round trip, exclusive
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
- Alpine Linux 3.24.2 aarch64 virtual ISO, downloaded from the official Alpine
  mirror and verified against its SHA-256, boots through UEFI to the login prompt.
- Virtual keyboard input successfully logs into the live guest.
- Pause and resume update both the VM window and the library.
- Guest shutdown request transitions to Stopping. Alpine's minimal live image
  does not service the ACPI request; confirmed Force Stop exits the helper and
  releases the disk lock. Guest power-menu support depends on the OS.
- Relaunching the Developer ID signed app restores the library; the same VM
  can be started again.
- After a second boot, `poweroff` inside the guest cleanly stops the VM, exits
  the helper, and records Stopped in the library.
- Duplicate creates an independent package with a new UUID and MAC address.
- Renaming and editing CPU/RAM persist and update the row.
- Adding a second location and moving a stopped machine update the actual
  package path while preserving its identity.

## Limits of this validation

- A full macOS IPSW download, install, and guest boot was not attempted because
  the host had only about 24 GiB free at the start. The metadata/configuration
  integration check is not a substitute for full install testing.
- Alpine live boot is verified; Ubuntu/Fedora installation and booting an
  installed guest disk have not been separately verified.
- Automated host text injection into a guest with a different keyboard layout
  did not preserve punctuation. Configure the guest keyboard layout; this
  release has no clipboard bridge. A guest internet connectivity test was not
  completed, so NAT is configured but not separately verified end to end.
- Notarization, stapling, Gatekeeper acceptance of a downloaded artifact, and
  GitHub publication have not been completed. No GitHub remote is configured;
  the checked `notarytool` Keychain profile does not exist. The DMG is a locally
  signed preview, not a notarized public release.
- CI is prepared but has not run remotely. Windows, snapshots, shared folders,
  clipboard/drag-and-drop, automated accounts, and MCP are outside this version.

Build logs and local integration output are in ignored `.build/` files. Test
ISOs are in ignored `.local/test-images/`; no operating-system image, virtual
disk, certificate, or generated distribution artifact is tracked in Git.
