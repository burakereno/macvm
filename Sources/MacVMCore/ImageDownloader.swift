import Foundation

/// Streams OS images to Downloads. A successful Range/If-Range exchange can
/// resume an interrupted transfer; a changed validator restarts from zero.
public final class ImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ResumeInfo: Codable {
        let url: URL
        let validator: String?
        let total: Int64
    }
    private let destination: URL
    private var metadataURL: URL { destination.appendingPathExtension("json") }
    private let progress: @Sendable (Double?, Int64) -> Void
    private let configuration: URLSessionConfiguration
    private let requiredRemainingSpace: UInt64
    private let availableCapacity: @Sendable (URL) -> UInt64
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var offset: Int64 = 0
    private var remoteURL: URL?
    private var validator: String?
    private var file: FileHandle?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let stateLock = NSLock()
    private var cancelled = false
    private var completed = false
    private var responseAccepted = false
    private var lastProgress = Date.distantPast

    public init(destination: URL, requiredRemainingSpace: UInt64 = 2 * VMStorage.gib,
                configuration: URLSessionConfiguration = .ephemeral,
                availableCapacity: @escaping @Sendable (URL) -> UInt64 = { VMStorage.availableBytes(at: $0) },
                progress: @escaping @Sendable (Double?, Int64) -> Void) {
        self.destination = destination; self.progress = progress
        self.configuration = configuration; self.requiredRemainingSpace = requiredRemainingSpace
        self.availableCapacity = availableCapacity
    }

    public func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                if cancelled { stateLock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    remoteURL = url
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VMError.message("The partial download is not a regular file.") }
                        if let data = try? Data(contentsOf: metadataURL), let resume = try? JSONDecoder().decode(ResumeInfo.self, from: data),
                           resume.url == url, let savedValidator = resume.validator, !savedValidator.isEmpty,
                           let size = values.fileSize, size > 0, Int64(size) < resume.total {
                            offset = Int64(size); validator = savedValidator
                        }
                    } else {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                            throw VMError.message("Cannot create a download in Downloads.")
                        }
                    }
                    file = try FileHandle(forWritingTo: destination)
                    if offset == 0 { try file?.truncate(atOffset: 0) } else { try file?.seekToEnd() }
                    received = offset
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    configuration.timeoutIntervalForRequest = 120
                    configuration.timeoutIntervalForResource = 86_400
                    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    var request = URLRequest(url: url)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if offset > 0 {
                        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                        request.setValue(validator, forHTTPHeaderField: "If-Range")
                    }
                    task = session?.dataTask(with: request); task?.resume()
                    stateLock.unlock()
                } catch { stateLock.unlock(); finish(.failure(error)) }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        stateLock.lock(); cancelled = true; let current = task; stateLock.unlock()
        current?.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw VMError.message("The download server returned an invalid response.") }
            if http.statusCode == 206 {
                guard offset > 0, let range = http.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = Self.parseRange(range), parsed.start == offset, parsed.total > offset,
                      response.expectedContentLength == parsed.total - offset else {
                    throw VMError.message("The server returned an invalid download range. Remove the partial download and retry.")
                }
                expected = parsed.total
            } else if http.statusCode == 200 {
                try file?.truncate(atOffset: 0); try file?.seek(toOffset: 0)
                received = 0; offset = 0; expected = response.expectedContentLength
            } else { throw VMError.message("The download server returned HTTP \(http.statusCode). Try again later.") }
            guard expected > 0 else { throw VMError.message("The download server did not provide the image size.") }
            let free = availableCapacity(destination.deletingLastPathComponent())
            let remaining = UInt64(expected - received)
            guard remaining <= free, requiredRemainingSpace <= free - remaining else {
                throw VMError.message("Downloads does not have enough free space for the macOS image and installation.")
            }
            let etag = http.value(forHTTPHeaderField: "ETag")
            let newValidator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? http.value(forHTTPHeaderField: "Last-Modified")
            if offset > 0, let newValidator, newValidator != validator {
                throw VMError.message("The download changed on the server. Remove the partial download and retry.")
            }
            let info = ResumeInfo(url: remoteURL!, validator: newValidator, total: expected)
            try JSONEncoder().encode(info).write(to: metadataURL, options: .atomic)
            responseAccepted = true
            completionHandler(.allow)
        } catch { completionHandler(.cancel); finish(.failure(error)) }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !completed, responseAccepted else { return }
        do {
            guard Int64(data.count) <= expected - received else { throw VMError.message("The download exceeded its advertised size.") }
            try file?.write(contentsOf: data); received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) > 0.2 {
                progress(Double(received) / Double(expected), received); lastProgress = Date()
            }
        } catch { dataTask.cancel(); finish(.failure(error)) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard responseAccepted, received == expected else { finish(.failure(VMError.message("The download was incomplete. Choose Create again to resume."))); return }
        finish(.success(destination))
    }
    private func finish(_ result: Result<URL, Error>) {
        stateLock.lock()
        guard !completed else { stateLock.unlock(); return }
        completed = true; let callback = continuation; continuation = nil
        stateLock.unlock()
        try? file?.synchronize(); try? file?.close(); file = nil
        session?.finishTasksAndInvalidate(); session = nil
        callback?.resume(with: result)
    }
    private static func parseRange(_ value: String) -> (start: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(separator: "/")
        guard fields.count == 2, let total = Int64(fields[1]), total > 0 else { return nil }
        let bounds = fields[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end == total - 1 else { return nil }
        return (start, total)
    }
}
