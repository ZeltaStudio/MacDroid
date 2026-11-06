import Foundation
import MacDroidCore

final class LocalBackend: FileBackend {
    let root: URL
    init(root: URL) { self.root = root }
    func local(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }
    func stat(_ path: String) throws -> RemoteEntry {
        let info = try FileManager.default.attributesOfItem(atPath: local(path).path)
        return RemoteEntry(path: path, directory: info[.type] as? FileAttributeType == .typeDirectory, size: (info[.size] as? NSNumber)?.uint64Value ?? 0, modified: info[.modificationDate] as? Date ?? Date())
    }
    func list(_ path: String) throws -> [RemoteEntry] {
        try FileManager.default.contentsOfDirectory(atPath: local(path).path).map { try stat((path == "/" ? "" : path) + "/" + $0) }
    }
    func download(_ path: String, to local: URL, transfer: TransferOperation?) throws { try FileManager.default.copyItem(at: self.local(path), to: local) }
    func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws { try Data(contentsOf: local).write(to: self.local(path), options: .atomic) }
    func mkdir(_ path: String) throws { try FileManager.default.createDirectory(at: local(path), withIntermediateDirectories: false) }
    func delete(_ path: String) throws { try FileManager.default.removeItem(at: local(path)) }
    func move(_ path: String, to destination: String, overwrite: Bool) throws {
        if overwrite { try? FileManager.default.removeItem(at: local(destination)) }
        try FileManager.default.moveItem(at: local(path), to: local(destination))
    }
}

