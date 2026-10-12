import XCTest
import MacVMUpdate

final class UpdateTests: XCTestCase {
    func testNumericVersionsAndInvalidTags() throws {
        XCTAssertGreaterThan(try SemanticVersion("1.10.0"), try SemanticVersion("1.9.9"))
        for value in ["1.2", "01.2.3", "1.2.3-beta", "1.2.٣", "../1.2.3"] { XCTAssertThrowsError(try SemanticVersion(value)) }
        let url = URL(string: "https://github.com/burakereno/macvm/releases/tag/v1.2.3")!
        XCTAssertEqual(try UpdateContract.tag(from: url), "v1.2.3")
        for value in ["https://github.com/other/macvm/releases/tag/v1.2.3", "https://example.com/burakereno/macvm/releases/tag/v1.2.3", "https://github.com/burakereno/macvm/releases/latest"] {
            XCTAssertThrowsError(try UpdateContract.tag(from: URL(string: value)!))
        }
        XCTAssertThrowsError(try UpdateContract.validateResponseURL(URL(string: "http://github.com/burakereno/macvm")))
        XCTAssertThrowsError(try UpdateContract.validateResponseURL(URL(string: "https://example.com/MacVM.dmg")))
        XCTAssertNoThrow(try UpdateContract.validateResponseURL(URL(string: "https://release-assets.githubusercontent.com/test")))
    }
    @MainActor func testAutomaticErrorsAreSilentAndManualErrorsAreVisible() async {
        let checker = UpdateChecker(currentVersion: "0.2.0", fetch: { _ in throw URLError(.notConnectedToInternet) })
        await checker.check(manual: false)
        XCTAssertNil(checker.lastError); XCTAssertFalse(checker.checkedSuccessfully)
        await checker.check(manual: true)
        XCTAssertNotNil(checker.lastError); XCTAssertFalse(checker.checkedSuccessfully)
    }
    @MainActor func testValidRedirectAssetAndManifestAreRequiredTogether() async throws {
        let manifest = try fixture()
        var methods: [String] = []
        let checker = UpdateChecker(currentVersion: "1.9.9", fetch: { request in
            methods.append(request.httpMethod ?? "")
            let final = request.url == UpdateContract.latestURL ? URL(string: "https://github.com/burakereno/macvm/releases/tag/v1.10.0")! : request.url!
            let data = request.httpMethod == "GET" ? manifest : Data()
            return (data, HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await checker.check(manual: true)
        XCTAssertNil(checker.lastError); XCTAssertEqual(checker.release?.tag, "v1.10.0")
        XCTAssertEqual(methods, ["HEAD", "HEAD", "GET"])
    }
    @MainActor func testMissingAssetAndWrongPublisherCannotOfferUpdate() async throws {
        for missingAsset in [true, false] {
            let badManifest = try fixture(team: "WRONGTEAM")
            let checker = UpdateChecker(currentVersion: "0.2.0", fetch: { request in
                let final = request.url == UpdateContract.latestURL ? URL(string: "https://github.com/burakereno/macvm/releases/tag/v1.10.0")! : request.url!
                let missing = missingAsset && request.url?.lastPathComponent == "MacVM.dmg"
                return (request.httpMethod == "GET" ? badManifest : Data(), HTTPURLResponse(url: final, statusCode: missing ? 404 : 200, httpVersion: nil, headerFields: nil)!)
            })
            await checker.check(manual: true)
            XCTAssertNil(checker.release); XCTAssertNotNil(checker.lastError)
        }
    }
    func testAllManifestFieldsAndDownloadedBytesAreBoundToRelease() throws {
        let original = try JSONDecoder().decode(UpdateManifest.self, from: fixture())
        XCTAssertNoThrow(try original.validate(tag: "v1.10.0"))
        for key in ["version", "asset", "bundleIdentifier", "teamIdentifier", "sha256"] {
            var object = try JSONSerialization.jsonObject(with: fixture()) as! [String: String]
            object[key] = "wrong"
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try manifest.validate(tag: "v1.10.0"))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("corrupted download".utf8).write(to: file)
        XCTAssertThrowsError(try original.verify(file: file))
    }
    func testUpdaterConstantsMatchReleaseContract() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(contentsOf: repo.appendingPathComponent(".github/release-contract.env"), encoding: .utf8)
        for line in ["GITHUB_OWNER=\(UpdateContract.owner)", "GITHUB_REPO=\(UpdateContract.repo)", "DMG_ASSET_NAME=\(UpdateContract.assetName)", "BUNDLE_IDENTIFIER=\(UpdateContract.bundleIdentifier)", "TEAM_IDENTIFIER=\(UpdateContract.teamIdentifier)"] {
            XCTAssertTrue(contract.split(separator: "\n").contains(Substring(line)))
        }
    }
    private func fixture(team: String = "66K3EFBVB6") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": "1.10.0", "asset": "MacVM.dmg", "sha256": String(repeating: "a", count: 64), "bundleIdentifier": "com.burakerenoglu.macvm", "teamIdentifier": team])
    }
}
