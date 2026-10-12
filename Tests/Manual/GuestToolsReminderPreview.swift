// Compile with the real reminder controller and client for a UI-only smoke check.
// No virtual machine starts and no guest state is changed.
import AppKit
import MacVMCore

@main
struct GuestToolsReminderPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var reminder: GuestToolsReminderController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Guest Tools Reminder — UI Test"
        let button = NSButton(title: "Show Setup Reminder", target: self, action: #selector(showReminder))
        button.frame = NSRect(x: 240, y: 190, width: 220, height: 40)
        window.contentView?.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        reminder = GuestToolsReminderController(window: window, machineName: "macOS Test") { [weak self] in
            self?.window.title = "Guest Tools — Guide Action Received"
        }
        appActivate()
        showReminder()
    }

    private func appActivate() { NSApp.activate(ignoringOtherApps: true) }
    @objc private func showReminder() { reminder.showConnectionFailure(GuestToolsConnectionError.notConnected) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
