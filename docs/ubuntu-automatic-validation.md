# Ubuntu automatic setup validation — 2026-10-12

Local Developer ID signed development build on an Apple silicon Mac
(14 cores, 24 GB RAM, macOS 26). macOS account automation is deferred.
These acceptance results describe the original test run. The feature subsequently
shipped in [MacVM 0.3.0](https://github.com/burakereno/macvm/releases/tag/v0.3.0).

## Observed guest coverage

| Guest | Actual checks |
| --- | --- |
| Ubuntu 26.04.1 Server | cloud-init completed, requested account/hashed password, password sudo, SSH, root disk growth, ordinary shutdown and subsequent boot |
| Ubuntu 26.04.1 GNOME | desktop installation, gdm3, 200% guest scaling, graphical session in the real runner, subsequent boot and ordinary shutdown |
| Ubuntu 26.04.1 Xfce + development | lightdm, Xfce graphical session/scaling, Git/GCC, Python venv, Node/npm, Docker/Compose and an ARM64 hello-world container, ordinary shutdown |
| Ubuntu 24.04 Server | production ImageDownloader to Downloads, official SHA256SUMS verification, full setup/account/password/sudo/SSH/disk checks |
| Completed Ubuntu 24.04 clone | different VM identity/MAC, no credential seed, new DHCP address and usable SSH/account/root disk after boot |
| Controlled Ubuntu 26.04 failure | an injected exit 99 after the package checkpoint produced failed status; the production retry API caused a live transition to ready and retained the package checkpoint timestamp |
| Creation UI | user entered a test password; an invalid short password was blocked with an explanation; Create & Start produced a working VM, stage updates, completion, normal shutdown and seed cleanup |
| Setup Log UI | real long GNOME log rendered, read-only, at its latest output; bounded reads, symlink rejection and ANSI cleanup tested |

GNOME and Xfce test fixtures used temporary auto-login solely to inspect the
desktop without collecting a user's login password. Shipping profiles keep
normal password login. Ubuntu's optional first-login welcome screens can
still appear. Installed SPICE package/daemon and native port configuration
were checked; this run did not repeat a clipboard matrix across compositors.

## Verification

- swift test: **57 tests, 0 failures**.
- Password hashing: independent Linux SHA-512-crypt vectors including UTF-8,
  salted uniqueness and malformed-input checks; actual guest shadow verification.
- QCOW2: v2/v3 allocated, zero, sparse and raw-deflate clusters; unsupported
  features, malformed offsets/data, truncation, output preservation and cancellation.
- NoCloud/account configuration, bounded status/log input, private setup metadata,
  exact ARM64 catalog selection, managed image deletion and image leases.
- scripts/verify-linux-configuration.sh: passed cached/full-flush disk,
  read-only installer, SPICE and folder-share validation.
- scripts/verify-downloads.sh: passed real HTTP interruption, validator changes,
  invalid ranges and cancellation/resume; synthetic downloads were removed.
- git diff --check and local app signature validation passed.

The tested combinations are listed above. Ubuntu 24.04 desktop profiles,
GNOME with development tools, other host hardware and extended stress tests
were not separately exercised.

## Findings incorporated

The official .tar.gz contains an ext4 filesystem rather than a complete EFI
disk. The implementation now downloads the official .img QCOW2 artifact and
converts it internally, with no external qemu-img installation. All source
downloads use Downloads.

A USB seed was not detected by the cloud guest; the seed now uses a read-only
virtio block device. Host writes through virtiofs did not reliably generate
guest inotify events; a fixed guest polling service handles retry only until
setup becomes ready. Pending setup is enabled at boot, uses checkpoints and
repairs interrupted dpkg configuration.

The network seed matches virtual Ethernet by name rather than pinning the
original MAC, so duplication retains working DHCP. Credential media are
removed only after completed setup and the runner releases its lock.
Long SwiftUI Text logs did not render reliably; the log sheet now uses
a bounded, read-only native text view.

## Reproducing

Run one profile at a time. These commands download an official image to
Downloads, create a private disposable VM and credentials, verify the guest,
request normal shutdown, and remove the test VM and credentials. Logs remain
under the ignored .local folder. The reusable downloaded image remains
visible in Downloads / Installation Files for reuse or removal.

    scripts/verify-ubuntu-automatic.sh server resolute no
    scripts/verify-ubuntu-automatic.sh gnome resolute no
    scripts/verify-ubuntu-automatic.sh xfce resolute yes
    scripts/verify-ubuntu-automatic.sh server noble no

The individual signed fixtures are in Tests/Integration/UbuntuAutomaticCheck.swift,
UbuntuDownloadCheck.swift and UbuntuCloneCheck.swift. The current run used
these components directly; the convenience shell wrapper was syntax-checked.
Desktop and native UI inspection remain a manual computer-use check.

Primary format references: [Ubuntu image artifacts](https://ubuntu.com/docs/public-images/public-images-reference/artifacts/),
[cloud-init NoCloud](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html),
[QEMU QCOW2 format](https://www.qemu.org/docs/master/interop/qcow2.html).

## Cleanup

All disposable VMs and generated credentials from this run were stopped and removed. The three owned source downloads (the initial 26.04 tarball and final 26.04/24.04 QCOW2 images) were removed through the Installation Files validation/lease API with an injected deletion operation. Existing user VMs and user-downloaded ISO files were retained. Only small ignored test logs remain.
