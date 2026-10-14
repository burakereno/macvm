# Guest icons — 12 October 2026

The library and runner share vector artwork in `MacVMUI`. Ubuntu uses the
Canonical Circle of Friends SVG embedded in the executable; Apple and generic
Linux use SF Symbols, and Windows uses four panes. No runtime network or
additional resource bundle is needed. The main app's ICNS is unchanged.

Only each runner assigns `NSApplication.applicationIconImage`. Each VM already
has its own process and Dock tile. No on-disk app-icon mutation, per-VM app copy,
private API or bundle-identifier change is needed.

`guestBrand` is optional package metadata, separate from `GuestSystem`. Existing
packages infer a missing value in memory; the next settings save retains it
across renames. New creation identifies the installer before saving the record.
Unknown future brands remain decodable. This adds no Windows backend.

Validation:

- 45 XCTest cases passed, including filename priority, old-package migration,
  rename persistence and future-value compatibility.
- The shared renderer produced inspected 32/64/256 px Dock previews for Ubuntu,
  Windows, macOS and generic Linux (`Tests/Manual/GuestIconPreview.swift`).
- The actual library showed Ubuntu logos for both existing Ubuntu VMs, the
  Apple logo for macOS and the terminal for Alpine.
- The local main/runner bundles passed strict signatures. The main ICNS hash
  remained unchanged and the existing notarized Guest Tools package was retained.
- Ubuntu 26.04.1 and macOS 27.0.1 ran concurrently using the new runner.
  Direct visual automation of the host Dock was unavailable (Dock target timed
  out); the artwork was inspected separately. Windows has no live VM test.

API: https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage

Ubuntu artwork: https://assets.ubuntu.com/v1/ce518a18-CoF-2022_solid+O.svg
