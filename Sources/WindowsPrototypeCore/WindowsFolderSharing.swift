import Foundation
import Darwin
import MacVMCore

/// WebDAV over the guest's standard SPICE virtio-serial channel. No host TCP
/// listener. A virtual root exposes only folders explicitly selected in Settings.
public final class WindowsFolderSharing {
    private let queue = DispatchQueue(label: "macvm.windows.webdav", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var socket: WindowsSocket?
    private let server: WindowsWebDAV
    public init(folders: [SharedFolder]) { server = WindowsWebDAV(folders: folders) }
    public func start(_ url: URL) {
        queue.async { [self] in
            while !isStopped {
                do {
                    let connection = try WindowsSocket(url: url)
                    lock.lock(); socket = connection; lock.unlock()
                    defer { connection.cancel(); lock.lock(); socket = nil; lock.unlock() }
                    var buffers: [UInt64: Data] = [:]
                    var continuing = Set<UInt64>()
                    while !isStopped {
                        let header = try connection.read(10)
                        let client = header.le64(0), count = Int(header[8]) | Int(header[9]) << 8
                        if count == 0 { buffers.removeValue(forKey: client); continuing.remove(client); continue }
                        guard buffers[client] != nil || buffers.count < 32 else { throw VMError.message("Too many Windows shared-folder connections.") }
                        buffers[client, default: Data()].append(try connection.read(count))
                        guard buffers[client]!.count <= WindowsWebDAV.maximumBody + 32_768 else { throw VMError.message("Shared-folder request exceeds 128 MB.") }
                        guard buffers.values.reduce(0, { $0 + $1.count }) <= WindowsWebDAV.maximumBody + 1_048_576 else { throw VMError.message("Shared-folder request buffers are full.") }
                        if !continuing.contains(client), WindowsWebDAV.needsContinue(buffers[client]!) {
                            try send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), client: client, connection: connection); continuing.insert(client)
                        }
                        while let request = try WindowsWebDAV.takeRequest(from: &buffers[client]!) {
                            let reply = server.respond(request)
                            try send(reply.header, client: client, connection: connection)
                            if let file = reply.file {
                                defer { try? file.close() }
                                var remaining = reply.fileSize
                                while remaining > 0 {
                                    guard let data = try file.read(upToCount: Int(min(65_535, remaining))), !data.isEmpty else {
                                        throw VMError.message("The shared file changed while it was being read.")
                                    }
                                    try send(data, client: client, connection: connection)
                                    remaining -= Int64(data.count)
                                }
                            } else if !reply.body.isEmpty { try send(reply.body, client: client, connection: connection) }
                            continuing.remove(client)
                            if request.headers["connection"]?.lowercased() == "close" {
                                try send(Data(), client: client, connection: connection); buffers.removeValue(forKey: client); break
                            }
                        }
                    }
                } catch { if !isStopped { Thread.sleep(forTimeInterval: 1) } }
            }
        }
    }
    public func stop() { lock.lock(); stopped = true; let connection = socket; lock.unlock(); connection?.cancel() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func send(_ data: Data, client: UInt64, connection: WindowsSocket) throws {
        if data.isEmpty { try connection.write(.littleEndian64(client) + Data([0, 0])); return }
        for offset in stride(from: 0, to: data.count, by: 65_535) {
            let part = data.subdata(in: offset..<min(offset + 65_535, data.count))
            try connection.write(.littleEndian64(client) + Data([UInt8(truncatingIfNeeded: part.count), UInt8(truncatingIfNeeded: part.count >> 8)]) + part)
        }
    }
}

