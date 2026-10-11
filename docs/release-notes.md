MacVM 0.1.0 introduces native macOS and ARM64 Linux virtual machines for Apple silicon.

- A compact machine library with live state and disk usage.
- macOS installation from a local IPSW or Apple's latest supported restore image.
- Linux installation from ARM64 UEFI ISOs.
- Per-machine windows and independent runner processes.
- Start, pause, resume, guest shutdown, and force stop.
- CPU, memory, disk capacity at creation, and NAT network settings.
- Storage locations, package import, offline duplication, moving, and Trash support.
- Developer ID signing and a notarized DMG release pipeline.

Requires macOS 26 or later on Apple silicon. Account setup is completed inside
the guest. Windows, snapshots, shared clipboard, and automated accounts are not
included. macOS installation requires enough free space for the OS and restore image.
