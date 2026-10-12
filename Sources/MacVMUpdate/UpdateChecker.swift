import Foundation
import Observation

@MainActor @Observable
public final class UpdateChecker {
    public private(set) var release: UpdateRelease?
    public private(set) var lastError: String?
    public private(set) var isChecking = false
    public private(set) var checkedSuccessfully = false
    public private(set) var lastCheck: Date?
    public let currentVersion: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    public init(currentVersion: String, fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }) { self.currentVersion = currentVersion; self.fetch = fetch }

    public func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if manual { lastError = nil }
        do {
            let current = try SemanticVersion(currentVersion)
            let (_, latestResponse) = try await response(UpdateContract.latestURL, method: "HEAD")
            guard let final = latestResponse.url else { throw UpdateError.missingVersion }
            let tag = try UpdateContract.tag(from: final)
            let latest = try SemanticVersion(String(tag.dropFirst()))
            let asset = try UpdateContract.assetURL(tag: tag)
            do { _ = try await response(asset, method: "HEAD") } catch { throw UpdateError.missingAsset }
            let (data, _) = try await response(UpdateContract.assetURL(tag: tag, manifest: true), method: "GET")
            guard data.count <= 65_536 else { throw UpdateError.invalidManifest }
            let manifest: UpdateManifest
            do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: data); try manifest.validate(tag: tag) }
            catch { throw UpdateError.invalidManifest }
            release = latest > current ? UpdateRelease(tag: tag, downloadURL: asset, manifest: manifest) : nil
            checkedSuccessfully = true; lastCheck = Date(); lastError = nil
        } catch {
            if manual { lastError = error.localizedDescription }
        }
    }
    private func response(_ url: URL, method: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("MacVM-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        if (response as? HTTPURLResponse)?.statusCode == 404, url == UpdateContract.latestURL { throw UpdateError.missingVersion }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw UpdateError.badResponse }
        try UpdateContract.validateResponseURL(http.url)
        return (data, http)
    }
}