public final class WindowsWebDAV {
    public static let maximumBody = 128 * 1024 * 1024
    public struct Request { public let method: String; public let path: String; public let headers: [String: String]; public let body: Data }
    public struct Reply { public let header: Data; public let body: Data; public let file: FileHandle?; public let fileSize: Int64; public let status: Int }
    private let folders: [SharedFolder]
    private struct WriteLock {
        let token: String
        let descendants: Bool
        var expires: TimeInterval
    }
    private var locks: [String: WriteLock] = [:]
    private let clock: () -> TimeInterval
    public init(folders: [SharedFolder], clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.folders = folders; self.clock = clock
    }
    private func suppliedTokens(_ request: Request) -> Set<String> {
        guard let value = request.headers["if"] else { return [] }
        let text = value as NSString
        let lists = try! NSRegularExpression(pattern: "\\(([^)]*)\\)")
        let conditions = try! NSRegularExpression(pattern: "(?i)(Not\\s+)?<([^>]+)>")
        var tokens = Set<String>()
        for list in lists.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let body = text.substring(with: list.range(at: 1)), content = body as NSString
            for condition in conditions.matches(in: body, range: NSRange(location: 0, length: content.length)) where condition.range(at: 1).location == NSNotFound {
                tokens.insert(content.substring(with: condition.range(at: 2)))
            }
        }
        return tokens
    }
    private func deniedByLock(_ path: String, request: Request, includingChildren: Bool = false) -> Bool {
        let tokens = suppliedTokens(request)
        return locks.contains { key, value in
            let affected = key == path || (value.descendants && path.hasPrefix(key + "/")) || (includingChildren && key.hasPrefix(path + "/"))
            return affected && !tokens.contains(value.token)
        }
    }
    private final class LockInfo: NSObject, XMLParserDelegate {
        private var elements: [String] = []
        private var exclusive = false, write = false, validRoot = false
        static func accepts(_ data: Data) -> Bool {
            guard data.count <= 32_768, let text = String(data: data, encoding: .utf8), !text.contains("<!") else { return false }
            let delegate = LockInfo(), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            return parser.parse() && delegate.validRoot && delegate.exclusive && delegate.write
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String]) {
            guard elements.count < 32 else { parser.abortParsing(); return }
            if elements.isEmpty { validRoot = elementName == "lockinfo" && namespaceURI == "DAV:" }
            elements.append(elementName)
            if namespaceURI == "DAV:", elements == ["lockinfo", "lockscope", "exclusive"] { exclusive = true }
            if namespaceURI == "DAV:", elements == ["lockinfo", "locktype", "write"] { write = true }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if !elements.isEmpty { elements.removeLast() } }
    }
    private func lockXML(_ key: String, _ value: WriteLock) -> String {
        let seconds = max(1, Int(ceil(value.expires - clock())))
        let path = key.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
        return "<d:activelock><d:locktype><d:write/></d:locktype><d:lockscope><d:exclusive/></d:lockscope><d:depth>\(value.descendants ? "infinity" : "0")</d:depth><d:timeout>Second-\(seconds)</d:timeout><d:locktoken><d:href>\(value.token)</d:href></d:locktoken><d:lockroot><d:href>/\(path)</d:href></d:lockroot></d:activelock>"
    }

    public static func needsContinue(_ data: Data) -> Bool {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return false }
        return header.lowercased().contains("expect: 100-continue")
    }
    public static func takeRequest(from buffer: inout Data) throws -> Request? {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 32_768 else { throw VMError.message("Shared-folder HTTP header is too large.") }; return nil
        }
        guard boundary.lowerBound - buffer.startIndex <= 32_768,
              let text = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { throw invalid() }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw invalid() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw invalid() }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw invalid() }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw invalid() }
        let count: Int
        if let length = headers["content-length"] { guard let value = Int(length), value >= 0, value <= maximumBody else { throw invalid() }; count = value }
        else { count = 0 }
        guard buffer.count >= boundary.upperBound - buffer.startIndex + count else { return nil }
        let start = boundary.upperBound, end = start + count
        let request = Request(method: String(first[0]), path: String(first[1]), headers: headers, body: buffer.subdata(in: start..<end))
        buffer = Data(buffer[end...]); return request
    }
    private static func invalid() -> VMError { .message("Invalid Windows shared-folder request.") }

    /// Anchor operations to opened directories. O_NOFOLLOW on every component
    /// prevents a parent-symlink swap from escaping the selected share.
    private final class Target {
        let url: URL; let folder: SharedFolder; let root: Bool
        let descriptor: Int32; let components: [String]
        var leaf: String { root ? "." : components.last! }
        init(url: URL, folder: SharedFolder, root: Bool, descriptor: Int32, components: [String]) {
            self.url = url; self.folder = folder; self.root = root; self.descriptor = descriptor; self.components = components
        }
        deinit { close(descriptor) }
    }
    private func target(_ path: String, writing: Bool = false) throws -> Target {
        guard path.hasPrefix("/"), !path.contains("?"), let decoded = path.removingPercentEncoding,
              !decoded.contains("\0"), !decoded.contains("\\") else { throw Self.invalid() }
        let components = decoded.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }), let name = components.first,
              let folder = folders.first(where: { $0.name == name }), !writing || !folder.readOnly else { throw Self.invalid() }
        let root = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath()
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.invalid() }
        do {
            for component in components.dropFirst().dropLast() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.invalid() }; close(descriptor); descriptor = next
            }
            var url = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
            if components.count > 1 { url.appendPathComponent(components.last!) }
            if components.count > 1 {
                var info = stat()
                if fstatat(descriptor, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK { throw Self.invalid() }
            }
            return Target(url: url, folder: folder, root: components.count == 1, descriptor: descriptor, components: components)
        } catch { close(descriptor); throw error }
    }
    public func respond(_ request: Request) -> Reply {
        let now = clock()
        locks = locks.filter { $0.value.expires > now }
        func answer(_ code: Int, _ data: Data = Data(), extra: [String: String] = [:], file: FileHandle? = nil, size: Int64? = nil) -> Reply {
            let names = [200:"OK",201:"Created",204:"No Content",207:"Multi-Status",400:"Bad Request",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",409:"Conflict",412:"Precondition Failed",423:"Locked",500:"Internal Server Error",507:"Insufficient Storage"]
            var head = "HTTP/1.1 \(code) \(names[code] ?? "Error")\r\nContent-Length: \(size ?? Int64(data.count))\r\nConnection: keep-alive\r\n"
            for (key, value) in extra { head += "\(key): \(value)\r\n" }
            head += "\r\n"; return Reply(header: Data(head.utf8), body: data, file: file, fileSize: file == nil ? 0 : size ?? 0, status: code)
        }
        if request.method == "OPTIONS" { return answer(200, extra: ["DAV":"1, 2", "MS-Author-Via":"DAV", "Allow":"OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK, PROPPATCH"]) }
        if request.path == "/" {
            if request.method == "PROPFIND" {
                guard [nil, "0", "1"].contains(request.headers["depth"]) else { return answer(403) }
                var entries = [properties(path: "/", name: "MacVM Shared Folders", directory: true, size: 0, modified: Date(), readOnly: true)]
                if request.headers["depth"] != "0" { entries += folders.map { properties(path: "/" + encode($0.name) + "/", name: $0.name, directory: true, size: 0, modified: Date(), readOnly: $0.readOnly) } }
                return answer(207, xml(entries), extra: ["Content-Type":"application/xml; charset=utf-8"])
            }
            return answer(403)
        }
        do {
            let mutation = ["PUT","DELETE","MKCOL","MOVE","LOCK","UNLOCK","PROPPATCH"].contains(request.method)
            let item = try target(request.path, writing: mutation)
            // Lock keys use decoded, normalized paths: percent encoding and a
            // trailing slash must not allow another client to evade a lock.
            let key = "/" + item.components.joined(separator: "/")
            if ["PUT","DELETE","MKCOL","MOVE","PROPPATCH"].contains(request.method),
               deniedByLock(key, request: request, includingChildren: ["DELETE","MOVE"].contains(request.method)) { return answer(423) }
            switch request.method {
            case "PROPFIND":
                guard [nil,"0","1"].contains(request.headers["depth"]) else { return answer(403) }
                let values = try WindowsShareFileSystem.info(item.descriptor, item.leaf)
                let isDirectory = values.directory
                let path = request.path + (isDirectory && !request.path.hasSuffix("/") ? "/" : "")
                var entries = [properties(path: path, name: item.root ? item.folder.name : item.leaf, directory: isDirectory, size: values.bytes, modified: values.modified, readOnly: item.folder.readOnly)]
                if isDirectory && request.headers["depth"] != "0" {
                    for info in try WindowsShareFileSystem.list(item.descriptor, item.leaf) {
                        entries.append(properties(path: path + encode(info.name) + (info.directory ? "/" : ""), name: info.name, directory: info.directory, size: info.bytes, modified: info.modified, readOnly: item.folder.readOnly))
                    }
                }
                return answer(207, xml(entries), extra: ["Content-Type":"application/xml; charset=utf-8"])
            case "GET", "HEAD":
                let (file, size) = try WindowsShareFileSystem.read(item.descriptor, item.leaf)
                if request.method == "HEAD" { try? file.close(); return answer(200, size: size) }
                return answer(200, extra: ["Content-Type":"application/octet-stream"], file: file, size: size)
            case "PUT":
                guard !item.root else { return answer(403) }
                let exists = (try? WindowsShareFileSystem.info(item.descriptor, item.leaf)) != nil
                let exclusive = request.headers["if-none-match"] == "*"
                if exclusive && exists { return answer(412) }
                try WindowsShareFileSystem.put(item.descriptor, item.leaf, data: request.body, exclusive: exclusive)
                return answer(exists ? 204 : 201)
            case "MKCOL": guard !item.root else { return answer(403) }; guard mkdirat(item.descriptor, item.leaf, 0o700) == 0 else { throw WindowsShareFileSystem.posix() }; return answer(201)
            case "DELETE": guard !item.root else { return answer(403) }; try WindowsShareFileSystem.remove(item.descriptor, item.leaf); return answer(204)
            case "MOVE", "COPY":
                guard !item.root, let destination = request.headers["destination"],
                      let components = URLComponents(string: destination), components.host == nil || ["localhost", "127.0.0.1"].contains(components.host!) else { return answer(403) }
                let dest = try target(components.percentEncodedPath, writing: true)
                guard !dest.root, dest.components != item.components,
                      !dest.components.starts(with: item.components) else { return answer(403) }
                if deniedByLock("/" + dest.components.joined(separator: "/"), request: request, includingChildren: true) { return answer(423) }
                let exclusive = request.headers["overwrite"] == "F"
                if exclusive && (try? WindowsShareFileSystem.info(dest.descriptor, dest.leaf)) != nil { return answer(412) }
                if request.method == "MOVE" {
                    let result = exclusive ? renameatx_np(item.descriptor, item.leaf, dest.descriptor, dest.leaf, UInt32(RENAME_EXCL)) : renameat(item.descriptor, item.leaf, dest.descriptor, dest.leaf)
                    guard result == 0 else { throw WindowsShareFileSystem.posix() }
                } else { try WindowsShareFileSystem.copy(item.descriptor, item.leaf, to: dest.descriptor, as: dest.leaf, exclusive: exclusive) }
                return answer(201)
            case "LOCK":
                let duration = request.headers["timeout"]?.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Second-", with: "")) }.first ?? 3600
                let seconds = min(3600, max(1, duration))
                let depth = request.headers["depth"] ?? "infinity"
                guard ["0", "infinity"].contains(depth) else { return answer(400) }
                let token: String
                if var existing = locks[key] {
                    guard request.body.isEmpty, suppliedTokens(request).contains(existing.token) else { return answer(request.body.isEmpty ? 412 : 423) }
                    existing.expires = now + Double(seconds); locks[key] = existing; token = existing.token
                } else {
                    guard !request.body.isEmpty else { return answer(412) }
                    guard LockInfo.accepts(request.body) else { return answer(400) }
                    guard locks.count < 1024 else { return answer(507) }
                    guard !deniedByLock(key, request: request, includingChildren: depth == "infinity") else { return answer(423) }
                    token = "opaquelocktoken:" + UUID().uuidString
                    locks[key] = WriteLock(token: token, descendants: depth == "infinity", expires: now + Double(seconds))
                }
                let body = "<?xml version=\"1.0\"?><d:prop xmlns:d=\"DAV:\"><d:lockdiscovery>\(lockXML(key, locks[key]!))</d:lockdiscovery></d:prop>"
                return answer(200, Data(body.utf8), extra: ["Lock-Token":"<\(token)>", "Content-Type":"application/xml"])
            case "UNLOCK": guard let existing = locks[key], request.headers["lock-token"] == "<\(existing.token)>" else { return answer(409) }; locks.removeValue(forKey: key); return answer(204)
            case "PROPPATCH": return answer(207, xml(["<d:response><d:href>\(escape(request.path))</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"]), extra: ["Content-Type":"application/xml"])
            default: return answer(405)
            }
        } catch {
            if error is VMError { return answer(403) }
            let ns = error as NSError
            return answer(ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) ? 404 : ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) ? 507 : 409)
        }
    }
    private func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    private func xml(_ entries: [String]) -> Data { Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:m=\"urn:schemas-microsoft-com:\">" + entries.joined() + "</d:multistatus>").utf8) }
    private func properties(path: String, name: String, directory: Bool, size: Int, modified: Date, readOnly: Bool) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let key = "/" + (path.removingPercentEncoding ?? path).split(separator: "/").joined(separator: "/")
        let discovery = locks.filter { $0.key == key || ($0.value.descendants && key.hasPrefix($0.key + "/")) }.map { lockXML($0.key, $0.value) }.joined()
        // Advertise the same permissions we enforce. Windows applications use
        // FILE_ATTRIBUTE_READONLY to avoid silently editing a cached WebDAV copy.
        let attributes = String(format: "%08X", (directory ? 0x10 : 0x20) | (readOnly ? 0x01 : 0))
        return "<d:response><d:href>\(escape(path))</d:href><d:propstat><d:prop><d:displayname>\(escape(name))</d:displayname><d:resourcetype>\(directory ? "<d:collection/>" : "")</d:resourcetype><d:getcontentlength>\(size)</d:getcontentlength><d:getlastmodified>\(formatter.string(from: modified))</d:getlastmodified><d:getetag>\"\(size)-\(Int(modified.timeIntervalSince1970))\"</d:getetag><m:Win32FileAttributes>\(attributes)</m:Win32FileAttributes><d:supportedlock><d:lockentry><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype></d:lockentry></d:supportedlock><d:lockdiscovery>\(discovery)</d:lockdiscovery></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
}
