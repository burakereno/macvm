MacVM 0.3 adds Windows 11 ARM and automatic Ubuntu setup to the native VM manager for Apple silicon.

- Create Windows 11 ARM VMs from a local ISO or Microsoft's download link.
  Downloads go to Downloads. Each VM has its own disk, TPM 2.0 identity and
  Secure Boot variables. The creation wizard checks installation headroom.
- Windows runs in the same MacVM library and native VM window, with normal
  shutdown, pause/resume and full-screen entry/exit. QEMU, TPM tools, firmware
  and runtime libraries are bundled; users do not need Homebrew.
- Windows Tools includes ARM64 display, network and serial drivers, automatic
  resolution support, text clipboard and selected shared folders. Install it
  inside Windows from Virtual Machine → Install Windows Tools, then restart.
  Set Windows display scaling to 200% for Retina. Sound output uses the built-in
  Windows High Definition Audio driver.
- Clipboard sharing is opt-in and limited to the active VM and host session.
  Shared folders start read-only and use a private channel. Open
  `\\localhost@9843\DavWWWRoot` in Windows Explorer.
- Automatic Ubuntu 26.04 and 24.04 LTS setup offers Server, GNOME and Xfce
  profiles, optional development tools and SSH public keys. Passwords are hashed
  locally. Setup progress, logs, interrupted-setup retry and completed seed
  cleanup are included. Automated macOS and Windows accounts remain deferred.
- Guest-specific artwork appears in the library and VM Dock items. The MacVM
  application icon remains separate.
- Installation Files can remove unused downloads and ejected VM ISO copies
  while protecting active installation media and VM disks.
- Developer ID app/installer signing, notarization, the Applications DMG and
  verified app updates remain part of the release pipeline. Matching Windows
  engine/helper source archives and original notices accompany the release.

Requires macOS 26 or later on Apple silicon. Windows activation requires your
own licence. Windows GPU support is display-only; accelerated 3D, snapshots,
disk resizing and file drag and drop are not included. Current live acceptance
and its limits are recorded in docs/windows-completion-validation.md and
docs/ubuntu-automatic-validation.md.
