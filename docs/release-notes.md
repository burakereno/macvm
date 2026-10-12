MacVM 0.2 adds installer management, sharing and verified app updates to the native macOS and ARM64 Linux VM manager for Apple silicon.

- macOS downloads go to Downloads, with validated resume after interruption.
- Installation Files lists ISO/IPSW files, partial downloads and their sizes.
  Unused installers can move to Trash; files required for installation or in use
  are protected. VM disks are preserved.
- Per-machine opt-in clipboard sharing and selected shared folders. Folders start
  read-only. macOS text sharing uses current Guest Tools; Linux clipboard sharing
  requires spice-vdagent.
- Imported VM packages start with host sharing disabled until you enable it.
- Manual and automatic update checks, exact publisher and checksum verification,
  staged installation, backup, rollback and relaunch confirmation. Active VMs
  prevent app replacement.
- A designed drag-to-Applications DMG and separately signed Guest Tools installer.
- macOS Guest Tools setup reminders, login-screen shutdown, native full screen,
  Retina resolution, pause/resume, and storage locations.

Requires macOS 26 or later on Apple silicon. Guest Tools desktop and login-screen
shutdown were previously verified on macOS 27.0.1; broader guest-version and
session combinations need separate live validation. This release does not add
Windows, snapshots, disk resizing, or automated guest accounts.
