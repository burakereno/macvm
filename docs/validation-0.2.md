# MacVM 0.2 validation — 12 October 2026

## Passed automated checks

- 42 XCTest cases on the development Mac. Coverage includes sparse storage,
  identity/locking, shutdown timing/session safety, bounded clipboard packets,
  old configuration compatibility, installer protection, space planning,
  resumable downloads, symlink rejection, updater URL/version/manifest/checksum
  validation, and manual versus automatic errors.
- Actual loopback HTTP interruption, cancellation/resume, changed validator,
  and wrong-range rejection through the production downloader. Fixtures write
  under Downloads and are removed afterward (`scripts/verify-downloads.sh`).
- The production update helper rejected a corrupt DMG before mounting or
  replacing the app, retained the original app and cleaned its workspace.
- Signed Linux integration validates cached I/O/full flushes, installer media,
  SPICE attachment and read-only virtiofs configuration. An unavailable shared
  folder produces a start error.
- Signed macOS integration resolves Apple restore build 26A434/macOS 27.0.1,
  validates real hardware/auxiliary storage, and constructs stopped installer
  and installed VM instances. The installed configuration includes Guest Tools
  and selected read-only automount folders. This check does not restore or boot
  an OS.
- The invoked updater audit reports zero findings. Shell syntax, workflow YAML
  and Git whitespace checks pass.

## Distribution validation

[GitHub validation run](https://github.com/burakereno/macvm/actions/runs/38242798064)
passed its macOS 26 tests and real HTTP integration, then signed/notarized the
Guest Tools package, app and DMG. Staple, strict signatures, exact publisher,
and Gatekeeper assessments passed. The downloaded package and DMG were assessed
again locally; the manifest matched version, asset, bundle ID, Team ID and SHA-256.
Publication was disabled for this run. All 42 cases passed in this build.

## Passed live checks

- Installation Files showed actual installer sizes and protected attached media.
  A disposable ISO moved to Trash through the confirmation UI, disappeared from
  the list and remained recoverable in Trash. The VM disks were unchanged.
- Sharing settings selected a host folder, defaulted to read-only and saved
  clipboard opt-in for each test VM. Both temporary configurations were removed
  after the tests.
- The designed Finder DMG showed the app, Applications link and installation
  instructions without clipping. Update settings showed the installed version
  and automatic toggle; manual network errors were visible.
- Ubuntu 26.04.1 shared text in both directions through SPICE/spice-vdagent.
  Its virtiofs folder was readable and rejected a privileged write.
- The bundled signed/notarized Guest Tools 0.2 package installed in macOS 27.0.1
  after user authorization. The setup warning cleared. Text clipboard sharing
  worked in both directions; My Shared Files contained the selected folder and
  rejected a write.
- Ubuntu and macOS ran concurrently. Ubuntu shut down normally. After a macOS
  restart, pause/resume worked at the login screen and the host's Shut Down
  button powered off the guest without Force Stop; the runtime reported stopped.
  A separate cold boot also shut down from the login screen without signing in.
- The production updater helper assessed a notarized DMG, replaced an isolated
  older app and launched the actual 0.2.0 executable with startup confirmation.
  A second test deliberately withheld confirmation: the helper stopped only
  the new target process, restored the original executable and relaunched it.
  Both cases cleaned the mounted image, staging directory and workspace.
  This caught and fixed a macOS Bash 3.2 failure-propagation edge case and
  physical-path aliases in process matching (`scripts/verify-update-launch.sh`).

## Published release and update

[Release run 38251580530](https://github.com/burakereno/macvm/actions/runs/38251580530)
passed tests, signatures, notarization, staples and Gatekeeper, then published
[MacVM 0.2.0](https://github.com/burakereno/macvm/releases/tag/v0.2.0) from
commit `6614cd1`. The public assets were downloaded and checked locally again;
the manifest's exact asset, version, bundle, Team and SHA-256 matched the DMG.
The app and package passed strict signatures and Gatekeeper.

An isolated signed test copy reporting version 0.1.0 found the public 0.2.0
release using the actual Check for Updates UI. Install Update downloaded and
verified the DMG, replaced the app and relaunched a new process. The next check
showed installed version 0.2.0 and "MacVM is up to date". No update workspace or
backup remained. The user's VM packages were preserved and all guests were
stopped during replacement.

## Validation limits

The restore-to-first-boot configuration switch still needs a fresh full restore.
Available space was about 73 GiB, below the 96 GiB same-volume starting policy;
the policy was not bypassed. Existing 0.1 macOS/Ubuntu installation and
full screen/Retina evidence remains in the historical validation documents.
Broader guest-version, multiple-user and unsaved-session combinations remain
in the backlog. Windows is not supported in this release.
