import Foundation
import Darwin
import MacVMCore

/// Used on one serial worker queue. No network listener, shell, or HMP text.
public final class QMPClient {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var requestID = 0
    public init(socketURL: URL) throws {
        let path = Array(socketURL.path.utf8) + [0]
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VMError.message("QMP socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError.message("Cannot create QMP socket.") }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(); throw VMError.message("Cannot connect to the Windows engine.") }
        do {
            let greeting = try readMessage()
            guard greeting["QMP"] != nil else { throw VMError.message("Invalid QMP greeting.") }
            _ = try execute("qmp_capabilities")
        } catch { close(); throw error }
    }

    deinit { close() }
    public func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    @discardableResult
    public func execute(_ command: String, arguments: [String: Any] = [:]) throws -> Any {
        guard fd >= 0 else { throw VMError.message("The Windows engine disconnected.") }
        requestID += 1
        let value: [String: Any] = ["execute": command, "arguments": arguments, "id": requestID]
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VMError.message("Cannot write to the Windows engine.") }
                offset += count
            }
        }
        // Events can arrive between request and response; they are not replies.
        for _ in 0..<1024 {
            let message = try readMessage()
            if message["event"] != nil { continue }
            guard message["id"] as? Int == requestID else { throw VMError.message("QMP response does not match the request.") }
            if let error = message["error"] as? [String: Any] {
                throw VMError.message(error["desc"] as? String ?? "Windows engine command failed.")
            }
            guard let result = message["return"] else { throw VMError.message("Malformed QMP response.") }
            return result
        }
        throw VMError.message("Too many Windows engine events without a response.")
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw VMError.message("Invalid QMP JSON object.")
                }
                return object
            }
            guard buffer.count < 1024 * 1024 else { throw VMError.message("Windows engine response exceeds the size limit.") }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw VMError.message(count == 0 ? "The Windows engine disconnected." : "The Windows engine response timed out.") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
