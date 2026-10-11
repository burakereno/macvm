import Foundation
import MacVMCore

/// Stream directly to the selected volume, so an external VM location does not
/// require another full IPSW's worth of space on the startup disk.
final class ImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?, Int64) -> Void
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var file: FileHandle?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let stateLock = NSLock()
    private var cancelled = false
    private var completed = false
    private var lastProgress = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Double?, Int64) -> Void) {
        self.destination = destination; self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                if cancelled { stateLock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw VMError.message("Cannot create a download in the selected location.")
                    }
                    file = try FileHandle(forWritingTo: destination)
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 120
                    config.timeoutIntervalForResource = 86_400
                    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    task = session?.dataTask(with: url)
                    task?.resume()
                    stateLock.unlock()
                } catch {
                    stateLock.unlock(); finish(.failure(error))
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        stateLock.lock(); cancelled = true; let current = task; stateLock.unlock()
        current?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(VMError.message("Apple’s download server returned an error. Please try again.")))
            return
        }
        expected = response.expectedContentLength
        if expected > 0 && UInt64(expected) + 2 * VMStorage.gib > VMStorage.availableBytes(at: destination.deletingLastPathComponent()) {
            completionHandler(.cancel)
            finish(.failure(VMError.message("This volume does not have enough room for the macOS restore image.")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) > 0.2 {
                progress(expected > 0 ? Double(received) / Double(expected) : nil, received)
                lastProgress = Date()
            }
        } catch { dataTask.cancel(); finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        if expected > 0 && received != expected { finish(.failure(VMError.message("The download was incomplete. Please retry."))); return }
        finish(.success(destination))
    }

    private func finish(_ result: Result<URL, Error>) {
        stateLock.lock()
        guard !completed else { stateLock.unlock(); return }
        completed = true
        let callback = continuation; continuation = nil
        stateLock.unlock()
        try? file?.close(); file = nil
        session?.finishTasksAndInvalidate(); session = nil
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        callback?.resume(with: result)
    }
}
