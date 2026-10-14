import Foundation
import Darwin
import zlib

/// Read-only converter for standalone QCOW2 v2/v3 disks with standard L2 entries
/// and deflate compression. Unsupported features fail before publishing a VM.
/// Format: https://www.qemu.org/docs/master/interop/qcow2.html
public enum QCOW2 {
    public static func convert(source: URL, destination: URL, capacity: UInt64) throws {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VMError.message("Cannot open the Ubuntu disk image.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 104 else { throw invalid() }
        let fileSize = UInt64(info.st_size)
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, count <= 4_194_304, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw invalid() }
            try input.seek(toOffset: offset)
            guard let data = try input.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        let header = try read(0, 104)
        let version = number(header, 4, 4)
        let bits = number(header, 20, 4)
        let size = number(header, 24, 8)
        guard number(header, 0, 4) == 0x514649fb, [2, 3].contains(version),
              number(header, 8, 8) == 0, number(header, 16, 4) == 0, number(header, 32, 4) == 0,
              (9...21).contains(bits), size >= 512, size <= capacity, capacity <= 2048 * VMStorage.gib,
              size % 512 == 0, number(header, 60, 4) == 0 else { throw invalid() }
        if version == 3 {
            guard number(header, 72, 8) == 0, number(header, 100, 4) >= 104,
                  number(header, 100, 4) <= (1 << bits) else { throw invalid() }
        }
        let cluster = UInt64(1) << bits
        let entries = cluster / 8
        let clusterCount = (size + cluster - 1) / cluster
        let l1Count = number(header, 36, 4)
        let l1Offset = number(header, 40, 8)
        guard l1Count >= (clusterCount + entries - 1) / entries, l1Count <= 524288,
              l1Offset >= cluster, l1Offset % cluster == 0 else { throw invalid() }
        let l1 = try read(l1Offset, Int(l1Count * 8))
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("Disk.preparing")
        let outFD = open(temporary.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outFD >= 0 else { throw VMError.message("Cannot prepare the Ubuntu disk.") }
        let output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        guard ftruncate(outFD, off_t(capacity)) == 0 else { throw VMError.message("Cannot allocate the Ubuntu disk.") }
        let offsetMask: UInt64 = 0x00ff_ffff_ffff_fe00
        for l1Index in 0..<Int((clusterCount + entries - 1) / entries) {
            try Task.checkCancellation()
            let entry = number(l1, l1Index * 8, 8)
            guard entry & ~(offsetMask | (1 << 63)) == 0 else { throw invalid() }
            let l2Offset = entry & offsetMask
            if l2Offset == 0 { continue }
            guard l2Offset >= cluster, l2Offset % cluster == 0 else { throw invalid() }
            let table = try read(l2Offset, Int(cluster))
            for l2Index in 0..<Int(entries) {
                let guestOffset = (UInt64(l1Index) * entries + UInt64(l2Index)) * cluster
                if guestOffset >= size { break }
                try Task.checkCancellation()
                let descriptor = number(table, l2Index * 8, 8)
                let data: Data
                if descriptor & (1 << 62) != 0 {
                    guard descriptor & (1 << 63) == 0 else { throw invalid() }
                    let shift = 62 - (bits - 8)
                    let compressedOffset = descriptor & ((UInt64(1) << shift) - 1)
                    let sectors = ((descriptor >> shift) & ((UInt64(1) << (bits - 8)) - 1)) + 1
                    let count = sectors * 512 - (compressedOffset & 511)
                    guard compressedOffset >= cluster, count <= cluster + 512 else { throw invalid() }
                    data = try inflate(try read(compressedOffset, Int(count)), count: Int(cluster))
                } else {
                    guard descriptor & ~(offsetMask | (1 << 63) | 1) == 0, version == 3 || descriptor & 1 == 0 else { throw invalid() }
                    let offset = descriptor & offsetMask
                    if descriptor & 1 != 0 || offset == 0 { continue }
                    guard offset >= cluster, offset % cluster == 0 else { throw invalid() }
                    data = try read(offset, Int(cluster))
                }
                if data.allSatisfy({ $0 == 0 }) { continue }
                try output.seek(toOffset: guestOffset)
                try output.write(contentsOf: data.prefix(Int(min(cluster, size - guestOffset))))
            }
        }
        try output.seek(toOffset: 0)
        let mbr = try output.read(upToCount: 512) ?? Data()
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xaa else { throw invalid() }
        try output.synchronize(); try output.close()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func number(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
        data[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func inflate(_ input: Data, count: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        var output = Data(count: count)
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard [Z_STREAM_END, Z_OK, Z_BUF_ERROR].contains(result), stream.total_out == count else { throw invalid() }
        return output
    }
    static func invalid() -> VMError { .message("The Ubuntu disk image is incomplete or uses an unsupported QCOW2 feature. Download the official image again.") }
}
