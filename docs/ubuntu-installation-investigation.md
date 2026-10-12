# Ubuntu installation investigation — 11 October 2026

Ubuntu 26.04.1 result: **installation, installed-disk boot, desktop, network,
and normal shutdown passed after enabling explicit Linux disk caching**.
The original official ISO was used again; it was not replaced by the control
image. Two earlier attempts with automatic caching froze during extraction.
The successful test supports retaining the caching change, but does not prove
that caching alone caused the difference: serial diagnostics were also enabled
during installation. A subsequent cold boot and normal shutdown passed using
the signed release app, without the serial device or installer ISO attached.
Long-term stability and a controlled single-variable reproduction remain unverified.

## Reproduction environment

- Host: Apple silicon, 14 cores, 24 GB RAM; macOS 27.0.1 (26A434).
- Guest: official Ubuntu 26.04.1 Desktop ARM64 ISO,
  `ubuntu-26.04.1-desktop-arm64.iso`, kernel `7.0.0-30-generic`.
- SHA-256 of both downloaded and VM-bundled ISO:
  `c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517`.
  Compared with [Ubuntu's official manifest](https://cdimage.ubuntu.com/ubuntu/releases/26.04.1/release/SHA256SUMS).
- VM: EFI boot, 8 GiB RAM, 64 GiB sparse disk, NAT, virtio graphics/block,
  USB installer media, keyboard and pointing device. The failing baseline used
  automatic disk caching and full synchronization. The standard virtio balloon is configured;
  the app does not adjust its target.
- Interactive installation, default applications, no third-party codecs,
  erase the fresh virtual disk (`vda`), no encryption, Europe/Istanbul timezone.
  Account details were entered by the user in the guest.

## Observations

| Attempt | CPU count | Result |
| --- | --- | --- |
| First | 4 | Froze during copying, approximately 6.3 GB allocated. EFI pstore contains kernel NULL pointer oopses. |
| Second | 2 | Froze during extraction with 118,636,544 bytes allocated. Guest clock stopped at 15:16; last disk modification was 15:16:37. |
| Explicit caching | 2 | Same ISO completed installation, updated kernel, booted installed disk, reached desktop, and shut down normally. A second boot with the release app and no serial device or ISO also passed. |

At 15:22, the second virtualization process used approximately 199% CPU. Its
sample showed both virtual CPU threads in Hypervisor execution and disk I/O
threads waiting. The guest remained visually unchanged. This establishes a
hang, not its cause. Reducing the CPU count did not resolve it.

The first recovered oops reports an instruction abort at address zero, with
`seccomp_run_filters` as the link-register frame in `systemd-logind`. Further
faults follow. The guest had automatically loaded ZFS/SPL modules; their taint
flags do not establish that they caused the failure. No security mechanism was
disabled during investigation.

The second EFI capture retains the first attempt's pstore records. It is not
independent evidence of the second failure's stack trace.

Both normal shutdown requests timed out. Explicit Force Stop returned the VM
to Stopped and released its processes. Pause/resume in the first attempt worked
at the host level but did not recover the guest.

Host free space after stopping the second attempt was approximately **105 GB**
(decimal). The virtual disk's 64 GiB size is its capacity; only about 119 MB was
allocated after the second attempt reformatted it. Disk exhaustion and a
mismatched installation ISO are not supported by the observations.

## Local evidence

Diagnostic files are ignored and are not part of a release:

- `.build/ubuntu-kernel-oops.log`: decoded first-attempt EFI pstore.
- `.build/ubuntu-hang-EFI.nvram`: first-attempt firmware capture.
- `.build/ubuntu-vz-sample.txt`: first-attempt virtualization process sample.
- `.build/ubuntu-retry-EFI.nvram`: second-attempt firmware capture.
- `.build/ubuntu-retry-kernel-oops.log`: earlier records decoded from the second
  attempt's firmware, not a newly observed backtrace.
- `.build/ubuntu-retry-vz-sample.txt`: second-attempt virtualization process sample.

## Explicit disk caching experiment

The implemented change sets Linux disk and ISO attachments to `cachingMode: .cached`
while retaining `.full` synchronization. macOS disk configuration is unchanged.
This addresses a known failure mode described in an
[UTM reproduction using Apple's VZ sample](https://github.com/utmapp/UTM/issues/4840#issuecomment-1824340975),
and the corresponding default-cache changes in
[Lima](https://github.com/lima-vm/lima/commit/488c95c41c67ae0c3afa8f35173a6e1ef59d29ef)
and [vfkit](https://github.com/crc-org/vfkit/commit/732de99a184e83c11e245f4f0d4e03ccedddb4f5).
These reports motivate the change; they do not establish the cause of this
particular Ubuntu 26.04.1 failure.

The signed Linux configuration check passes for both boot modes, all eleven
unit tests pass, and debug and release builds pass. The final optimized app
and nested runner were signed with Developer ID, passed strict signature and
exact Team ID checks, and were launched through `script/build_and_run.sh --verify`.
An opt-in `--serial-log` runner argument adds a virtio console file attachment;
the test boot also adds `console=hvc0` in GRUB. The serial diagnostic device is
an additional configuration difference and may affect timing.

A short earlier experiment without the memory balloon did not reach the live
desktop during the observation period. Its host sample showed vCPUs waiting
for interrupts, but no guest backtrace was captured. This was not a proven
kernel crash. The original balloon configuration was restored before the
cache experiment.

The original 26.04.1 ISO reached the graphical live desktop at approximately
16:48 with cached I/O, 2 CPUs, and 8 GiB RAM. After a host unlock and user account
entry, interactive installation began around 17:01. Extraction began at
17:02:13, completed by 17:04:47, and curtin reported successful system and GRUB
configuration at 17:06:18. Online updates installed kernel `7.0.0-38-generic`.
The installer displayed completion around 17:11.

The live session ignored MacVM's ACPI shutdown request and the recovery alert
appeared after 30 seconds. Keep Running followed by the installer's Restart Now
completed the reboot after a guest stop-job wait. Force Stop was not needed in
this attempt. The installed guest reached login around 17:13; login and
first-run setup completed. Ubuntu Pro was skipped, location remained disabled,
and system/error-report sharing was declined.

| Installed-system check | Observed result |
| --- | --- |
| Distribution | `/etc/os-release`: Ubuntu 26.04.1 LTS, Resolute Raccoon |
| Running kernel | `7.0.0-38-generic` |
| Root filesystem | `/dev/vda2`, `ext4`, mounted read/write; not a live overlay |
| Guest free space | `df -h /`: 62G capacity, 11G used, 48G available, 19% used |
| Failed services | `systemctl --failed --no-pager`: zero units |
| Network | `enp0s1`: 192.168.64.3/24; default gateway 192.168.64.1 |
| Internet | `wget --spider --timeout 10 --tries 1 example.com`: DNS and HTTP 200 OK |
| First normal shutdown | MacVM shutdown stopped the installed guest within seconds at 17:22; runner exited and library showed zero active machines |
| Cold boot | Boot from installer ISO disabled in machine settings; signed release app launched the guest from the library without `--serial-log`; desktop reached |
| Second normal shutdown | MacVM shutdown stopped the cold-booted guest within seconds around 17:28; runtime recorded Stopped, runner exited, library showed zero active machines |

The first installed boot's error-priority kernel journal contained the PCI
`of_root node is NULL, cannot create PCI host bridge node` message and
`/dev/sda1: Can't open blockdev` while the installer ISO was still attached.
After disabling installer boot, the same journal check showed only the PCI
message. No kernel oops was observed in either check. The installation serial
log contained no matches for `BUG:`, `Oops:`, `Kernel panic`, `Unable to handle`,
`I/O error`, or `Bad rss-counter`; this is not a long-term stability guarantee.
HTTPS was not separately verified.

After the final shutdown, the virtual disk occupied approximately **10.38 GB**
and the host had **118.61 GB free** (decimal). The VM is left stopped with
installer boot disabled. The 64 GiB disk is sparse and can grow as data is added.
The earlier memory-balloon probe was discarded; the standard balloon remains
configured. No AppArmor, seccomp, or other guest protection was disabled.

Additional ignored local evidence:

- `.build/ubuntu26-cached-serial.log`: console from the cached-I/O boot.
- `.build/ubuntu26-no-balloon-vz-sample.txt`: host sample from the earlier probe.
- `.build/ubuntu26-tests.log`: eleven passing unit tests.
- `.local/ubuntu26-before-balloon-test/`: APFS-cloned disk and firmware backup
  from before these experiments.

## Follow-up disk load test

At approximately 19:15–19:26, the installed Ubuntu 26.04.1 guest was booted again
using the signed release app, without installer media or a serial console.
The official Ubuntu repository supplied `stress-ng` 0.20.01-1. The command was:

```sh
stress-ng --iomix 4 --iomix-bytes 256m --temp-path /var/tmp --timeout 10m --verify --metrics-brief
```

This exercised the disk-backed `/var/tmp` filesystem, with 64 MiB per worker
and 256 MiB total temporary file capacity. The tool reported 638,596 bogo
operations in 600.18 seconds, four passed workers, zero failed/skipped workers,
and zero untrustworthy metrics. It printed a successful 10-minute completion.
The post-test error-priority kernel journal still contained only the earlier
PCI `of_root` message; no new kernel error appeared in that check. Normal MacVM
shutdown then completed and runtime recorded Stopped. A host-side macOS IPSW
download ran concurrently. This is a bounded disk-load test, not a long-term
stability or exhaustive data-integrity guarantee.

## Ubuntu 24.04.3 control image

The official `ubuntu-24.04.3-desktop-arm64.iso` was downloaded for the next test.
Its published package manifest lists `linux-image-6.14.0-27-generic`, providing
a different kernel from the failing Ubuntu 26.04.1 image. Both the download and
the VM-bundled copy match the official SHA-256:
`cdbf0f83ab4f7d46be767e73c59b5cbca9743dd5fb887142c96f4b2df38fa5ad`.

A new VM (`62B8766D-A742-4B40-8E58-F47F8109EEBD`) uses 2 CPUs, 8 GiB RAM,
and a fresh sparse 64 GiB disk. It boots through EFI to the live desktop and
interactive installer. Turkish keyboard layout was selected to match the
host; the input field correctly received `test -r / 123`.

The user completed account creation. Interactive installation on the fresh
virtual disk completed at approximately 16:21, including online package and
security updates. Although the installer was initially asked not to connect,
its logs show network downloads; this was not an offline installation. The
live session's `uname -r` reported `6.14.0-27-generic`.

The live session did not complete shutdown. It waited for `session-1.scope`
with a 90-second guest deadline, displayed `Bad rss-counter state` messages
and later `fb_set_par error, error code: -16`, and remained active after several
minutes. MacVM's 30-second recovery alert appeared; Keep Running allowed more
time, then explicit Force Stop ended the live session. This is a separate
limitation from the successful installed-system shutdown below.

With **Boot from installer ISO disabled**, the installed system booted from its
virtual disk. Login succeeded and first-run setup completed (Ubuntu Pro skipped,
system-data sharing declined). Checks in the installed guest showed:

| Check | Observed result |
| --- | --- |
| Running kernel | `7.0.0-38-generic`, installed by the online updates |
| Root filesystem | `/dev/vda2`, `ext4` (not the live ISO overlay) |
| Guest disk space | `df -h /`: 62G capacity, 9.7G used, 49G available, 17% used |
| NAT/DHCP | `enp0s1`, address `192.168.64.4`, default gateway `192.168.64.1` |
| Internet | `wget --spider --timeout=5 --tries=1 example.com`: DNS resolution and HTTP `200 OK` |
| Failed services | `systemctl --failed --no-pager`: zero units |
| Kernel errors | `journalctl -k -b -p 3 --no-pager`: one PCI `of_root node is NULL, cannot create PCI host bridge node` message; no oops in this check |
| Normal shutdown | MacVM's Shut Down button stopped the guest within a few seconds, before the recovery deadline; runner PID exited and the library showed zero active machines |

The initial HTTP request to `ubuntu.com` timed out. The independent
`example.com` check passed; HTTPS was not separately verified. Automated
modifier-key injection remained unreliable (for example, Ctrl+C and colon
input); ordinary lowercase commands and pointer input worked. This is not a
complete keyboard compatibility test.

At 16:29, the virtual disk occupied approximately **9.59 GB** of host storage
and **132.06 GB** remained free on the host (decimal values). The VM was left
stopped after the successful normal shutdown, with installer boot disabled.

**Result: installation, installed-disk boot, login, NAT internet access, and
normal installed-system shutdown passed in this control test.** This does not
establish the cause of the Ubuntu 26.04.1 failures or prove long-term stability.
The control changed the distribution image and installer environment as well
as the kernel; no MacVM source fix is claimed from this result.
