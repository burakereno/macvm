# Windows 0.3 acceptance — 2026-10-14

Production code: `5142298f764c7e111b13ca723d395747a06bb0bb`.
Signed validation build: [Actions 38560466720](https://github.com/burakereno/macvm/actions/runs/38560466720).
The final CI and local artifact trust/launch/rollback checks passed.
[MacVM 0.3.0](https://github.com/burakereno/macvm/releases/tag/v0.3.0) is public.
The release tag points to the exact verified production commit above; subsequent
acceptance documentation changes do not alter the packaged app.

## Fresh guest

A new Windows 11 ARM Installation Test was created through the production wizard
at `8C45ADF3-1200-4AD0-B9CF-028BB7011607.macvm`, with 4 CPUs, 8 GB RAM,
a 128 GB QCOW2 disk and its own TPM/Secure Boot variables. The original Windows
VM was preserved and remains stopped. The host is Apple silicon, 14 cores,
24 GB RAM, macOS 27.0.1.

Microsoft's English ARM64 26300.9457 ISO was downloaded to Downloads; its SHA-256
was `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c`.
The Microsoft page's language/checksum-table discrepancy is retained as a
limitation; no English table-row match is claimed. Installation uses the normal
Windows 11 Pro work/school → Domain join local-account flow. The user accepted
the licence and entered the password/recovery information. No hardware,
network, UAC, activation or security checks were bypassed.

## Observed acceptance

| Area | Actual result |
| --- | --- |
| Installation | Fresh Setup/OOBE completed and the desktop opened; installation ISO was subsequently ejected and disk-only boot passed. |
| Portable engine | QEMU/TPM runtime mappings contained no Homebrew libraries. All 35 bundled Mach-O files passed exact hashes, publisher signatures and loader-relative dependency checks; system-only PATH disk/TPM tests passed. |
| Tools | Source-built ARM64 clipboard/folder helpers and signed network/serial/GPU drivers installed. The Microsoft ARM64 VC runtime signature and licence were checked. Matching helper receipts, 18 binaries and source archives were verified. |
| Display | Windows 200% scale; 2560×1664 window resolution and 3456×2064 full-screen resolution. Button and Control–Command–F entry/exit passed; resolution returned after exit. No old letterboxing. |
| Audio | Built-in Windows High Definition Audio driver selected; the user confirmed both stereo speaker test sounds on the Mac. |
| Clipboard | Distinct test text copied host → Windows and Windows → host, unchanged. An exclusively created TextEdit document was used; no existing user clipboard contents were transmitted. |
| Folder scope | Explorer listed exactly the two selected folders at `\\localhost@9843\DavWWWRoot`. Read-only file content opened correctly. |
| Writable folder | Explorer created a directory; a Notepad edit saved into the selected host file with the exact expected appended text. |
| Read-only folder | Directory creation failed. After the metadata correction, a fresh file's Properties showed Read-only and Notepad refused overwrite with “This file is set to read-only.” Actual host bytes remained unchanged. |
| Lifecycle | Toolbar pause and Control–Command–P resume passed. Normal toolbar shutdown passed repeatedly, including after the final folder test; Runner/WindowsEngine processes exited and VM disks remained intact. |
| Media cleanup | Source ISO and copied Installer.iso were removed through Installation Files, preserving the Windows disk. The user approved permanent deletion of the remaining disposable ISO at action time. |

## Findings incorporated

The setup/recovery display is retained independently of the installer ISO.
VNC is explicitly bound to the named VirtIO GPU or recovery display, avoiding
device-order dependence. Pause uses Control–Command–P so Windows' Win–P remains
available. Physical key/modifier handling was corrected and regression-tested.

Tools installation requires Windows' actual **Restart** command after its final
step. An earlier shutdown/start retained the obsolete framebuffer state through
Fast Startup. The final restart produced the correct VirtIO desktop; instructions
in the installer, runtime guide, Settings and README now explain this sequence.

Read-only WebDAV mutations were already denied by the host, but Notepad initially
reported a cached edit as saved. PROPFIND now advertises Windows read-only
attributes as well. A new uncached file produced the expected visible overwrite
error in the final live test. Unit tests assert both read-only and writable flags.

Clipboard sharing is opt-in, text-only and restricted to the active VM and host
session. Selected-folder WebDAV uses a private virtio channel, no host TCP
listener, descriptor-relative no-follow file operations and bounded uploads.
Source/notice archives and pinned helper build recipes accompany distribution.

## Verification and limits

- Local native suites: 58 MacVMCore and 25 Windows tests, zero failures.
- Final CI: all 83 tests, source collection, portable engine, app/pkg/DMG strict
  signatures, exact Team 66K3EFBVB6, hardened runtime, notarization, stapling,
  Gatekeeper and update manifest passed.
- Updater audit: zero issues, zero warnings. The production installer accepted the
  notarized 0.3.0 DMG, replaced an isolated app target, launched the real app and
  received its confirmation. A deliberately missing confirmation stopped that
  launch, restored and relaunched the original executable. Workspace, mount and
  staging cleanup passed; the user's installed app was not replaced by this test.
- Local DMG, mounted app and macOS Guest Tools package passed signatures,
  exact publisher identity, staple and Gatekeeper assessment. The DMG SHA-256
  matched its update manifest: `ed68e1d5f7dd8b313f42648bde95b760167c9fbd2e400be1b42419fcc0473ab0`.
- Storage-error pause handling and independent clipboard sleep/lock state are
  covered in code/tests. A controlled live host-lock clipboard matrix and guest
  storage-failure injection were not performed. They are not claimed as passed.
- Windows GPU is display-only. Accelerated 3D, snapshots, disk resizing and file
  drag and drop are not included. Other host hardware/extended stress were not exercised.

- Normal Finder DMG opening showed the configured app/Applications placement and
  complete install hint. The copied release app opened locally and About MacVM
  confirmed version 0.3.0 (15).

- All four public assets returned HTTP 200; the latest-release redirect selected
  v0.3.0 and the public manifest matched the verified DMG. The actual 0.3.0 app
  reported “MacVM is up to date” through its manual update UI. GitHub upload
  digests matched every local asset before publication.

## Cleanup

The fresh and original Windows VM disks remain intact and stopped. Test shared
folder references were removed through Machine Settings. Owned source build
extractions, source caches, old validation downloads, clipboard document and
share fixtures were removed. Existing user downloads and other VM disks were
preserved. The final DMG, manifest and macOS Guest Tools installer remain in
`~/Downloads/MacVM-0.3.0`. The large local source archive was removed after its
public asset was verified; matching sources remain available in the release.
The notarized release app is open from `dist/MacVM.app`; no VM is running.
