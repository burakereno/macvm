import XCTest
import MacVMCore
@testable import WindowsPrototypeCore

final class WindowsSharingTests: XCTestCase {
    func testClipboardFramingIsBoundedAndHandlesFragmentation() throws {
        var bytes = Data.littleEndian(1); bytes.append(.littleEndian(4)); bytes.append(Data(repeating: 0, count: 8))
        bytes.append(.littleEndian(7)); bytes.append(.littleEndian(1)); bytes.append(Data("abc".utf8))
        var partial = Data(bytes.prefix(22))
        XCTAssertNil(try WindowsAgentClient.takeMessage(from: &partial))
        partial.append(bytes.dropFirst(22))
        let message = try XCTUnwrap(WindowsAgentClient.takeMessage(from: &partial))
        XCTAssertEqual(message.type, 4); XCTAssertEqual(message.data, .littleEndian(1) + Data("abc".utf8)); XCTAssertTrue(partial.isEmpty)
        var invalid = Data.littleEndian(1); invalid.append(.littleEndian(4)); invalid.append(Data(repeating: 0, count: 8)); invalid.append(.littleEndian(UInt32(WindowsAgentClient.maximumTextBytes + 5)))
        XCTAssertThrowsError(try WindowsAgentClient.takeMessage(from: &invalid))
    }
    func testWebDAVParsingRejectsSmugglingAndConsumesOneRequest() throws {
        var partial = Data("PUT /Share/a HTTP/1.1\r\nContent-Length: 3\r\n\r\na".utf8)
        XCTAssertNil(try WindowsWebDAV.takeRequest(from: &partial))
        partial.append(Data("bcOPTIONS / HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(try WindowsWebDAV.takeRequest(from: &partial)?.body, Data("abc".utf8))
        XCTAssertEqual(try WindowsWebDAV.takeRequest(from: &partial)?.method, "OPTIONS")
        for header in ["Content-Length: -1", "Content-Length: 134217729", "Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked"] {
            var invalid = Data("PUT /Share/a HTTP/1.1\r\n\(header)\r\n\r\n".utf8)
            XCTAssertThrowsError(try WindowsWebDAV.takeRequest(from: &invalid))
        }
    }
    func testSelectedFoldersReadWriteAndReadOnlyIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writable = root.appendingPathComponent("Writable"), readOnly = root.appendingPathComponent("ReadOnly")
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("safe".utf8).write(to: readOnly.appendingPathComponent("sample.txt"))
        let server = WindowsWebDAV(folders: [.init(name: "Writable", path: writable.path, readOnly: false), .init(name: "ReadOnly", path: readOnly.path)])
        func request(_ method: String, _ path: String, body: Data = Data(), headers: [String:String] = [:]) throws -> WindowsWebDAV.Reply {
            var text = "\(method) \(path) HTTP/1.1\r\nContent-Length: \(body.count)\r\n"
            for (key,value) in headers { text += "\(key): \(value)\r\n" }; text += "\r\n"
            var data = Data(text.utf8) + body
            return server.respond(try XCTUnwrap(WindowsWebDAV.takeRequest(from: &data)))
        }
        XCTAssertEqual(try request("PUT", "/Writable/new.txt", body: Data("from Windows".utf8)).status, 201)
        XCTAssertEqual(try String(contentsOf: writable.appendingPathComponent("new.txt")), "from Windows")
        let read = try request("GET", "/ReadOnly/sample.txt")
        XCTAssertEqual(read.status, 200); XCTAssertEqual(try read.file?.readToEnd(), Data("safe".utf8)); try read.file?.close()
        for method in ["PUT","DELETE","MKCOL","MOVE","LOCK","PROPPATCH"] {
            XCTAssertEqual(try request(method, "/ReadOnly/sample.txt", body: Data("bad".utf8)).status, 403, method)
        }
        XCTAssertEqual(try request("COPY", "/Writable/new.txt", headers: ["Destination":"http://localhost:9843/ReadOnly/new.txt"]).status, 403)
        XCTAssertEqual(try request("PROPFIND", "/", headers: ["Depth":"infinity"]).status, 403)
        let listing = try request("PROPFIND", "/", headers: ["Depth":"1"])
        XCTAssertEqual(listing.status, 207); XCTAssertTrue(String(decoding: listing.body, as: UTF8.self).contains("Writable"))
        // Windows must see a read-only file as read-only before it opens a
        // local WebDAV cache copy, in addition to the server rejecting writes.
        let readOnlyProperties = try request("PROPFIND", "/ReadOnly/sample.txt", headers: ["Depth":"0"])
        XCTAssertTrue(String(decoding: readOnlyProperties.body, as: UTF8.self).contains("<m:Win32FileAttributes>00000021</m:Win32FileAttributes>"))
        let writableProperties = try request("PROPFIND", "/Writable/new.txt", headers: ["Depth":"0"])
        XCTAssertTrue(String(decoding: writableProperties.body, as: UTF8.self).contains("<m:Win32FileAttributes>00000020</m:Win32FileAttributes>"))
        for path in ["/Writable/../ReadOnly/sample.txt", "/Writable/%2e%2e/ReadOnly/sample.txt", "/Writable/%00file", "/Other/file"] { XCTAssertEqual(try request("GET", path).status, 403) }
        try FileManager.default.createSymbolicLink(at: writable.appendingPathComponent("escape"), withDestinationURL: readOnly)
        XCTAssertEqual(try request("GET", "/Writable/escape/sample.txt").status, 403)
        XCTAssertEqual(try request("DELETE", "/Writable").status, 403)
    }
    func testOnlyOfficialMicrosoftDownloadLinksAreAccepted() throws {
        try WindowsMachinePreparation.validateDownloadURL(URL(string:"https://software.download.prss.microsoft.com/dbazure/test.iso?t=token")!)
        for path in ["http://download.microsoft.com/test.iso", "https://download.microsoft.com.evil.example/test.iso", "https://evil.example/test.iso", "https://user:pass@download.microsoft.com/test.iso", "https://download.microsoft.com/test.exe"] {
            XCTAssertThrowsError(try WindowsMachinePreparation.validateDownloadURL(URL(string: path)!))
        }
    }
    func testFolderCopyMoveAndDeletePreserveExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = WindowsWebDAV(folders: [.init(name:"Share", path:root.path, readOnly:false)])
        func request(_ method: String, _ path: String, body: String = "", destination: String? = nil, exclusive: Bool = false) throws -> Int {
            var text = "\(method) \(path) HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n"
            if let destination { text += "Destination: http://localhost:9843\(destination)\r\n" }
            if exclusive { text += "Overwrite: F\r\n" }; text += "\r\n\(body)"
            var bytes = Data(text.utf8)
            return server.respond(try XCTUnwrap(WindowsWebDAV.takeRequest(from:&bytes))).status
        }
        XCTAssertEqual(try request("MKCOL", "/Share/Folder"), 201)
        XCTAssertEqual(try request("PUT", "/Share/Folder/a.txt", body:"original"), 201)
        XCTAssertEqual(try request("COPY", "/Share/Folder", destination:"/Share/Copy"), 201)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("Copy/a.txt")), "original")
        XCTAssertEqual(try request("PUT", "/Share/existing.txt", body:"keep"), 201)
        XCTAssertEqual(try request("MOVE", "/Share/Copy/a.txt", destination:"/Share/existing.txt", exclusive:true), 412)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("existing.txt")), "keep")
        XCTAssertEqual(try request("MOVE", "/Share/Copy/a.txt", destination:"/Share/moved.txt", exclusive:true), 201)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("moved.txt")), "original")
        XCTAssertEqual(try request("DELETE", "/Share/Folder"), 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("moved.txt").path))
    }
    func testWriteLocksProtectFilesUntilUnlockOrExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("a.txt"))
        var now: TimeInterval = 100
        let server = WindowsWebDAV(folders: [.init(name: "Share", path: root.path, readOnly: false)], clock: { now })
        let lockInfo = "<d:lockinfo xmlns:d='DAV:'><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype></d:lockinfo>"
        func request(_ method: String, _ path: String, body: String = "", headers: [String:String] = [:]) throws -> WindowsWebDAV.Reply {
            var text = "\(method) \(path) HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n"
            for (key, value) in headers { text += "\(key): \(value)\r\n" }
            var data = Data((text + "\r\n" + body).utf8)
            return server.respond(try XCTUnwrap(WindowsWebDAV.takeRequest(from: &data)))
        }
        let locked = try request("LOCK", "/Share/a.txt", body: lockInfo, headers: ["Depth":"0", "Timeout":"Second-10"])
        XCTAssertEqual(locked.status, 200)
        let response = String(decoding: locked.header, as: UTF8.self)
        let token = try XCTUnwrap(response.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Lock-Token: ") })?.dropFirst(12)).description
        let properties = try request("PROPFIND", "/Share/a.txt", headers: ["Depth":"0"])
        XCTAssertTrue(String(decoding: properties.body, as: UTF8.self).contains(token.dropFirst().dropLast()))
        XCTAssertEqual(try request("PUT", "/Share/%61.txt", body: "blocked").status, 423)
        XCTAssertEqual(try request("DELETE", "/Share/a.txt/").status, 423)
        XCTAssertEqual(try request("PUT", "/Share/a.txt", body: "blocked", headers: ["If":"(Not \(token))"]).status, 423)
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", body: lockInfo).status, 423)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt")), "original")
        XCTAssertEqual(try request("PUT", "/Share/a.txt", body: "owner", headers: ["If":"(\(token))"]).status, 204)
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", headers: ["If":"(\(token))", "Timeout":"Second-20"]).status, 200)
        now = 111
        XCTAssertEqual(try request("PUT", "/Share/a.txt", body: "blocked").status, 423)
        XCTAssertEqual(try request("UNLOCK", "/Share/a.txt", headers: ["Lock-Token":"<invalid>"]).status, 409)
        XCTAssertEqual(try request("UNLOCK", "/Share/a.txt", headers: ["Lock-Token": token]).status, 204)
        XCTAssertEqual(try request("PUT", "/Share/a.txt", body: "unlocked").status, 204)
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", body: lockInfo, headers: ["Depth":"0", "Timeout":"Second-1"]).status, 200)
        now = 113
        XCTAssertEqual(try request("PUT", "/Share/a.txt", body: "expired").status, 204)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt")), "expired")
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", body: "not XML").status, 400)
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", body: lockInfo.replacingOccurrences(of: "exclusive", with: "shared")).status, 400)
        XCTAssertEqual(try request("LOCK", "/Share/a.txt", body: "<!DOCTYPE x [<!ENTITY a 'expand'>]>" + lockInfo).status, 400)
        XCTAssertEqual(try request("MKCOL", "/Share/Folder").status, 201)
        XCTAssertEqual(try request("PUT", "/Share/Folder/child.txt", body: "child").status, 201)
        XCTAssertEqual(try request("LOCK", "/Share/Folder/child.txt", body: lockInfo, headers: ["Depth":"0"]).status, 200)
        XCTAssertEqual(try request("DELETE", "/Share/Folder").status, 423)
        XCTAssertEqual(try request("MOVE", "/Share/Folder", headers: ["Destination":"http://localhost:9843/Share/Moved"]).status, 423)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/child.txt").path))
    }
}
