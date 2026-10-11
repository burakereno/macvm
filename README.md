# MacVM

A native Swift app for macOS and ARM64 Linux virtual machines on Apple silicon.

## Requirements

- Apple silicon Mac, macOS 26 or later.
- Xcode 26 or later to build (Swift 6 toolchain; Swift 5 language mode).
- macOS: a compatible IPSW, or download the latest compatible image from Apple.
- Linux: an ARM64/aarch64 UEFI ISO. Intel/x86_64 ISOs are not supported.
- Free space: the create wizard requires 64 GiB for a local macOS image, 90 GiB for download plus installation, or 12 GiB for Linux. These are conservative starting checks; monitor space as your machines grow. External volumes can be added under Settings → Locations.

## Build and run

```sh
./script/build_and_run.sh --verify
swift test
# Optional: fetch Apple metadata and validate a real macOS VM configuration.
./scripts/verify-macos-configuration.sh
```

The Codex Run button uses the same script. The app bundle is `dist/MacVM.app`.
The script stops the library app before rebuilding and refuses to replace the
bundle while any MacVM guest is running. Shut down guests first.

Development builds use an ad-hoc signature with the virtualization entitlement.
For a Developer ID build, set `CONFIGURATION=release` and `CODESIGN_IDENTITY` to
the Developer ID identity in your Keychain, then run `scripts/build-app.sh`.
The build verifies the exact publisher Team ID for both the app and its helper.

## Using MacVM

1. Choose **New Virtual Machine** (⌘N).
2. Pick macOS or Linux and an installation image.
3. Choose a storage location, CPU, memory, disk capacity, and network access.
4. Create the machine. Each guest opens in its own window and process.
5. Complete guest account setup inside the guest. MacVM does not collect a guest password.

For Linux, shut down after installing to the virtual disk, open the machine's
settings, and turn **Boot from installer ISO** off. The ISO stays in the package
in case it is needed later. For macOS, Apple’s installer runs first, then macOS
starts its normal Setup Assistant.

The row's play/pause button starts, pauses, or resumes a machine. Double-click a
row to open its window. Its action menu includes shutdown, force stop, settings,
duplicate, move, show in Finder, and move to Trash. CPU, RAM, boot media, and
network can be changed while stopped. Disk capacity is chosen at creation;
resizing an existing guest volume is not included in 0.1.

**Shut Down** asks the guest OS to power off. A minimal Linux live environment
may not run an ACPI power service; shut down from inside that guest or use
**Force Stop**. Force Stop loses unsaved guest work. Closing a VM window offers
to keep it running. Quitting the library does not terminate running guests.

Keyboard events go to the guest as a virtual keyboard. Select a matching layout
inside the guest. The shared clipboard is not included in this version.

## Storage and architecture

- `MacVM`: SwiftUI library, creation wizard, native settings, downloads.
- `MacVMCore`: versioned models, storage operations, locking, VZ configuration.
- `MacVMRunner`: separately signed AppKit helper with `VZVirtualMachineView`.
- `Tests/MacVMCoreTests`: actual file, sparse disk, identity, validation, and lock tests.

Each `.macvm` package contains `Config.json`, a sparse `Disk.img`, guest-specific
firmware/identity files, and (for Linux) `Installer.iso`. Packages are private to
the current user at creation. The runner holds an exclusive kernel file lock
for its lifetime; destructive changes and duplicates acquire the same lock.
Session-scoped commands and atomic status files reconnect the library to a
guest after relaunch. Duplicates get a new machine identity and MAC address;
APFS file cloning is used when available, with a copy fallback on other volumes.
New and duplicate packages are published only after preparation is complete.

The library index is in `~/Library/Application Support/MacVM/Library.json`.
Default packages live under that folder's `Virtual Machines` directory.
Additional locations and existing packages can be registered without copying.
macOS downloads stream directly to `Base Images` on the chosen volume, avoiding
a second image-sized allocation on the startup disk. Cancelled downloads are
removed. A downloaded IPSW is retained for reuse.

No host folder sharing, microphone input, telemetry, or network control server
is enabled. Guest internet uses Apple's NAT networking. No private Apple APIs
or third-party runtime dependencies are used.

## Release

`/.github/release-contract.env` is the release metadata source of truth.
The manual GitHub workflow imports an ephemeral signing identity, runs tests,
verifies the publisher and hardened runtime, notarizes and staples the app and
DMG, checks Gatekeeper, then publishes a version tag, DMG, and SHA-256 manifest.
It must run in the configured repository with the six secrets described in
the user's `macos-developer-id-release` skill. No credentials belong in Git.

For local notarization with an existing Keychain profile:

```sh
NOTARY_PROFILE=your-profile CODESIGN_IDENTITY=your-identity ./scripts/notarize-release.sh
```

`scripts/create-dmg.sh` also creates a local development DMG. A locally signed
build is **not notarized** until the notarization script and Gatekeeper checks
have succeeded. The update manifest is release metadata; 0.1 has no built-in updater.

## Not in 0.1

Windows, snapshots/save-to-disk, shared folders/clipboard, drag and drop between
host and guest, automated accounts, port forwarding, Parallels import, and
CLI/MCP automation are follow-up work. This release uses public Virtualization
APIs; guest GPU capabilities depend on Apple's framework and the guest drivers.

See [validation notes](docs/validation.md) for tested behavior and limitations.