final class WebDAVTests {
    var server: WebDAVServer!
    var root: URL!
    var base: URL!
    func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = WebDAVServer(backend: LocalBackend(root: root))
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
    }
    func tearDown() async throws { server.stop(); try? FileManager.default.removeItem(at: root) }
    @discardableResult
    func request(_ method: String, _ path: String = "", data: Data? = nil, headers: [String: String] = [:], status: Int) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = data
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status, String(decoding: body, as: UTF8.self))
        return body
    }
    func testFinderFileLifecycle() async throws {
        try await request("OPTIONS", status: 200)
        try await request("MKCOL", "Documents", status: 201)
        let name = "Documents/hello & café's.txt"
        let data = Data("Hello from the Mac 🌏".utf8)
        try await request("PUT", name, data: data, status: 201)
        let listing = try await request("PROPFIND", "Documents", data: Data("<propfind/>".utf8), headers: ["Depth": "1"], status: 207)
        XCTAssertTrue(String(decoding: listing, as: UTF8.self).contains("hello &amp; café&apos;s.txt"))
        let received = try await request("GET", name, status: 200)
        XCTAssertEqual(received, data)
        try await request("HEAD", name, status: 200)
        try await request("MOVE", name, headers: ["Destination": base.appendingPathComponent("Documents/renamed.txt").absoluteString], status: 201)
        try await request("GET", name, status: 404)
        try await request("DELETE", "Documents/renamed.txt", status: 204)
        try await request("DELETE", "Documents", status: 204)
        try await request("DELETE", status: 403)
    }
    func testOverwritePreconditionsAndForeignDestinations() async throws {
        try await request("PUT", "a", data: Data("a".utf8), status: 201)
        try await request("PUT", "b", data: Data("b".utf8), status: 201)
        try await request("PUT", "a", data: Data("changed".utf8), headers: ["If-None-Match": "*"], status: 412)
        try await request("MOVE", "a", headers: ["Destination": base.appendingPathComponent("b").absoluteString, "Overwrite": "F"], status: 412)
        try await request("MOVE", "a", headers: ["Destination": "http://example.com/b"], status: 403)
        let received = try await request("GET", "a", status: 200)
        XCTAssertEqual(received, Data("a".utf8))
    }
    func testExclusiveLocks() async throws {
        var req = URLRequest(url: base.appendingPathComponent("locked.txt")); req.httpMethod = "LOCK"
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.httpBody = Data("<D:lockinfo xmlns:D='DAV:'><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>".utf8)
        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let token = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Lock-Token"))
        try await request("PUT", "locked.txt", data: Data("blocked".utf8), status: 423)
        try await request("PUT", "locked.txt", data: Data("allowed".utf8), headers: ["If": "(\(token))"], status: 204)
        try await request("UNLOCK", "locked.txt", headers: ["Lock-Token": token], status: 204)
        try await request("DELETE", "locked.txt", status: 204)
    }
    func testChunkedUploadUsingCurl() async throws {
        let file = root.appendingPathComponent("curl-source")
        let data = Data(repeating: 0xab, count: 700_000)
        try data.write(to: file)
        let output = try Command.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--http1.1", "-X", "PUT", "-H", "Transfer-Encoding: chunked", "--data-binary", "@" + file.path, base.appendingPathComponent("chunked.bin").absoluteString])
        XCTAssertEqual(output, "")
        let received = try await request("GET", "chunked.bin", status: 200)
        XCTAssertEqual(received, data)
    }
    func testSystemWebDAVMount() async throws {
        guard ProcessInfo.processInfo.environment["MACDROID_TEST_MOUNT"] == "1" else { throw XCTSkip("Set MACDROID_TEST_MOUNT=1 to exercise the macOS WebDAV filesystem.") }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FinderMount.eject(mount) }
        try Data("from phone".utf8).write(to: root.appendingPathComponent("phone.txt"))
        _ = try Command.run("/sbin/mount_webdav", ["-v", "MacDroid Test", base.absoluteString, mount.path], timeout: 20)
        XCTAssertEqual(try String(contentsOf: mount.appendingPathComponent("phone.txt")), "from phone")
        try Data("from Mac".utf8).write(to: mount.appendingPathComponent("mac.txt"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mac.txt")), "from Mac")
        try FileManager.default.moveItem(at: mount.appendingPathComponent("mac.txt"), to: mount.appendingPathComponent("renamed.txt"))
        try FileManager.default.removeItem(at: mount.appendingPathComponent("renamed.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        XCTAssertTrue(try FinderMount.isMounted(mount))
        try FinderMount.eject(mount)
        XCTAssertFalse(try FinderMount.isMounted(mount))
    }
    func testRealAndroidBackend() async throws {
        guard let executable = ProcessInfo.processInfo.environment["MACDROID_ADB_PATH"], let serial = ProcessInfo.processInfo.environment["MACDROID_TEST_SERIAL"] else { throw XCTSkip("Set MACDROID_ADB_PATH and MACDROID_TEST_SERIAL for isolated real-device checks.") }
        let adb = ADB(executable: executable, serial: serial)
        let directory = "/Download/.macdroid-check-" + UUID().uuidString
        try adb.mkdir(directory)
        defer { try? adb.delete(directory) }
        let local = root.appendingPathComponent("upload")
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        try data.write(to: local)
        let name = directory + "/hello & café's file.bin"
        let upload = TransferOperation(path: name, direction: "Mac → Phone")
        try adb.upload(local, to: name, transfer: upload)
        XCTAssertEqual(upload.snapshot.completed, UInt64(data.count))
        upload.finish()
        XCTAssertTrue((try adb.storage())?.total ?? 0 > 0)
        XCTAssertEqual(try adb.stat(name).size, UInt64(data.count))
        XCTAssertEqual(try adb.list(directory).map(\.path), [name])
        let download = root.appendingPathComponent("download")
        let read = TransferOperation(path: name, direction: "Phone → Mac")
        try adb.download(name, to: download, transfer: read)
        XCTAssertEqual(read.snapshot.completed, UInt64(data.count))
        read.finish()
        XCTAssertEqual(try Data(contentsOf: download), data)
        let renamed = directory + "/renamed.bin"
        try adb.move(name, to: renamed, overwrite: false)
        XCTAssertEqual(try adb.stat(renamed).size, UInt64(data.count))
        let store = RecoveryStore(backend: adb)
        let safe = RecoverableBackend(base: adb, recovery: store)
        try safe.delete(renamed)
        let recovered = try XCTUnwrap(store.items().first { $0.originalPath == renamed })
        XCTAssertTrue((try? adb.stat(renamed)) == nil)
        try store.restore(recovered)
        let restored = root.appendingPathComponent("restored")
        try adb.download(renamed, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored), data)
        try adb.delete(renamed)
        XCTAssertTrue(try adb.list(directory).isEmpty)
    }
    func testPathValidation() throws {
        for path in ["/secret/../etc", "/secret/%2e%2e/etc", "/secret/%00file", "/wrong/file", "/secret/a?query=yes"] {
            XCTAssertThrowsError(try WebDAVServer.decodedPath(path, token: "secret"), path)
        }
        XCTAssertEqual(try WebDAVServer.decodedPath("/secret/DCIM/hello%20world.jpg", token: "secret"), "/DCIM/hello world.jpg")
        XCTAssertEqual(ADB.quote("hello'; rm -rf /"), "'hello'\\''; rm -rf /'")
    }
    func testLargeBinaryRoundTrip() async throws {
        let data = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        try await request("PUT", "large.bin", data: data, status: 201)
        let received = try await request("GET", "large.bin", status: 200)
        XCTAssertEqual(received, data)
    }
}

private var failures = 0
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if left != right { failures += 1; print("FAIL \(file):\(line): \(left) != \(right) \(message)") }
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, true, file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, false, file: file, line: line) }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw AppError("Expected non-nil value") }; return value }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String) {
    do { _ = try expression(); failures += 1; print("FAIL expected rejection: \(message)") } catch {}
}
struct XCTSkip: Error { let message: String; init(_ message: String) { self.message = message } }

