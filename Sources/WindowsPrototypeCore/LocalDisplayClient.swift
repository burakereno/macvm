import Foundation
import Darwin
import CoreGraphics
import MacVMCore
import OSLog

/// RFB 3.8 over a private Unix socket. No TCP listener, clipboard or file transfer.
/// Protocol: https://www.rfc-editor.org/rfc/rfc6143
public final class LocalDisplayClient {
    private static let log = Logger(subsystem: "com.burakerenoglu.macvm", category: "WindowsDisplay")
    private let reader = DispatchQueue(label: "com.burakerenoglu.macvm.display.read", qos: .userInteractive)
    private let writer = DispatchQueue(label: "com.burakerenoglu.macvm.display.input", qos: .userInteractive)
    private let state = NSLock()
    private var connection: WindowsSocket?
    private var cancelled = false
    private var ready = false
    private var resize = DisplayResize()
    public var onFrame: ((CGImage) -> Void)?
    public var onFailure: ((String) -> Void)?
    public init() {}

    public func start(socketURL: URL) {
        reader.async { [self] in
            do {
                let socket = try WindowsSocket(url: socketURL)
                state.lock(); connection = socket; let stop = cancelled; state.unlock()
                if stop { socket.cancel(); return }
                defer { socket.cancel(); state.lock(); connection = nil; ready = false; state.unlock() }
                guard try socket.read(12) == Data("RFB 003.008\n".utf8) else { throw invalid() }
                try socket.write(Data("RFB 003.008\n".utf8))
                let count = Int(try socket.read(1)[0])
                guard count > 0, try socket.read(count).contains(1) else { throw invalid() }
                try socket.write(Data([1]))
                guard try socket.read(4) == Data([0,0,0,0]) else { throw invalid() }
                try socket.write(Data([1]))
                let header = try socket.read(24)
                var frame = try DisplayFramebuffer(width: Int(header.u16(0)), height: Int(header.u16(2)))
                let nameLength = Int(header.u32(20))
                guard nameLength <= 4096 else { throw invalid() }
                _ = try socket.read(nameLength)
                // 32-bit little-endian BGRX, 24-bit true color.
                try socket.write(Data([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0]))
                // Raw, ExtendedDesktopSize (-308), and legacy DesktopSize (-223).
                try socket.write(Data([2,0,0,3,0,0,0,0,255,255,254,204,255,255,255,33]))
                state.lock(); ready = true; state.unlock()
                try request(socket, frame: frame, incremental: false)
                while !isCancelled {
                    let kind = try socket.read(1)[0]
                    switch kind {
                    case 0:
                        let head = try socket.read(3)
                        let count = Int(head.u16(1))
                        guard count <= 8192 else { throw invalid() }
                        var resized = false
                        var layoutChanged = false
                        for _ in 0..<count {
                            let rect = try socket.read(12)
                            let x = Int(rect.u16(0)), y = Int(rect.u16(2)), w = Int(rect.u16(4)), h = Int(rect.u16(6))
                            switch Int32(bitPattern: rect.u32(8)) {
                            case 0:
                                try frame.validate(x: x, y: y, width: w, height: h)
                                try frame.apply(x: x, y: y, width: w, height: h, pixels: socket.read(w * h * 4))
                            case -223:
                                frame = try DisplayFramebuffer(width: w, height: h); resized = true
                            case -308:
                                let screens = Int(try socket.read(4)[0])
                                let layout = try socket.read(screens * 16)
                                Self.log.notice("Layout: \(w)x\(h), reason \(x), status \(y), screens \(screens)")
                                if DisplayResize.acceptsLayout(reason: x, status: y) {
                                    if w != frame.width || h != frame.height {
                                        frame = try DisplayFramebuffer(width: w, height: h); resized = true
                                    }
                                    // This runner exposes one monitor. Preserve the server's ID/flags.
                                    if screens == 1 {
                                        state.lock()
                                        resize.receivedLayout(id: layout.u32(0), flags: layout.u32(12), width: w, height: h)
                                        state.unlock()
                                        layoutChanged = true
                                    }
                                }
                            default: throw invalid()
                            }
                        }
                        if count > 0, let image = frame.image() {
                            // Backpressure: retain at most one delivered frame, not an unbounded UI queue.
                            DispatchQueue.main.sync { if !self.isCancelled { self.onFrame?(image) } }
                        }
                        try request(socket, frame: frame, incremental: !resized)
                        if layoutChanged { sendResize() }
                    case 2: break // bell
                    case 3:
                        let length = Int(try socket.read(7).u32(3))
                        guard length <= 1_048_576 else { throw invalid() }
                        _ = try socket.read(length) // never put guest text on the host clipboard
                    default: throw invalid()
                    }
                }
            } catch {
                if !isCancelled { DispatchQueue.main.async { self.onFailure?(error.localizedDescription) } }
            }
        }
    }

