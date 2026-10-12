import AppKit
import Virtualization
import MacVMCore

/// Owns the runner's non-destructive availability checks and one setup reminder
/// per VM session. It never installs anything or sends a shutdown request.
@MainActor
final class GuestToolsReminderController {
    private weak var window: NSWindow?
    private let machineName: String
    private let openGuide: () -> Void
    var onStatusChange: ((GuestToolsAvailability.Status) -> Void)?
    private var availability = GuestToolsAvailability()
    private var client: GuestShutdownClient?
    private var nextCheck: TimeInterval = 0
    private var alert: NSAlert?

    init(window: NSWindow, machineName: String, openGuide: @escaping () -> Void) {
        self.window = window
        self.machineName = machineName
        self.openGuide = openGuide
    }

    func poll(machine: VZVirtualMachine, system: GuestSystem, phase: RuntimePhase,
              restoring: Bool, busy: Bool, requireClipboard: Bool = false) {
        guard GuestToolsAvailability.shouldCheck(system: system, phase: phase,
                                                restoring: restoring, busy: busy) else {
            suspend()
            return
        }
        if availability.shouldRemind { presentReminder() }
        let now = ProcessInfo.processInfo.systemUptime
        guard client == nil, now >= nextCheck else { return }
        nextCheck = now + 15
        let probe = GuestShutdownClient()
        client = probe
        probe.checkConnection(on: machine, requireClipboard: requireClipboard) { [weak self] result in
            guard let self else { return }
            self.client = nil
            let previous = self.availability.status
            self.availability.record(connected: (try? result.get()) != nil,
                                     at: ProcessInfo.processInfo.systemUptime)
            if previous != self.availability.status { self.onStatusChange?(self.availability.status) }
            if self.availability.status == .connected { self.dismissAlert() }
            if self.availability.shouldRemind { self.presentReminder() }
        }
    }

    func didOpenGuide() {
        availability.markReminderShown()
        dismissAlert()
    }

    /// An explicit failed Shut Down action should offer the guide immediately,
    /// even if the user deferred the automatic reminder earlier in this session.
    func showConnectionFailure(_ error: Error) {
        presentReminder(detail: error.localizedDescription, requestedByUser: true)
    }

    func suspend() {
        client?.cancel()
        client = nil
        nextCheck = 0
        if availability.status != .checking { onStatusChange?(.checking) }
        availability.suspend()
        dismissAlert()
    }

    private func presentReminder(detail: String? = nil, requestedByUser: Bool = false) {
        guard let window, window.attachedSheet == nil, alert == nil,
              requestedByUser || (NSApp.isActive && window.isKeyWindow) else { return }
        availability.markReminderShown()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up Guest Tools for \(machineName)"
        alert.informativeText = (detail ?? "MacVM Guest Tools are not connected yet.") +
            "\n\nInstall or update them inside this macOS machine to use MacVM’s Shut Down button and optional text clipboard sharing. The setup guide shows where to find the included installer.\n\nYou can keep using the machine and set this up later from the Virtual Machine menu."
        alert.addButton(withTitle: "Set Up Guest Tools…")
        alert.addButton(withTitle: "Later")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.alert = nil
            if response == .alertFirstButtonReturn { self.openGuide() }
        }
    }

    private func dismissAlert() {
        if let alert { window?.endSheet(alert.window, returnCode: .cancel) }
        alert = nil
    }
}
