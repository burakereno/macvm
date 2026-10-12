import Foundation
import Darwin

/// Running guests share this lock; an update exclusively leases it. The helper
/// inherits the open file as stdin, keeping the lease after the library quits.
public final class AppUsageLock {
    private let descriptor: Int32
    public init(exclusive: Bool, url: URL? = nil) throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacVM")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = url ?? directory.appendingPathComponent("ApplicationUsage.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VMError.message("Cannot lock MacVM’s application files.") }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw VMError.message(exclusive ? "Shut down your virtual machines before updating MacVM." : "MacVM is being updated. Start this machine after the update finishes.")
        }
        descriptor = fd
    }
    public func inheritedHandle() throws -> FileHandle {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw VMError.message("Cannot preserve the update lock.") }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }
    deinit { close(descriptor) }
}
