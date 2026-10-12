# Display and full-screen validation — 11 October 2026

Host: Apple silicon, Retina display, macOS 27.0.1. Guest: existing installed
Ubuntu 26.04.1, 2 CPUs, 8 GiB memory, 64 GiB disk.

## Display quality

- The prior host-sized pixel resolution with Ubuntu at 100% made icons and
  controls small. Linux virtio scanout configuration exposes pixel dimensions,
  unlike the macOS configuration which also exposes pixels-per-inch.
- The initial Display menu could request a resolution based on the window's logical
  point size. On this Retina screen it requested 1728 × 902 in the window,
  and 1728 × 1032 in full screen. Ubuntu adopted the new size and made the UI
  larger, but the user correctly reported softness from bitmap enlargement.
- The final implementation uses automatic full pixel density for every guest.
  The Display toolbar/menu, lower-resolution mode, configuration property, and
  custom resizing code were removed after user feedback. Existing JSON packages
  with the unused `displayScaling` key still load (Codable ignores unknown keys).
- The Ubuntu VM was switched back to full Retina resolution.
  Its guest settings showed 3456 × 1804 at 100%. Changing the guest's own Scale
  to 200%, applying, and keeping the changes retained that resolution while
  enlarging the desktop and rendering text/icons sharply.
- The guest's 200% scale persisted across a cold boot. The updated runner was
  launched against the existing package and its toolbar no longer has Display.

This sets the existing Ubuntu account's display preference through its UI.
MacVM does not install a guest agent, automatically configure every Linux
desktop, or claim that all legacy applications support HiDPI. Installer/login
display preferences can differ from the logged-in desktop. Non-Retina and
mixed-DPI external displays have not been tested.

## Full screen

- The VM window explicitly supports native macOS full screen.
- Toolbar and Window menu actions switch between Enter Full Screen and
  Exit Full Screen. The toolbar stays visible in full screen. Repeated toolbar
  entry/exit passed on Ubuntu, including with native resolution and 200% scale.
- The first window-level Control–Command–F handler failed, including on the
  user's physical keyboard. It was replaced by an application-local event
  monitor registered after the virtual display, restricted to the active VM
  window. Key repeat is consumed, and Escape stays with the guest.
- The updated shortcut entered full screen in automation. The user explicitly
  confirmed that the shortcuts now work. The visible exit button remains a
  separate exit path; transitions are guarded against overlapping requests.

## Build

- Optimized build, launch, strict Developer ID signatures and publisher checks
  passed. Eleven XCTest cases passed after removing the two tests for the
  deleted display mode feature.
- Logs: `.build/display-simplification-build.log` and
  `.build/display-simplification-tests.log`.

## API references

- [Apple: automatic display reconfiguration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview/automaticallyreconfiguresdisplay)
- [Apple: guest display resize requests](https://developer.apple.com/documentation/virtualization/vzgraphicsdisplay/reconfigure(sizeinpixels:)) — guests may ignore a request.
- [GNOME: display resolution and scale](https://help.gnome.org/gnome-help/look-resolution.html)
- [Microsoft: native resolution and display scaling](https://support.microsoft.com/en-in/help/3025083/windows-scaling-issues-for-high-dpi-devices) — Windows is outside this app version.
