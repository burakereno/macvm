import Foundation
import Carbon
import SystemConfiguration
import OSLog
import GuestControl
import AppKit

/// Runs as a launch agent in both LoginWindow and Aqua sessions, never on the host.
@main
struct GuestApp {
    private static let logger = Logger(subsystem: "com.burakerenoglu.macvm.guest", category: "shutdown")
    private static var shutdownProcess: Process?

    static func main() {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0 else { exit(1) }
        var model = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &model, &length, nil, 0) == 0,
              String(cString: model).hasPrefix("VirtualMac") else {
            fputs("MacVM Guest Tools only run inside an Apple virtual machine.\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.contains("--check") { return }
        DispatchQueue.global(qos: .utility).async { serve() }
        CFRunLoopRun()
    }

    private static var isActiveSession: Bool {
        var uid: uid_t = 0
        // The console user may be absent before login. Only the system-owned
        // LoginWindow agent may serve in that state, never a stale Aqua session.
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        return GuestControl.isActiveSession(consoleUser: name, consoleUID: uid, processUID: geteuid())
    }

    private static func serve() {
        while true {
            guard isActiveSession else { Thread.sleep(forTimeInterval: 1); continue }
            let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
            guard listener >= 0 else { Thread.sleep(forTimeInterval: 2); continue }
            var address = sockaddr_vm()
            address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
            address.svm_family = sa_family_t(AF_VSOCK)
            address.svm_cid = VMADDR_CID_ANY
            address.svm_port = GuestControl.port
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
                }
            }
            guard bound == 0, listen(listener, 2) == 0 else {
                close(listener); Thread.sleep(forTimeInterval: 2); continue
            }
            while isActiveSession {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 1000) > 0 else { continue }
                var peer = sockaddr_vm()
                var size = socklen_t(MemoryLayout<sockaddr_vm>.size)
                let client = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &size) }
                }
                guard client >= 0 else { continue }
                // Only the owning host can request shutdown; guest-local peers are rejected.
                if peer.svm_cid == VMADDR_CID_HOST { handle(client) }
                close(client)
            }
            close(listener)
        }
    }

    private static func handle(_ descriptor: Int32) {
        GuestControl.configure(descriptor)
        do {
            let command = try GuestControl.readFrame(from: descriptor)
            guard command == GuestControl.shutdown || command == GuestControl.clipboard || command == GuestControl.capabilities else { return }
            guard isActiveSession else {
                try GuestControl.writeFrame(GuestControl.inactive, to: descriptor)
                return
            }
            if command == GuestControl.capabilities {
                try GuestControl.writeFrame(GuestControl.supportedCapabilities, to: descriptor)
                return
            }
            if command == GuestControl.clipboard {
                guard geteuid() >= 500 else { return }
                let message = try GuestControl.readClipboard(from: descriptor)
                let reply = DispatchQueue.main.sync { () -> GuestControl.ClipboardMessage in
                    let pasteboard = NSPasteboard.general
                    if let text = message.text {
                        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                    }
                    return GuestControl.ClipboardMessage(text: pasteboard.string(forType: .string), changeCount: pasteboard.changeCount)
                }
                try GuestControl.writeClipboard(reply, to: descriptor)
                return
            }
            let result = DispatchQueue.main.sync { requestShutdown() }
            try GuestControl.writeFrame(result, to: descriptor)
        } catch GuestControl.WireError.disconnected {
            // A connection-only presence probe closes without sending a frame.
        } catch { logger.error("Guest control request could not be decoded or completed") }
    }

    private static func requestShutdown() -> String {
        if geteuid() == 0 { return requestPreloginShutdown() }
        // Apple's documented loginwindow event preserves application cancellation
        // and unsaved-document prompts. No shutdown shell command or hard power-off.
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        guard let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber,
                                                 bytes: &psn, length: MemoryLayout.size(ofValue: psn)) else { return GuestControl.failed }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEShutDown),
                                          targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try event.sendEvent(options: [.noReply, .canInteract], timeout: 3)
            logger.info("Sent normal shutdown request to loginwindow")
            return GuestControl.accepted
        } catch {
            logger.error("loginwindow refused shutdown: \(error.localizedDescription, privacy: .public)")
            return GuestControl.failed
        }
    }

    private static func requestPreloginShutdown() -> String {
        var uid: uid_t = 0
        let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        guard GuestControl.mayShutDownWithoutSession(
            consoleUser: user, consoleUID: uid, processUID: geteuid(),
            hasUserSessions: GuestControl.loggedInUserSessionsExist()
        ) else {
            logger.error("Pre-login shutdown refused: a user session exists or its state is unknown")
            return GuestControl.sessionActive
        }
        // QA1134 documents the system shutdown command when no GUI users are
        // logged in. Fixed executable/arguments: no shell or host-supplied input.
        // launchd shuts down services and flushes disks; this is not VM force stop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        process.arguments = ["-h", "now"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            shutdownProcess = process
            logger.notice("Started normal pre-login system shutdown")
            return GuestControl.accepted
        } catch {
            logger.error("Could not start pre-login shutdown: \(error.localizedDescription, privacy: .public)")
            return GuestControl.failed
        }
    }
}
