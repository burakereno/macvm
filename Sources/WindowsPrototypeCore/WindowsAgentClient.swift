import Foundation
import MacVMCore

/// Standard SPICE agent messages transported directly over a private virtio
/// serial socket. Only text clipboard capabilities are offered; no commands.
public final class WindowsAgentClient {
    public static let maximumTextBytes = 1_048_576
    private let queue = DispatchQueue(label: "macvm.windows.agent", qos: .utility)
    private let writer = DispatchQueue(label: "macvm.windows.agent.write", qos: .utility)
    private let lock = NSLock()
    private let messageWriteLock = NSLock()
    private var socket: WindowsSocket?
    private var stopped = false
    private var eligible = false
    private var hostText: String?
    private var connectedAt: TimeInterval = 0
    public var onConnected: ((Bool) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public init() {}

    public func start(_ url: URL) {
        queue.async { [self] in
            while !isStopped {
                do {
                    let connection = try WindowsSocket(url: url)
                    lock.lock(); socket = connection; connectedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
                    defer { connection.cancel(); lock.lock(); socket = nil; lock.unlock(); notify(false) }
                    try write(type: 6, data: capabilities(request: true), socket: connection)
                    var buffers: [UInt32: Data] = [:]
                    while !isStopped {
                        let header = try connection.read(8)
                        let port = header.le32(0), length = Int(header.le32(4))
                        guard [1, 2].contains(port), length > 0, length <= 2048 else { throw invalid() }
                        buffers[port, default: Data()].append(try connection.read(length))
                        guard buffers[port]!.count <= Self.maximumTextBytes + 24 else { throw invalid() }
                        while let message = try Self.takeMessage(from: &buffers[port]!) { try receive(message, connection) }
                    }
                } catch { if !isStopped { Thread.sleep(forTimeInterval: 1) } }
            }
        }
    }
    public func setEligible(_ value: Bool) {
        lock.lock(); eligible = value; if !value { hostText = nil }; lock.unlock()
    }
    public func offerClipboard(_ text: String?) {
        lock.lock(); hostText = text; let active = eligible; lock.unlock()
        guard active else { return }
        send(type: text == nil ? 9 : 7, data: text == nil ? Data() : .littleEndian(1))
    }
    public func stop() { lock.lock(); stopped = true; let connection = socket; lock.unlock(); connection?.cancel() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func send(type: UInt32, data: Data) {
        writer.async { [self] in
            lock.lock(); let connection = socket; let active = eligible; lock.unlock()
            guard active, let connection else { return }
            do { try write(type: type, data: data, socket: connection) } catch { connection.cancel() }
        }
    }
    private func capabilities(request: Bool) -> Data {
        // Clipboard by demand, text, and CRLF. No file transfer or monitor changes.
        let mask: UInt32 = (1 << 3) | (1 << 5) | (1 << 9) | (1 << 10) | (1 << 13)
        return Data.littleEndian(request ? 1 : 0) + Data.littleEndian(mask)
    }
    private func notify(_ connected: Bool) { DispatchQueue.main.async { self.onConnected?(connected) } }
    private func receive(_ message: AgentMessage, _ connection: WindowsSocket) throws {
        lock.lock(); let active = eligible; let text = hostText; lock.unlock()
        switch message.type {
        case 6:
            guard message.data.count >= 8 else { throw invalid() }
            if message.data.le32(0) != 0 { try write(type: 6, data: capabilities(request: false), socket: connection) }
            notify(message.data.le32(4) & (1 << 5) != 0)
            try write(type: 14, data: .littleEndian(UInt32(Self.maximumTextBytes)), socket: connection)
        case 7:
            guard message.data.count % 4 == 0 else { throw invalid() }
            lock.lock(); let baseline = ProcessInfo.processInfo.systemUptime - connectedAt < 1; lock.unlock()
            guard active, !baseline, stride(from: 0, to: message.data.count, by: 4).contains(where: { message.data.le32($0) == 1 }) else { return }
            try write(type: 8, data: .littleEndian(1), socket: connection)
        case 8:
            guard active, message.data.count == 4, message.data.le32(0) == 1,
                  let text, text.utf8.count <= Self.maximumTextBytes else { return }
            try write(type: 4, data: .littleEndian(1) + Data(text.utf8), socket: connection)
        case 4:
            guard active, message.data.count >= 4, message.data.le32(0) == 1,
                  let text = String(data: message.data.dropFirst(4), encoding: .utf8) else { return }
            DispatchQueue.main.async { self.onClipboard?(text.replacingOccurrences(of: "\r\n", with: "\n")) }
        default: break
        }
    }
    private func write(type: UInt32, data: Data, socket: WindowsSocket) throws {
        guard data.count <= Self.maximumTextBytes + 4 else { throw invalid() }
        // A clipboard message spans several chunks. Keep replies and offers
        // from interleaving chunks of two messages on the same agent port.
        messageWriteLock.lock(); defer { messageWriteLock.unlock() }
        var message = Data.littleEndian(1)
        message.append(Data.littleEndian(type)); message.append(Data(repeating: 0, count: 8))
        message.append(Data.littleEndian(UInt32(data.count))); message.append(data)
        for offset in stride(from: 0, to: message.count, by: 2048) {
            let part = message.subdata(in: offset..<min(offset + 2048, message.count))
            var chunk = Data.littleEndian(1); chunk.append(Data.littleEndian(UInt32(part.count))); chunk.append(part)
            try socket.write(chunk)
        }
    }
    public struct AgentMessage: Equatable { public let type: UInt32; public let data: Data }
    public static func takeMessage(from buffer: inout Data) throws -> AgentMessage? {
        guard buffer.count >= 20 else { return nil }
        guard buffer.le32(0) == 1 else { throw VMError.message("Invalid Windows Tools protocol.") }
        let length = Int(buffer.le32(16))
        guard length <= maximumTextBytes + 4 else { throw VMError.message("Windows clipboard message is too large.") }
        guard buffer.count >= length + 20 else { return nil }
        let result = AgentMessage(type: buffer.le32(4), data: buffer.subdata(in: 20..<20+length))
        buffer = Data(buffer.dropFirst(length + 20)); return result
    }
    private func invalid() -> VMError { .message("Invalid Windows Tools response.") }
}

extension Data {
    func le32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) } }
    func le64(_ offset: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) } }
    static func littleEndian(_ value: UInt32) -> Data { var v = value.littleEndian; return Swift.withUnsafeBytes(of: &v) { Data($0) } }
    static func littleEndian64(_ value: UInt64) -> Data { var v = value.littleEndian; return Swift.withUnsafeBytes(of: &v) { Data($0) } }
}