@main
struct CheckRunner {
    static func main() async {
        let suite = WebDAVTests()
        let checks: [(String, () async throws -> Void)] = [
            ("Reconnect policy and transport labels", suite.testReconnectPolicy),
            ("Screen mirror command", { try suite.testScreenMirrorCommand() }),
            ("Transfer progress and cancellation", suite.testTransferCancellation),
            ("Recoverable deletion and restore", suite.testRecoverableDeletion),
            ("Storage capacity parsing", suite.testStorageParsing),
            ("HTTP transfer progress and cancellation", suite.testHTTPTransferProgressAndCancellation),
            ("Safe mount cleanup", suite.testSafeMountCleanup),
            ("Real phone Finder mount", suite.testRealPhoneFinderMount),
            ("Real USB and Wi-Fi handoff", suite.testRealTransportHandoff),
            ("HTTP byte ranges", suite.testHTTPByteRanges),
            ("HTTP image validators", suite.testHTTPFileValidators),
            ("Image range reassembly", suite.testImageRangeReassembly),
            ("Real phone image integrity", suite.testRealPhoneImageIntegrity),
            ("Finder file lifecycle", suite.testFinderFileLifecycle),
            ("Overwrite and destination protection", suite.testOverwritePreconditionsAndForeignDestinations),
            ("Exclusive locks", suite.testExclusiveLocks),
            ("Path validation", { try suite.testPathValidation() }),
            ("Binary transfer", suite.testLargeBinaryRoundTrip),
            ("Chunked transfer", suite.testChunkedUploadUsingCurl),
            ("macOS filesystem mount", suite.testSystemWebDAVMount),
            ("Real Android backend", suite.testRealAndroidBackend)
        ]
        let filter = ProcessInfo.processInfo.environment["MACDROID_CHECK_FILTER"]
        for (name, check) in checks where filter == nil || name.localizedCaseInsensitiveContains(filter!) {
            let before = failures
            do {
                try await suite.setUp()
                try await check()
                print("\(failures == before ? "PASS" : "FAIL") \(name)")
            } catch let skip as XCTSkip { print("SKIP \(name): \(skip.message)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            try? await suite.tearDown()
        }
        print("\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
