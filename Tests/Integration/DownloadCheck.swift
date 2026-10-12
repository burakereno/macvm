import Foundation

@main struct DownloadCheck {
    static func main() async {
        let base = CommandLine.arguments[1]
        let run = UUID().uuidString
        let root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("MacVM-network-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for route in ["interrupt", "changed", "wrong-range"] {
                let file = root.appendingPathComponent("MacVM-macOS-\(route).ipsw.download")
                let remote = URL(string: base + "/" + route + "?run=" + run)!
                let first = ImageDownloader(destination: file, requiredRemainingSpace: 0, progress: { _, _ in })
                var interrupted = false
                do { _ = try await first.download(remote) } catch { interrupted = true }
                let partial = try Data(contentsOf: file)
                let sent = Data(String(repeating: "01234567", count: 40960).utf8)
                // URLSession may buffer the final network chunk differently
                // across macOS releases; only received bytes can be resumed.
                guard interrupted, partial.count <= sent.count, partial == sent.prefix(partial.count) else {
                    throw VMError.message("Partial bytes or interruption error were lost for \(route).")
                }
                let retry = ImageDownloader(destination: file, requiredRemainingSpace: 0, progress: { _, _ in })
                if route == "wrong-range" {
                    var rejected = false
                    do { _ = try await retry.download(remote) } catch { rejected = true }
                    guard rejected, try Data(contentsOf: file) == partial else { throw VMError.message("Invalid range was accepted or appended data.") }
                } else {
                    _ = try await retry.download(remote)
                    let expected = route == "changed" ? "NEW!" : String(repeating: "01234567", count: 131072)
                    guard try Data(contentsOf: file) == Data(expected.utf8) else { throw VMError.message("Resumed bytes mismatch.") }
                }
            }
            let file = root.appendingPathComponent("MacVM-macOS-cancel.ipsw.download")
            let remote = URL(string: base + "/cancel?run=" + run)!
            let loader = ImageDownloader(destination: file, requiredRemainingSpace: 0, progress: { _, _ in })
            let task = Task { try await loader.download(remote) }
            for _ in 0..<500 {
                if ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) >= 131072 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch { cancelled = true }
            guard cancelled else { throw VMError.message("Cancelled transfer finished unexpectedly.") }
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) >= 131072 else { throw VMError.message("Cancel lost partial download.") }
            _ = try await ImageDownloader(destination: file, requiredRemainingSpace: 0, progress: { _, _ in }).download(remote)
            guard try Data(contentsOf: file) == Data(String(repeating: "01234567", count: 262144).utf8) else { throw VMError.message("Cancel/resume data mismatch.") }
            print("PASS: actual HTTP interruption, validator change, range rejection and cancellation/resume in Downloads; test files cleaned up.")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
