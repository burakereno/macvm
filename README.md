# MacVM

A native Swift app for macOS and ARM64 Linux virtual machines on Apple silicon.

## Download

[Download MacVM](https://github.com/burakereno/macvm/releases/latest/download/MacVM.dmg)
and drag the app to Applications. Public releases and the
[macOS Guest Tools installer](https://github.com/burakereno/macvm/releases/latest/download/MacVM-Guest-Tools.pkg)
are Developer ID signed, notarized and stapled. Install Guest Tools inside each
macOS VM using the in-app guide.

## Requirements

- Apple silicon Mac, macOS 26 or later.
- Xcode 26 or later to build (Swift 6 toolchain; Swift 5 language mode).
- macOS: a compatible IPSW, or download the latest compatible image from Apple.
- Linux: an ARM64/aarch64 UEFI ISO. Intel/x86_64 ISOs are not supported.
- Free space: the create wizard requires 64 GiB at the VM location for macOS or 12 GiB for Linux. Automatic macOS downloads also need 32 GiB in Downloads; when both are on the same volume, the starting check is 96 GiB. These are conservative starting checks; monitor space as your machines grow. External volumes can be added under Settings → Locations.

## Build and run

```sh
./script/build_and_run.sh --verify
swift test
./scripts/verify-downloads.sh
# Validate Linux disk cache, flush, and installer-media settings.
./scripts/verify-linux-configuration.sh
# Optional: fetch Apple metadata and validate a real macOS VM configuration.
./scripts/verify-macos-configuration.sh
# Optional live updater install/rollback check; shut down all VMs first.
./scripts/verify-update-launch.sh /path/to/notarized-MacVM.dmg your-signing-identity
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
resizing an existing guest volume is not included in 0.2.

**Shut Down** asks the guest OS to power off. A minimal Linux live environment
may not run an ACPI power service. MacVM waits up to 30 seconds, then restores
the guest's actual running/paused status and explains that shutdown timed out.
Choose **Keep Running**, **Try Shutdown Again**, or **Force Stop**, or shut down
from inside the guest. Clicking the power button while waiting shows shutdown
options without restarting the timeout. MacVM never forces a timed-out guest
off automatically. Force Stop loses unsaved guest work. Closing a VM window offers
to keep it running. Quitting the library does not terminate running guests.

Keyboard events go to the guest as a virtual keyboard. Select a matching layout
inside the guest. Clipboard sharing is opt-in under Machine Settings → Sharing.

### Guest Tools for macOS

Open **Settings → Guest Tools**, the macOS machine’s **Guest Tools…** action,
or **Virtual Machine → Guest Tools…** for the installation guide. The same
guide is available in the running macOS guest window’s Virtual Machine menu.

MacVM checks for Guest Tools while a macOS machine is running. If the connection
remains unavailable for at least 45 seconds, it offers **Set Up Guest Tools…**
and **Later**. Setup opens the installation guide; Later defers the reminder for
that VM session. A toolbar warning remains available until the tools connect.
Already-connected tools, Linux guests, paused VMs, and macOS restoration do not
trigger the reminder. A failed Shut Down request also offers the guide directly.

1. Start the macOS guest and sign in.
2. In the **guest’s Finder**, open **My Shared Files → MacVM Guest Tools**.
3. Run **Install MacVM Guest Tools.pkg** and authorize with the guest’s
   administrator password.
4. Restart the guest using its Apple menu. Repeat installation after updating
   Guest Tools, and for each macOS VM.

The guide’s **Save Installer…** button defaults to Downloads. This exports the
bundled installer without running it on the host. The shared folder also has an
offline Read Me. A missing share requires fully shutting down the VM and starting
it with the current MacVM app. No separate OS download is needed.

Guest Tools provide normal desktop and login-screen shutdown, tested on macOS
27.0.1. If another user session exists, sign in before requesting shutdown so
macOS can handle open applications. Use the guest’s own power menu if the tools
cannot connect. Linux does not need this package. The helper accepts only a fixed
shutdown request over the VM’s host connection; it does not enable SSH, expose
network ports, collect passwords, or automatically force shutdown.

To remove the helper, run inside the guest:

```sh
sudo "/Library/Application Support/MacVM/GuestTools/uninstall.sh"
```

Builds produce both the bundled installer and `dist/MacVM-Guest-Tools.pkg`.
Development packages may have a signed payload without an Installer signature.
Public releases require `INSTALLER_SIGN_IDENTITY` (Developer ID Installer, Team
`66K3EFBVB6`) and `GUEST_TOOLS_NOTARY_PROFILE`. Guest Tools are signed, notarized,
stapled, and assessed **before** signing the containing application. The release
workflow requires `MACOS_INSTALLER_P12_BASE64` and `MACOS_INSTALLER_PASSWORD`
secrets in addition to the Application certificate. It publishes the verified
package beside the DMG; missing installer trust blocks publication. Do not
publish the development package as a signed/notarized release.

The VM toolbar's **Full Screen** button and **Control–Command–F** enter or leave
native macOS full screen. The toolbar stays visible in full screen so **Exit
Full Screen** remains reachable. The shortcut belongs to MacVM while the guest
view has focus; host system shortcuts remain available, and Escape is passed
to guest applications.

MacVM automatically uses the host display's full pixel density, including
Retina. For sharp, comfortably sized Ubuntu text and icons, set **Settings →
Displays → Scale → 200%** inside the guest. Other Linux desktops have their
own scaling settings. Automatic resolution changes require guest driver support.

Display preferences are stored per VM and apply on its next launch as well.

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
macOS images download directly into **Downloads**, with no duplicate cache in the
project or VM location. Interrupted downloads keep a resumable `.ipsw.download`
file; retries use Range and If-Range with a server validator. A changed image
restarts from zero. The completed IPSW is reused until you remove it.

Open **Settings → Installation Files** to see ISO/IPSW files, sizes, partial
downloads, legacy caches, and per-VM ISO copies. **Move to Trash** removes an
unused installer; empty Trash in Finder to reclaim physical space. Images needed
for unfinished macOS restores, active transfers, and attached/running VM media
are protected. Removing an installer leaves the VM disk intact.

Host folders are shared only when selected in **Machine Settings → Sharing**.
Each folder starts read-only. macOS mounts them in Finder → My Shared Files.
Linux mounts the `macvm-share` virtiofs tag; the settings show the mount command.
Missing folders produce an actionable start error.

macOS text clipboard sharing requires current Guest Tools and operates only
while that VM window is active. Linux uses Apple’s SPICE clipboard attachment
and requires `spice-vdagent` inside the guest (Ubuntu: `sudo apt install spice-vdagent`,
then sign out and back in). Existing VMs keep sharing disabled after updating.
No microphone input, telemetry, or network control server is enabled. Guest internet uses Apple's NAT networking. No private Apple APIs
or third-party runtime dependencies are used.

Linux disks and installer media explicitly use host caching, with full flush
synchronization retained for the writable disk. This avoids the automatic
uncached I/O path implicated in Linux corruption reports from other Apple
Virtualization clients; guest compatibility still requires installation tests.

For local Linux diagnostics, the runner accepts `--serial-log /absolute/log/path`
alongside `--bundle /absolute/machine.macvm`. Add `console=hvc0` to the guest
kernel command line to capture its console output. Logging is opt-in, appends
to the specified file, and does not provide a serial input channel. Treat the
log as private guest data; it is not included in distribution artifacts.

## Release

`/.github/release-contract.env` is the release metadata source of truth.
The manual GitHub workflow imports an ephemeral signing identity, runs tests,
verifies the publisher and hardened runtime, notarizes and staples the app and
DMG, checks Gatekeeper, then publishes a version tag, DMG, and SHA-256 manifest.
It must run in the configured repository with the eight secrets listed in
the release workflow: six Application/notarization secrets and two Installer
certificate secrets. No credentials belong in Git.

For local notarization with an existing Keychain profile:

```sh
NOTARY_PROFILE=your-profile CODESIGN_IDENTITY=your-identity ./scripts/notarize-release.sh
```

`scripts/create-dmg.sh` also creates a local development DMG. A locally signed
build is **not notarized** until the notarization script and Gatekeeper checks
have succeeded. Choose **MacVM → Check for Updates…** to download and install a verified release.
Automatic checks are quiet on network errors. The updater uses GitHub’s latest
release redirect, validates the DMG and companion manifest, checks SHA-256,
requires the exact Developer ID publisher and Gatekeeper assessment, stages
the new app, and preserves a backup until the new executable confirms startup.
Failed replacement or relaunch restores the previous app. Running VMs hold a
shared application lock that excludes update installation.

## Follow-up features

Windows, snapshots/save-to-disk, drag and drop between
host and guest, automated accounts, port forwarding, Parallels import, and
CLI/MCP automation are follow-up work. This release uses public Virtualization
APIs; guest GPU capabilities depend on Apple's framework and the guest drivers.

See [0.2 validation notes](docs/validation-0.2.md) for current checks and limits,
and [0.1 validation history](docs/validation.md) for the earlier installation tests.
Deferred fixes are tracked in [the backlog](docs/backlog.md).
