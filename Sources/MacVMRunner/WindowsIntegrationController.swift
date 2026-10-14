import AppKit
import WindowsPrototypeCore
import MacVMCore

@MainActor
final class WindowsIntegrationController {
    let agent = WindowsAgentClient()
    private var folders: WindowsFolderSharing?
    private var availability = GuestToolsAvailability()
    private var hostCount: Int?
    private var nextClipboard: TimeInterval = 0
    private var pendingHostText: String?
    private var hasPendingClipboard = false
    private var connected = false
    var onReminder: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private weak var window: NSWindow?
    private var clipboardEnabled = false
    private var running = false
    private var sessionInForeground = true
    private var hostAwake = true
    private var screenLocked = false
    private var sessionActive: Bool { sessionInForeground && hostAwake && !screenLocked }
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []

    func start(runtime: URL, record: VirtualMachineRecord, window: NSWindow?) {
        self.window = window; clipboardEnabled = record.clipboardSharingEnabled == true
        hostCount = NSPasteboard.general.changeCount
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionInForeground = false
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionInForeground = true
                    case NSWorkspace.willSleepNotification: self.hostAwake = false
                    case NSWorkspace.didWakeNotification: self.hostAwake = true
                    default: break
                    }
                    self.resetClipboardBaseline()
                }
            })
        }
        // A display wake is not an unlock. Keep these states independent so
        // waking a locked Mac cannot make its clipboard eligible again.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = locked; self?.resetClipboardBaseline() }
            })
        }
        agent.onConnected = { [weak self] value in
            guard let self else { return }; self.connected = value
            self.onStatus?(value ? "Windows Tools connected" : "Checking Windows Tools…")
        }
        agent.onClipboard = { [weak self] text in
            guard let self, self.eligible else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            self.hostCount = pasteboard.changeCount
            self.pendingHostText = nil; self.hasPendingClipboard = false
        }
        agent.start(runtime.appendingPathComponent("agent.sock"))
        let folders = WindowsFolderSharing(folders: record.sharedFolders ?? [])
        self.folders = folders; folders.start(runtime.appendingPathComponent("webdav.sock"))
    }
    private var eligible: Bool { sessionActive && clipboardEnabled && running && NSApp.isActive && NSApp.keyWindow === window }
    private func resetClipboardBaseline() {
        hostCount = NSPasteboard.general.changeCount
        pendingHostText = nil; hasPendingClipboard = false
        agent.setEligible(false)
    }
    func poll(running: Bool, installing: Bool) {
        self.running = running
        if running && !installing {
            availability.record(connected: connected, at: ProcessInfo.processInfo.systemUptime)
            if availability.shouldRemind { availability.markReminderShown(); onReminder?() }
        } else { availability.suspend() }
        let active = eligible
        agent.setEligible(active)
        let now = ProcessInfo.processInfo.systemUptime
        guard sessionActive, clipboardEnabled, running, now >= nextClipboard else { return }; nextClipboard = now + 0.75
        let pasteboard = NSPasteboard.general, count = pasteboard.changeCount
        if hostCount != nil && hostCount != count {
            let text = pasteboard.string(forType: .string)
            pendingHostText = text
            hasPendingClipboard = (text?.utf8.count ?? 0) <= WindowsAgentClient.maximumTextBytes
        }
        hostCount = count
        // Copying in a host app happens before focusing the VM. Remember that
        // new copy locally, but send it only once this VM is foreground.
        if active && connected && hasPendingClipboard {
            agent.offerClipboard(pendingHostText)
            pendingHostText = nil; hasPendingClipboard = false
        }
    }
    var status: String { connected ? "Windows Tools connected" : availability.status == .notConnected ? "Windows Tools are not connected" : "Checking Windows Tools…" }
    func stop() {
        agent.stop(); folders?.stop(); folders = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }; lockObservers = []
    }
}