    public func resizeDisplay(to size: DisplaySize) {
        Self.log.notice("Viewport: \(size.width)x\(size.height)")
        state.lock(); resize.desired = size; state.unlock()
        sendResize()
    }
    private func sendResize() {
        writer.async { [self] in
            state.lock()
            let socket = ready && !cancelled ? connection : nil
            let packet = socket == nil ? nil : resize.request()
            state.unlock()
            if let packet {
                Self.log.notice("Request: \(packet.u16(2))x\(packet.u16(4))")
                try? socket?.write(packet)
            }
        }
    }
    public func stop() {
        state.lock(); cancelled = true; let socket = connection; state.unlock(); socket?.cancel()
    }
    public func key(_ keysym: UInt32, down: Bool) {
        var data = Data([4, down ? 1 : 0, 0, 0]); data.appendBE(keysym); send(data)
    }
    public func pointer(x: Int, y: Int, buttons: UInt8) {
        var data = Data([5, buttons]); data.appendBE(UInt16(clamping: x)); data.appendBE(UInt16(clamping: y)); send(data)
    }
    private var isCancelled: Bool { state.lock(); defer { state.unlock() }; return cancelled }
    private func send(_ data: Data) {
        writer.async { [self] in
            state.lock(); let socket = ready && !cancelled ? connection : nil; state.unlock()
            try? socket?.write(data)
        }
    }
    private func request(_ socket: WindowsSocket, frame: DisplayFramebuffer, incremental: Bool) throws {
        var data = Data([3, incremental ? 1 : 0, 0,0,0,0]); data.appendBE(UInt16(frame.width)); data.appendBE(UInt16(frame.height))
        try socket.write(data)
    }
    private func invalid() -> VMError { .message("The Windows display sent an unsupported response.") }
}

struct DisplayFramebuffer {
    let width: Int
    let height: Int
    private(set) var pixels: Data
    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
            throw VMError.message("Invalid Windows display size.")
        }
        self.width = width; self.height = height; pixels = Data(count: width * height * 4)
    }
    func validate(x: Int, y: Int, width w: Int, height h: Int) throws {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x <= width, y <= height, w <= width - x, h <= height - y else {
            throw VMError.message("Invalid Windows display rectangle.")
        }
    }
    mutating func apply(x: Int, y: Int, width w: Int, height h: Int, pixels source: Data) throws {
        try validate(x: x, y: y, width: w, height: h)
        guard source.count == w * h * 4 else { throw VMError.message("Incomplete Windows display rectangle.") }
        if w == 0 || h == 0 { return }
        pixels.withUnsafeMutableBytes { target in
            source.withUnsafeBytes { input in
                for row in 0..<h {
                    memcpy(target.baseAddress!.advanced(by: ((y + row) * width + x) * 4), input.baseAddress!.advanced(by: row * w * 4), w * 4)
                }
            }
        }
    }
    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

final class WindowsSocket {
    private let fd: Int32
    private let writeLock = NSLock()
    init(url: URL) throws {
        var address = sockaddr_un(); let path = Array(url.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VMError.message("Display socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError.message("Cannot create the display socket.") }
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 { Darwin.close(fd); throw VMError.message("Cannot connect to the Windows display.") }
    }
    deinit { Darwin.close(fd) }
    func cancel() { Darwin.shutdown(fd, SHUT_RDWR) }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= 67_108_864 else { throw VMError.message("Windows display response is too large.") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw VMError.message("Windows display disconnected.") }
                offset += n
            }
        }
        return data
    }
    func write(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw VMError.message("Cannot send Windows display input.") }
                offset += n
            }
        }
    }
}
private extension Data {
    func u16(_ offset: Int) -> UInt16 { (UInt16(self[offset]) << 8) | UInt16(self[offset + 1]) }
    func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[offset + $1]) } }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
