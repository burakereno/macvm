import AppKit
import Virtualization
import GuestControl

/// Text-only clipboard synchronization is opt-in and scoped to the foreground
/// guest window. Neither clipboard contents nor errors are logged.
@MainActor
final class GuestClipboardController {
    private var nextCheck: TimeInterval = 0
    private var busy = false
    private var hostCount: Int?
    private var guestCount: Int?
    private weak var activeMachine: VZVirtualMachine?

    func poll(machine: VZVirtualMachine, enabled: Bool, window: NSWindow?, running: Bool) {
        guard enabled, running, NSApp.isActive, NSApp.keyWindow === window else { return }
        activeMachine = machine
        let now = ProcessInfo.processInfo.systemUptime
        guard !busy, now >= nextCheck, let device = machine.socketDevices.first as? VZVirtioSocketDevice else { return }
        nextCheck = now + 1
        let pasteboard = NSPasteboard.general
        let capturedHostCount = pasteboard.changeCount
        // Initial connection never uploads existing host contents automatically.
        let sending = hostCount != nil && hostCount != capturedHostCount
        let text = sending ? pasteboard.string(forType: .string) : nil
        guard (text?.utf8.count ?? 0) < GuestControl.maxClipboardBytes - 256 else { return }
        busy = true
        device.connect(toPort: GuestControl.port) { [weak self] result in
            guard let self else { if case .success(let connection) = result { connection.close() }; return }
            guard case .success(let connection) = result else { self.busy = false; self.nextCheck = now + 5; return }
            let descriptor = dup(connection.fileDescriptor); connection.close()
            guard descriptor >= 0 else { self.busy = false; return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { close(descriptor) }
                let reply = try? Self.exchange(descriptor, text: text)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let pasteboard = NSPasteboard.general
                    self.busy = false
                    if reply == nil { self.nextCheck = ProcessInfo.processInfo.systemUptime + 10 }
                    guard let reply, self.activeMachine?.state == .running, NSApp.isActive, NSApp.keyWindow === window,
                          pasteboard.changeCount == capturedHostCount else { return }
                    if !sending, self.guestCount != nil, self.guestCount != reply.changeCount,
                       let text = reply.text {
                        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                    }
                    self.hostCount = pasteboard.changeCount
                    self.guestCount = reply.changeCount
                }
            }
        }
    }
    nonisolated private static func exchange(_ descriptor: Int32, text: String?) throws -> GuestControl.ClipboardMessage {
        GuestControl.configure(descriptor)
        try GuestControl.writeFrame(GuestControl.clipboard, to: descriptor)
        try GuestControl.writeClipboard(.init(text: text), to: descriptor)
        return try GuestControl.readClipboard(from: descriptor)
    }
}
