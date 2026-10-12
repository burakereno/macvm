import Foundation
import Virtualization
import MacVMCore
import GuestControl

enum GuestToolsConnectionError: LocalizedError {
    case notConnected, timedOut, unavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MacVM Guest Tools are not connected to this macOS machine."
        case .timedOut: return "MacVM Guest Tools did not respond."
        case .unavailable: return "Restart this machine to enable MacVM Guest Tools."
        }
    }
}

@MainActor
final class GuestShutdownClient {
    private var completion: ((Result<Void, Error>) -> Void)?
    private var started = false
    private var deadline: DispatchWorkItem?

    func request(on machine: VZVirtualMachine, completion: @escaping (Result<Void, Error>) -> Void) {
        connect(on: machine, shutdown: true, completion: completion)
    }

    /// Opening and closing the private port is deliberately read-only: never
    /// send SHUTDOWN while checking availability. Also works with existing 0.1 tools.
    func checkConnection(on machine: VZVirtualMachine, requireClipboard: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        connect(on: machine, shutdown: false, requireClipboard: requireClipboard, completion: completion)
    }

    func cancel() {
        completion = nil
        deadline?.cancel()
        deadline = nil
    }

    private func connect(on machine: VZVirtualMachine, shutdown: Bool, requireClipboard: Bool = false,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard !started else { return }
        started = true
        self.completion = completion
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            finish(.failure(GuestToolsConnectionError.unavailable))
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(GuestToolsConnectionError.timedOut))
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        device.connect(toPort: GuestControl.port) { [weak self] result in
            guard let self, self.completion != nil else {
                if case .success(let connection) = result { connection.close() }
                return
            }
            switch result {
            case .failure:
                self.finish(.failure(GuestToolsConnectionError.notConnected))
            case .success(let connection):
                guard shutdown || requireClipboard else {
                    connection.close()
                    self.finish(.success(()))
                    return
                }
                let descriptor = dup(connection.fileDescriptor)
                connection.close()
                guard descriptor >= 0 else {
                    self.finish(.failure(VMError.message("Could not open the Guest Tools connection.")))
                    return
                }
                // Keep blocking socket I/O off the VM's main queue.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    defer { close(descriptor) }
                    let outcome: Result<Void, Error> = Result {
                        GuestControl.configure(descriptor)
                        if requireClipboard {
                            try GuestControl.writeFrame(GuestControl.capabilities, to: descriptor)
                            guard try GuestControl.readFrame(from: descriptor) == GuestControl.supportedCapabilities else {
                                throw GuestToolsConnectionError.notConnected
                            }
                            return
                        }
                        try GuestControl.writeFrame(GuestControl.shutdown, to: descriptor)
                        let reply = try GuestControl.readFrame(from: descriptor)
                        if reply == GuestControl.sessionActive {
                            throw VMError.message("A user may still be signed in to this Mac. Sign in and use Shut Down again so macOS can save open work.")
                        }
                        guard reply == GuestControl.accepted else {
                            throw VMError.message("macOS could not begin shutdown. Check the guest for a confirmation or use its Apple menu.")
                        }
                    }
                    Task { @MainActor [weak self] in self?.finish(outcome) }
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel()
        deadline = nil
        completion(result)
    }
}
