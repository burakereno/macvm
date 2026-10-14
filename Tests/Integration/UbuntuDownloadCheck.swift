import Foundation

@main
struct UbuntuDownloadCheck {
    static func main() async {
        do {
            guard let release = UbuntuRelease(rawValue: CommandLine.arguments[1]) else { throw VMError.message("Choose a known Ubuntu release.") }
            let image = try await UbuntuImageCatalog.resolve(release)
            let file = InstallationFiles.downloads.appendingPathComponent(image.managedName)
            let lease = try ImageLease(url: file)
            defer { withExtendedLifetime(lease) {} }
            if !FileManager.default.fileExists(atPath: file.path) {
                print("Downloading \(release.title) to Downloads…"); fflush(stdout)
                let partial = file.appendingPathExtension("download")
                let downloader = ImageDownloader(destination: partial) { _, _ in }
                _ = try await downloader.download(image.url)
                try FileManager.default.moveItem(at: partial, to: file)
                try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
            }
            try image.verify(archive: file)
            if CommandLine.arguments.count > 2 {
                let root = URL(fileURLWithPath: CommandLine.arguments[2])
                try Data((image.sha256 + " *" + image.archiveName + "\n").utf8).write(to: root.appendingPathComponent("SHA256SUMS"), options: .atomic)
            }
            print("PASS: official catalog, production ImageDownloader and SHA256 verification")
            print(file.path)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
