import Foundation
import Darwin

/// A private VM socket, never a TCP listener or a general command executor.
public enum GuestControl {
    public static let port: UInt32 = 49201
    public static let shutdown = "MACVM/1 SHUTDOWN"
    public static let accepted = "MACVM/1 ACCEPTED"
    public static let inactive = "MACVM/1 INACTIVE"
    public static let failed = "MACVM/1 FAILED"
    public static let sessionActive = "MACVM/1 SESSION_ACTIVE"
    public static let clipboard = "MACVM/1 CLIPBOARD"
    public static let capabilities = "MACVM/1 CAPABILITIES"
    public static let supportedCapabilities = "MACVM/2 SHUTDOWN,CLIPBOARD"
    public static let maxFrameBytes = 64

    public enum WireError: Error { case disconnected, invalidFrame }

    public struct ClipboardMessage: Codable, Equatable, Sendable {
        public var text: String?
        public var changeCount: Int?
        public init(text: String? = nil, changeCount: Int? = nil) { self.text = text; self.changeCount = changeCount }
    }
    public static let maxClipboardBytes = 1_048_576

    public static func readClipboard(from descriptor: Int32) throws -> ClipboardMessage {
        let header = try readBytes(4, from: descriptor)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maxClipboardBytes else { throw WireError.invalidFrame }
        return try JSONDecoder().decode(ClipboardMessage.self, from: readBytes(Int(length), from: descriptor))
    }
    public static func writeClipboard(_ message: ClipboardMessage, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(message)
        guard data.count <= maxClipboardBytes else { throw WireError.invalidFrame }
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeBytes(header + data, to: descriptor)
    }
    private static func readBytes(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while offset < count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw WireError.disconnected }
                var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let status = poll(&ready, 1, Int32(ceil(remaining * 1000)))
                if status < 0 && errno == EINTR { continue }
                guard status > 0 else { throw WireError.disconnected }
                let received = recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw WireError.disconnected }
                offset += received
            }
        }
        return data
    }
    private static func writeBytes(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WireError.disconnected }
                offset += count
            }
        }
    }

    public static func isActiveSession(consoleUser: String?, consoleUID: uid_t, processUID: uid_t) -> Bool {
        if consoleUser == nil || consoleUser == "loginwindow" { return processUID < 500 }
        return consoleUID >= 500 && consoleUID == processUID
    }

    /// The system shutdown path is permitted only before login, with a complete
    /// session census. A locked desktop or fast-user-switched session must retain
    /// the normal Apple-event path and its unsaved-document cancellation.
    public static func mayShutDownWithoutSession(consoleUser: String?, consoleUID: uid_t,
                                                processUID: uid_t, hasUserSessions: Bool?) -> Bool {
        processUID == 0 && consoleUID == 0 &&
        (consoleUser == nil || consoleUser == "loginwindow") && hasUserSessions == false
    }

    /// Read all login records, including users switched away from the console.
    /// Missing, incomplete, or unreadable accounting data fails closed.
    public static func loggedInUserSessionsExist() -> Bool? {
        setutxent()
        defer { endutxent() }
        var sawBootRecord = false
        while true {
            errno = 0
            guard let record = getutxent()?.pointee else {
                return errno == 0 && sawBootRecord ? false : nil
            }
            if record.ut_type == USER_PROCESS { return true }
            if record.ut_type == BOOT_TIME { sawBootRecord = true }
        }
    }

    public static func configure(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func readFrame(from descriptor: Int32) throws -> String {
        var bytes: [UInt8] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        // The size cap and socket timeout bound malformed/partial requests.
        while bytes.count < maxFrameBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw WireError.disconnected }
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&ready, 1, Int32(ceil(remaining * 1000)))
            if status < 0 && errno == EINTR { continue }
            guard status > 0 else { throw WireError.disconnected }
            var byte: UInt8 = 0
            let count = recv(descriptor, &byte, 1, 0)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw WireError.disconnected }
            if byte == 10 {
                guard let frame = String(bytes: bytes, encoding: .utf8) else { throw WireError.invalidFrame }
                return frame
            }
            bytes.append(byte)
        }
        throw WireError.invalidFrame
    }

    public static func writeFrame(_ frame: String, to descriptor: Int32) throws {
        let bytes = Array((frame + "\n").utf8)
        guard bytes.count <= maxFrameBytes, !frame.contains("\n") else { throw WireError.invalidFrame }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WireError.disconnected }
                offset += count
            }
        }
    }
}
