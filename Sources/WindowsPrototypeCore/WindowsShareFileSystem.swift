import Foundation
import Darwin
import MacVMCore

/// All paths are relative to opened directory descriptors. Child symlinks are
/// never followed, including during recursive copy/remove and concurrent renames.
enum WindowsShareFileSystem {
    struct Info {
        let name: String; let directory: Bool; let bytes: Int; let modified: Date
    }
    static func info(_ parent: Int32, _ name: String) throws -> Info {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else { throw VMError.message("Unsupported shared-folder item.") }
        return Info(name: name, directory: value.st_mode & S_IFMT == S_IFDIR, bytes: Int(value.st_size),
                    modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec)))
    }
    static func list(_ parent: Int32, _ name: String) throws -> [Info] {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }; defer { close(fd) }
        return try names(fd).filter { !$0.hasPrefix(".macvm-upload-") }.compactMap { child in
            do { return try info(fd, child) } catch is VMError { return nil }
        }
    }
    static func names(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let directory = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw posix() }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }
            guard result.count < 100_000 else { throw VMError.message("Shared directory has too many entries.") }
        }
        return result
    }
    static func read(_ parent: Int32, _ name: String) throws -> (FileHandle, Int64) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { close(fd); throw VMError.message("Choose a regular shared file.") }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), value.st_size)
    }
    static func put(_ parent: Int32, _ name: String, data: Data, exclusive: Bool) throws {
        let temp = ".macvm-upload-" + UUID().uuidString
        defer { unlinkat(parent, temp, 0) }
        let fd = openat(parent, temp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        let result = exclusive ? renameatx_np(parent, temp, parent, name, UInt32(RENAME_EXCL)) : renameat(parent, temp, parent, name)
        guard result == 0 else { throw posix() }
    }
    static func remove(_ parent: Int32, _ name: String) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
        if value.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posix() }; defer { close(fd) }
            for child in try names(fd) { try remove(fd, child) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix() }
        } else { guard unlinkat(parent, name, 0) == 0 else { throw posix() } }
    }
    static func copy(_ source: Int32, _ name: String, to parent: Int32, as destination: String, exclusive: Bool) throws {
        let temp = ".macvm-upload-" + UUID().uuidString
        defer { try? remove(parent, temp) }
        var remaining = 100_000
        try copyTree(source, name, to: parent, as: temp, remaining: &remaining)
        let result = exclusive ? renameatx_np(parent, temp, parent, destination, UInt32(RENAME_EXCL)) : renameat(parent, temp, parent, destination)
        guard result == 0 else { throw posix() }
    }
    private static func copyTree(_ source: Int32, _ name: String, to parent: Int32, as destination: String, remaining: inout Int) throws {
        remaining -= 1; guard remaining > 0 else { throw VMError.message("Shared-folder copy is too large.") }
        let value = try info(source, name)
        if value.directory {
            let input = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw posix() }; defer { close(input) }
            guard mkdirat(parent, destination, 0o700) == 0 else { throw posix() }
            let output = openat(parent, destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw posix() }; defer { close(output) }
            for child in try names(input) { try copyTree(input, child, to: output, as: child, remaining: &remaining) }
        } else {
            let (input, _) = try read(source, name); defer { try? input.close() }
            let fd = openat(parent, destination, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posix() }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
            try output.synchronize()
        }
    }
    static func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
