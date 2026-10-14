import Foundation

/// One guest monitor, expressed in physical pixels, not AppKit points.
public struct DisplaySize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init?(width: Int, height: Int) {
        guard width >= 640, height >= 400, width <= 8192, height <= 8192,
              width * height <= 16_777_216 else { return nil }
        self.width = width; self.height = height
    }
}

struct DisplayResize {
    var desired: DisplaySize?
    private var screen: (id: UInt32, flags: UInt32)?
    private var lastRequested: DisplaySize?

    mutating func receivedLayout(id: UInt32, flags: UInt32, width: Int, height: Int) {
        screen = (id, flags)
        // A boot/login mode change can supersede an earlier request.
        if lastRequested != nil, lastRequested != DisplaySize(width: width, height: height) {
            lastRequested = nil
        }
    }

    mutating func request() -> Data? {
        guard let desired, let screen, desired != lastRequested else { return nil }
        lastRequested = desired
        var data = Data([251, 0])
        data.appendBE(UInt16(desired.width)); data.appendBE(UInt16(desired.height))
        data.append(contentsOf: [1, 0])
        data.appendBE(screen.id); data.appendBE(UInt16(0)); data.appendBE(UInt16(0))
        data.appendBE(UInt16(desired.width)); data.appendBE(UInt16(desired.height)); data.appendBE(screen.flags)
        return data
    }

    /// QEMU's status 4 only means forwarded to the guest. Its dimensions are
    /// not a new framebuffer. Rejections also leave the current image intact.
    static func acceptsLayout(reason: Int, status: Int) -> Bool { reason != 1 || status == 0 }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
