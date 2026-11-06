import Foundation
import Network

public final class WebDAVServer {
    private let backend: FileBackend
    public let transfers: TransferCenter
    private let previews = ContentCache()
    private let queue = DispatchQueue(label: "MacDroid.WebDAV")
    private var listener: NWListener?
    private var clients: [UUID: HTTPClient] = [:]
    private var locks: [String: (String, Date)] = [:]
    private let token = UUID().uuidString
    private var port: UInt16 = 0
    public var onError: ((String) -> Void)?
    public init(backend: FileBackend, transfers: TransferCenter = TransferCenter()) { self.backend = backend; self.transfers = transfers }
    public func start(completion: @escaping (Result<URL, Error>) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port!.rawValue
                completion(.success(URL(string: "http://127.0.0.1:\(self.port)/\(self.token)/")!))
            case .failed(let error): completion(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPClient(connection: connection, queue: self.queue) { [weak self] request in
                let response = self?.respond(request) ?? HTTPResponse(503)
                if ProcessInfo.processInfo.environment["MACDROID_DAV_TRACE"] == "1" {
                    fputs("DAV \(request.method) \(request.target) \(request.headers) -> \(response.status)\n", stderr)
                }
                return response
            }
            client.beginTransfer = { [weak self] method, target, size in
                guard let self, ["GET", "PUT"].contains(method), let path = try? Self.decodedPath(target, token: self.token) else { return nil }
                let operation = self.transfers.begin(path: path, direction: method == "GET" ? "Phone → Mac" : "Mac → Phone")
                operation.stage(method == "GET" ? "Preparing download" : "Receiving from Finder", total: size)
                return operation
            }
            self.clients[id] = client
            client.onClose = { [weak self] in self?.clients.removeValue(forKey: id) }
            client.start()
        }
        listener.start(queue: queue)
    }
    public func stop() {
        queue.async {
            self.previews.removeAll()
            self.transfers.cancelAll()
            self.listener?.cancel(); self.listener = nil
            let clients = Array(self.clients.values)
            clients.forEach { $0.close() }; self.clients.removeAll()
        }
    }
    public static func decodedPath(_ target: String, token: String) throws -> String {
        guard let components = URLComponents(string: target), components.query == nil,
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/\(token)/") else { throw DAVError(403) }
        let suffix = String(decoded.dropFirst(token.count + 1))
        let pieces = suffix.split(separator: "/")
        guard !pieces.contains(".."), !pieces.contains("."), !decoded.contains("\0") else { throw DAVError(403) }
        return "/" + pieces.joined(separator: "/")
    }
    private func href(_ path: String, directory: Bool) -> String {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }.joined(separator: "/")
        return "/\(token)/" + encoded + (directory && !encoded.isEmpty ? "/" : "")
    }
    private func entryXML(_ entry: RemoteEntry) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let etag = "\"\(entry.size)-\(Int(entry.modified.timeIntervalSince1970))\""
        return """
        <D:response><D:href>\(xml(href(entry.path, directory: entry.directory)))</D:href><D:propstat><D:prop><D:displayname>\(xml((entry.path as NSString).lastPathComponent))</D:displayname><D:resourcetype>\(entry.directory ? "<D:collection/>" : "")</D:resourcetype><D:getcontentlength>\(entry.directory ? 0 : entry.size)</D:getcontentlength><D:getlastmodified>\(date.string(from: entry.modified))</D:getlastmodified><D:getetag>\(xml(etag))</D:getetag><D:getcontenttype>\(entry.directory ? "httpd/unix-directory" : "application/octet-stream")</D:getcontenttype><D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
    }
    private func checkLocks(_ path: String, request: HTTPRequest) throws {
        locks = locks.filter { $0.value.1 > Date() }
        for (locked, value) in locks where path == locked || path.hasPrefix(locked + "/") || locked.hasPrefix(path + "/") {
            guard request.headers["if", default: ""].contains(value.0) else { throw DAVError(423) }
        }
    }
    private func respond(_ request: HTTPRequest) -> HTTPResponse {
        do {
            let path = try Self.decodedPath(request.target, token: token)
            switch request.method {
            case "OPTIONS": return HTTPResponse(200, headers: ["DAV": "1, 2", "Allow": "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, MOVE, LOCK, UNLOCK"])
            case "PROPFIND":
                guard ["0", "1"].contains(request.headers["depth", default: "infinity"]) else { throw DAVError(403) }
                guard let entry = try? backend.stat(path) else { throw DAVError(404) }
                var entries = [entry]
                if entry.directory && request.headers["depth"] == "1" { entries += try backend.list(path) }
                return HTTPResponse(207, xml: "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\(entries.map(entryXML).joined())</D:multistatus>")
            case "GET", "HEAD":
                guard let entry = try? backend.stat(path) else { throw DAVError(404) }
                guard !entry.directory else { throw DAVError(405) }
                let representation = HTTPFileRepresentation(entry: entry)
                var headers = representation.headers
                if representation.unchanged(headers: request.headers) { return HTTPResponse(304, headers: headers) }
                headers["Content-Length"] = String(entry.size)
                if request.method == "HEAD" { return HTTPResponse(200, headers: headers) }
                let selection = representation.range(headers: request.headers)
                let offset: UInt64, length: UInt64, status: Int
                switch selection {
                case .full: offset = 0; length = entry.size; status = 200
                case .partial(let start, let count):
                    offset = start; length = count; status = 206
                    headers["Content-Range"] = "bytes \(start)-\(start + count - 1)/\(entry.size)"
                    headers["Content-Length"] = String(count)
                case .unsatisfiable:
                    headers["Content-Range"] = "bytes */\(entry.size)"
                    headers["Content-Length"] = "0"
                    return HTTPResponse(416, headers: headers)
                }
                // Ranges stay the real file bytes. Thumbnails reuse a cache; a full read still pulls the whole file.
                let (file, fileOffset) = try serveBody(path: path, entry: entry, offset: offset, length: length, transfer: request.transfer)
                return HTTPResponse(status, headers: headers, file: file, fileOffset: fileOffset, fileLength: length)
            case "PUT":
                guard path != "/" else { throw DAVError(403) }
                try checkLocks(path, request: request)
                if request.headers["if-none-match"] == "*", (try? backend.stat(path)) != nil { throw DAVError(412) }
                let exists = (try? backend.stat(path)) != nil
                try request.transfer?.cancellation.check(); try backend.upload(request.body, to: path, transfer: request.transfer)
                previews.invalidate(path)
                return HTTPResponse(exists ? 204 : 201)
            case "MKCOL":
                try checkLocks(path, request: request)
                guard request.bodySize == 0 else { throw DAVError(415) }
                guard (try? backend.stat(path)) == nil else { throw DAVError(405) }
                try backend.mkdir(path); return HTTPResponse(201)
            case "DELETE":
                guard path != "/" else { throw DAVError(403) }
                try checkLocks(path, request: request)
                guard (try? backend.stat(path)) != nil else { throw DAVError(404) }
                try backend.delete(path); previews.invalidate(path); return HTTPResponse(204)
            case "MOVE":
                guard let destination = request.headers["destination"], let url = URLComponents(string: destination),
                      url.host == "127.0.0.1", url.port == Int(port), url.scheme == "http" else { throw DAVError(403) }
                let target = try Self.decodedPath(destination, token: token)
                guard path != "/", target != "/", target != path, !target.hasPrefix(path + "/") else { throw DAVError(403) }
                try checkLocks(path, request: request); try checkLocks(target, request: request)
                guard (try? backend.stat(path)) != nil else { throw DAVError(404) }
                let exists = (try? backend.stat(target)) != nil
                if exists && request.headers["overwrite"] == "F" { throw DAVError(412) }
                // Avoid recursive replacement; Finder can explicitly delete an existing folder first.
                if exists, (try backend.stat(target)).directory { throw DAVError(409) }
                try backend.move(path, to: target, overwrite: request.headers["overwrite"] != "F")
                previews.invalidate(path); previews.invalidate(target)
                return HTTPResponse(exists ? 204 : 201)
            case "LOCK":
                guard request.headers["depth", default: "0"] == "0" else { throw DAVError(403) }
                locks = locks.filter { $0.value.1 > Date() }
                let lock: String
                if request.bodySize == 0, let existing = locks[path], request.headers["if", default: ""].contains(existing.0) { lock = existing.0 }
                else {
                    guard locks[path] == nil else { throw DAVError(423) }
                    lock = "opaquelocktoken:" + UUID().uuidString
                }
                // Finder can lock a new file before its first PUT.
                if (try? backend.stat(path)) == nil { try backend.upload(request.emptyFile(), to: path); previews.invalidate(path) }
                locks[path] = (lock, Date().addingTimeInterval(600))
                return HTTPResponse(200, headers: ["Lock-Token": "<\(lock)>"], xml: "<?xml version=\"1.0\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:timeout>Second-600</D:timeout><D:locktoken><D:href>\(lock)</D:href></D:locktoken><D:lockroot><D:href>\(href(path, directory: false))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>")
            case "UNLOCK":
                guard let lock = locks[path], request.headers["lock-token"] == "<\(lock.0)>" else { throw DAVError(409) }
                locks.removeValue(forKey: path); return HTTPResponse(204)
            default: throw DAVError(405)
            }
        } catch is CancellationError { return HTTPResponse(503, text: "Transfer cancelled.") }
        catch let error as DAVError { return HTTPResponse(error.status) }
        catch { onError?(error.localizedDescription); return HTTPResponse(500, text: error.localizedDescription) }
    }
    /// Cache hits and narrow windows return a file that already starts at the requested byte.
    /// A complete download returns the whole file so the caller can slice it, after the size check.
    private func serveBody(path: String, entry: RemoteEntry, offset: UInt64, length: UInt64, transfer: TransferOperation?) throws -> (URL, UInt64) {
        let entire = offset == 0 && length == entry.size
        if let hit = previews.read(path: path, size: entry.size, modified: entry.modified, offset: offset, length: length), UInt64(hit.count) == length {
            return (try staged(hit), 0)
        }
        if !entire, case .window(let start, let count) = ContentCache.plan(path: path, fileSize: entry.size, offset: offset, length: length), count >= length, start <= offset {
            do {
                let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: raw) }
                try transfer?.cancellation.check()
                try backend.downloadRange(path, offset: start, length: count, to: raw, transfer: transfer)
                let data = try Data(contentsOf: raw)
                guard UInt64(data.count) == count else { throw AppError("The file changed or the download was incomplete. Please try opening it again.") }
                previews.store(path: path, size: entry.size, modified: entry.modified, offset: start, data: data)
                guard offset >= start, length <= UInt64(Int.max), offset - start <= UInt64(Int.max) else { throw AppError("The file changed or the download was incomplete. Please try opening it again.") }
                let lead = Int(offset - start)
                guard lead + Int(length) <= data.count else { throw AppError("The file changed or the download was incomplete. Please try opening it again.") }
                return (try staged(data.subdata(in: lead..<(lead + Int(length)))), 0)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try transfer?.cancellation.check()
                guard entry.size <= ContentCache.fallbackFullLimit else { throw error }
            }
        }
        return (try downloadFull(path, entry: entry, transfer: transfer), offset)
    }
    private func downloadFull(_ path: String, entry: RemoteEntry, transfer: TransferOperation?) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try transfer?.cancellation.check()
            try backend.download(path, to: file, transfer: transfer)
            let actualSize = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value
            guard actualSize == entry.size else { throw AppError("The file changed or the download was incomplete. Please try opening it again.") }
            if entry.size <= ContentCache.imageFullLimit, entry.size <= UInt64(Int.max), let data = try? Data(contentsOf: file), UInt64(data.count) == entry.size {
                previews.store(path: path, size: entry.size, modified: entry.modified, offset: 0, data: data)
            }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private func staged(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file, options: .atomic)
        return file
    }
}

private func xml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}
public struct DAVError: Error { public let status: Int; public init(_ status: Int) { self.status = status } }

struct HTTPRequest {
    let method: String; let target: String; let headers: [String: String]; let body: URL; let bodySize: UInt64; let transfer: TransferOperation?
    func emptyFile() throws -> URL { try Data().write(to: body); return body }
}
struct HTTPResponse {
    let status: Int; var headers: [String: String]; var data: Data; var file: URL?; var fileOffset: UInt64 = 0; var fileLength: UInt64?
    init(_ status: Int, headers: [String: String] = [:], text: String = "", file: URL? = nil, fileOffset: UInt64 = 0, fileLength: UInt64? = nil) {
        self.status = status; self.headers = headers; self.data = Data(text.utf8); self.file = file; self.fileOffset = fileOffset; self.fileLength = fileLength
    }
    init(_ status: Int, headers: [String: String] = [:], xml: String) {
        self.init(status, headers: headers.merging(["Content-Type": "application/xml; charset=utf-8"]) { _, new in new }, text: xml)
    }
}

/// One request per connection. Uploads and downloads are disk-backed, including chunked uploads.
private final class HTTPClient {
    let connection: NWConnection; let queue: DispatchQueue; let handler: (HTTPRequest) -> HTTPResponse
    var onClose: (() -> Void)?
    var beginTransfer: ((String, String, UInt64?) -> TransferOperation?)?
    var transfer: TransferOperation?
    var cancellationTimer: DispatchSourceTimer?
    var completedResponse = false
    var sentBytes: UInt64 = 0
    var responseRemaining: UInt64 = 0
    var finishTimeout: DispatchWorkItem?
    var buffer = Data(); var headers: [String: String] = [:]; var method = ""; var target = ""
    let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var writer: FileHandle?; var reader: FileHandle?; var responseFile: URL?
    var remaining: UInt64 = 0; var written: UInt64 = 0; var parsed = false; var chunked = false
    var chunkRemaining: Int?; var needsChunkCRLF = false; var awaitingTrailers = false; var closed = false
    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.connection = connection; self.queue = queue; self.handler = handler
    }
    func start() {
        FileManager.default.createFile(atPath: body.path, contents: nil)
        writer = try? FileHandle(forWritingTo: body)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in if self?.transfer?.cancellation.isCancelled == true { self?.close() } }
        cancellationTimer = timer; timer.resume()
        receive()
    }
    func close() {
        guard !closed else { return }; closed = true
        cancellationTimer?.cancel(); cancellationTimer = nil
        finishTimeout?.cancel(); finishTimeout = nil
        if !completedResponse { transfer?.finish("Connection interrupted") }
        connection.cancel(); try? writer?.close(); try? reader?.close()
        try? FileManager.default.removeItem(at: body)
        if let responseFile { try? FileManager.default.removeItem(at: responseFile) }
        onClose?(); onClose = nil
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            do {
                if try self.consume() { return }
                if complete || error != nil { self.close() } else { self.receive() }
            } catch let error as DAVError { self.send(HTTPResponse(error.status)) }
            catch { self.send(HTTPResponse(500)) }
        }
    }
    func consume() throws -> Bool {
        if !parsed {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65536 { throw DAVError(431) }; return false
            }
            guard end.lowerBound <= 65536 else { throw DAVError(431) }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3 else { throw DAVError(400) }
            method = String(first[0]); target = String(first[1])
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw DAVError(400) }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw DAVError(400) }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            buffer.removeSubrange(..<end.upperBound); parsed = true
            chunked = headers["transfer-encoding"]?.lowercased() == "chunked"
            if headers["transfer-encoding"] != nil && !chunked { throw DAVError(501) }
            if chunked && headers["content-length"] != nil { throw DAVError(400) }
            if let length = headers["content-length"] {
                guard let length = UInt64(length) else { throw DAVError(400) }; remaining = length
            }
            transfer = beginTransfer?(method, target, chunked ? nil : remaining)
            if headers["expect"]?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        if chunked {
            while true {
                if awaitingTrailers {
                    if buffer.starts(with: Data("\r\n".utf8)) || buffer.range(of: Data("\r\n\r\n".utf8)) != nil { return finish() }
                    if buffer.count > 65536 { throw DAVError(431) }; return false
                }
                if needsChunkCRLF {
                    guard buffer.count >= 2 else { return false }
                    guard buffer.starts(with: Data("\r\n".utf8)) else { throw DAVError(400) }
                    buffer.removeFirst(2); needsChunkCRLF = false; chunkRemaining = nil
                }
                if chunkRemaining == nil {
                    guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                        if buffer.count > 1024 { throw DAVError(400) }; return false
                    }
                    let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)[0]
                    guard let size = Int(line, radix: 16), size >= 0 else { throw DAVError(400) }
                    buffer.removeSubrange(..<end.upperBound)
                    if size == 0 { awaitingTrailers = true; continue }
                    chunkRemaining = size
                }
                let count = min(buffer.count, chunkRemaining!)
                if count == 0 { return false }
                try write(count); chunkRemaining! -= count
                if chunkRemaining == 0 { needsChunkCRLF = true }
            }
        } else {
            let count = Int(min(UInt64(buffer.count), remaining))
            try write(count); remaining -= UInt64(count)
            return remaining == 0 ? finish() : false
        }
    }
    func write(_ count: Int) throws {
        try transfer?.cancellation.check()
        guard let writer else { throw DAVError(507) }
        try writer.write(contentsOf: buffer.prefix(count)); written += UInt64(count); buffer.removeFirst(count)
        if method == "PUT" { transfer?.progress(written, phase: "Receiving from Finder") }
    }
    func finish() -> Bool {
        try? writer?.close(); writer = nil
        send(handler(HTTPRequest(method: method, target: target, headers: headers, body: body, bodySize: written, transfer: transfer)))
        return true
    }
    func send(_ response: HTTPResponse) {
        if response.status >= 400 { transfer?.finish("Failed (HTTP \(response.status))") }
        responseFile = response.file
        var response = response
        if let file = response.file {
            do {
                reader = try FileHandle(forReadingFrom: file)
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard response.fileOffset <= size else { throw AppError("File offset is outside the downloaded file.") }
                let length = response.fileLength ?? (size - response.fileOffset)
                guard length <= size - response.fileOffset else { throw AppError("Downloaded file is incomplete.") }
                try reader?.seek(toOffset: response.fileOffset)
                responseRemaining = length
                transfer?.stage("Sending to Finder", total: length)
                response.headers["Content-Length"] = String(length)
            } catch { close(); return }
        } else if response.headers["Content-Length"] == nil { response.headers["Content-Length"] = String(response.data.count) }
        if response.status == 204 || response.status == 304 { response.headers.removeValue(forKey: "Content-Length") }
        response.headers["Date"] = HTTPFileRepresentation.dateString(Date())
        response.headers["Connection"] = "close"
        response.headers["Content-Type"] = response.headers["Content-Type"] ?? "application/octet-stream"
        let reasons = [200:"OK", 201:"Created", 204:"No Content", 206:"Partial Content", 207:"Multi-Status", 304:"Not Modified", 400:"Bad Request", 403:"Forbidden", 404:"Not Found", 405:"Method Not Allowed", 409:"Conflict", 412:"Precondition Failed", 415:"Unsupported Media Type", 416:"Range Not Satisfiable", 423:"Locked", 431:"Request Header Fields Too Large", 500:"Internal Server Error", 501:"Not Implemented", 503:"Service Unavailable", 507:"Insufficient Storage"]
        let head = "HTTP/1.1 \(response.status) \(reasons[response.status, default: "Error"])\r\n" + response.headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
        var initial = Data(head.utf8)
        if method != "HEAD" { initial.append(response.data) }
        connection.send(content: initial, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close() }
            else if self.method == "HEAD" || self.reader == nil {
                self.finishResponse()
            } else { self.sendFileChunk() }
        })
    }
    func finishResponse() {
        // Send a TCP write-close after the body, then wait for the client's close. Cancelling
        // the connection immediately can discard bytes still buffered in the protocol stack.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            self.completedResponse = true; self.transfer?.finish()
            let timeout = DispatchWorkItem { [weak self] in self?.close() }
            self.finishTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            self.waitForPeerClose()
        })
    }
    func waitForPeerClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self, !self.closed else { return }
            if complete || error != nil { self.close() } else { self.waitForPeerClose() }
        }
    }
    func sendFileChunk() {
        do {
            try transfer?.cancellation.check()
            if responseRemaining == 0 { finishResponse(); return }
            guard let data = try reader?.read(upToCount: Int(min(responseRemaining, 256 * 1024))), !data.isEmpty else {
                transfer?.finish("Incomplete download"); close(); return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close() }
                else {
                    self.sentBytes += UInt64(data.count); self.responseRemaining -= UInt64(data.count)
                    self.transfer?.progress(self.sentBytes, phase: "Sending to Finder")
                    self.sendFileChunk()
                }
            })
        } catch { close() }
    }
}
