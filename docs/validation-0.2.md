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
Publication was disabled for this run. The final source hardening changes and
all 42 cases passed in this build; live GUI validation remains before release.

## Live checks still required for 0.2

- Installation Files listing/Trash, sharing settings, update UI and Finder DMG
  appearance in the current app.
- Ubuntu clipboard/share and macOS updated Guest Tools clipboard/share;
  simultaneous guests and the broader shutdown/session cases in the backlog.
- Actual update installation/relaunch and failure recovery against the final
  signed release in an isolated test app.
- The new restore-to-first-boot configuration switch needs a fresh restore test.
  Existing 0.1 macOS/Ubuntu installation, full screen/Retina and shutdown evidence
  remains in the linked historical validation documents.

These GUI tests have not yet been claimed as passed. No public release has been
dispatched.
