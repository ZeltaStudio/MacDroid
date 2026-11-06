import Foundation
import MacDroidCore

final class MemoryBackend: FileBackend {
    var files: [String: Data]
    var modified: [String: Date]
    var fullCalls = 0
    var rangeCalls: [(UInt64, UInt64)] = []
    init(files: [String: Data]) {
        self.files = files
        modified = Dictionary(uniqueKeysWithValues: files.keys.map { ($0, Date(timeIntervalSince1970: 1_700_000_000)) })
    }
    func stat(_ path: String) throws -> RemoteEntry {
        if let data = files[path] { return RemoteEntry(path: path, directory: false, size: UInt64(data.count), modified: modified[path] ?? Date()) }
        throw AppError("File not found.")
    }
    func list(_ path: String) throws -> [RemoteEntry] { [] }
    func download(_ path: String, to local: URL, transfer: TransferOperation?) throws {
        fullCalls += 1
        guard let data = files[path] else { throw AppError("File not found.") }
        try data.write(to: local)
    }
    func downloadRange(_ path: String, offset: UInt64, length: UInt64, to local: URL, transfer: TransferOperation?) throws {
        rangeCalls.append((offset, length))
        guard let data = files[path] else { throw AppError("File not found.") }
        let start = Int(offset), end = start + Int(length)
        guard start >= 0, end <= data.count else { throw AppError("The file changed or the download was incomplete. Please try opening it again.") }
        try data.subdata(in: start..<end).write(to: local)
    }
    func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws { files[path] = try Data(contentsOf: local) }
    func mkdir(_ path: String) throws {}
    func delete(_ path: String) throws { files.removeValue(forKey: path) }
    func move(_ path: String, to destination: String, overwrite: Bool) throws {
        guard let data = files.removeValue(forKey: path) else { throw AppError("File not found.") }
        if !overwrite, files[destination] != nil { throw AppError("Destination already exists.") }
        files[destination] = data
        modified[destination] = modified[path]
    }
}

final class FailingRangeBackend: MemoryBackend {
    override func downloadRange(_ path: String, offset: UInt64, length: UInt64, to local: URL, transfer: TransferOperation?) throws {
        rangeCalls.append((offset, length))
        throw AppError("exec-out unavailable")
    }
}

final class HugePreviewBackend: FileBackend {
    var fullCalls = 0
    var rangeCalls = 0
    func stat(_ path: String) throws -> RemoteEntry { RemoteEntry(path: path, directory: false, size: 40_000_000, modified: Date(timeIntervalSince1970: 1_700_000_000)) }
    func list(_ path: String) throws -> [RemoteEntry] { [] }
    func download(_ path: String, to local: URL, transfer: TransferOperation?) throws { fullCalls += 1; throw AppError("full pull") }
    func downloadRange(_ path: String, offset: UInt64, length: UInt64, to local: URL, transfer: TransferOperation?) throws { rangeCalls += 1; throw AppError("range failed") }
    func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws {}
    func mkdir(_ path: String) throws {}
    func delete(_ path: String) throws {}
    func move(_ path: String, to destination: String, overwrite: Bool) throws {}
}

extension WebDAVTests {
    func testPreviewPlanningAndRanges() throws {
        XCTAssertEqual(ContentCache.plan(path: "/DCIM/photo.jpg", fileSize: 2_000_000, offset: 0, length: 100), .complete)
        XCTAssertEqual(ContentCache.plan(path: "/DCIM/clip.mp4", fileSize: 2_000_000, offset: 0, length: 100), .window(offset: 0, length: ContentCache.readAhead))
        XCTAssertEqual(ContentCache.plan(path: "/DCIM/clip.mp4", fileSize: 2_000_000, offset: 1_900_000, length: 100), .window(offset: 1_900_000, length: 100_000))
        XCTAssertEqual(ContentCache.plan(path: "/notes.bin", fileSize: 100, offset: 0, length: 10), .complete)
        XCTAssertEqual(ContentCache.plan(path: "/DCIM/clip.mp4", fileSize: 80_000_000, offset: 0, length: ContentCache.maxWindow + 1), .complete)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let blob = Data((0..<500).map { UInt8($0 % 251) })
        let cache = ContentCache()
        cache.store(path: "/DCIM/clip.mp4", size: 5000, modified: date, offset: 0, data: blob)
        XCTAssertEqual(cache.read(path: "/DCIM/clip.mp4", size: 5000, modified: date, offset: 10, length: 4), blob.subdata(in: 10..<14))
        XCTAssertNil(cache.read(path: "/DCIM/clip.mp4", size: 5000, modified: date.addingTimeInterval(5), offset: 0, length: 4))
        XCTAssertNil(cache.read(path: "/DCIM/clip.mp4", size: 5001, modified: date, offset: 0, length: 4))
        cache.invalidate("/DCIM")
        XCTAssertNil(cache.read(path: "/DCIM/clip.mp4", size: 5000, modified: date, offset: 0, length: 4))
        let small = ContentCache(capacity: 100)
        small.store(path: "/a", size: 80, modified: date, offset: 0, data: Data(count: 80))
        small.store(path: "/b", size: 80, modified: date, offset: 0, data: Data(count: 80))
        XCTAssertNil(small.read(path: "/a", size: 80, modified: date, offset: 0, length: 80))
        XCTAssertEqual(small.read(path: "/b", size: 80, modified: date, offset: 0, length: 80)?.count, 80)
        let read = try XCTUnwrap(ADB.remoteRange(path: "/DCIM/hello café.jpg", offset: 5000, length: 100))
        XCTAssertEqual(read.alignedOffset, 4096)
        XCTAssertEqual(read.script, "dd if='/sdcard/DCIM/hello café.jpg' bs=4096 skip=1 count=1 2>/dev/null")
        let hostile = try XCTUnwrap(ADB.remoteRange(path: "/x'; rm -rf /", offset: 0, length: 10))
        XCTAssertEqual(hostile.script, "dd if=" + ADB.quote("/sdcard/x'; rm -rf /") + " bs=4096 skip=0 count=1 2>/dev/null")
        XCTAssertNil(ADB.remoteRange(path: "/a", offset: 0, length: 0))
        let block = Data((0..<8192).map { UInt8($0 % 251) })
        let sliced = try XCTUnwrap(ADB.slice(data: block, alignedOffset: 4096, offset: 5000, length: 100))
        XCTAssertEqual(sliced, block.subdata(in: 904..<1004))
        let memory = MemoryBackend(files: ["/a.bin": Data(repeating: 3, count: 100)])
        let safe = RecoverableBackend(base: memory, recovery: RecoveryStore(backend: memory))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try safe.downloadRange("/a.bin", offset: 10, length: 4, to: copy, transfer: nil)
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertEqual(try Data(contentsOf: copy), Data(repeating: 3, count: 4))
        XCTAssertEqual(memory.rangeCalls, [(10, 4)])
        XCTAssertEqual(memory.fullCalls, 0)
    }

    func testPreviewReadsKeepFullFiles() async throws {
        let video = Data((0..<6_000_000).map { UInt8(($0 * 13 + 7) % 251) })
        let clips = MemoryBackend(files: ["/DCIM/clip.mp4": video])
        server.stop()
        server = WebDAVServer(backend: clips)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let (prefix, prefixResponse) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=0-1023"])
        XCTAssertEqual(prefixResponse.statusCode, 206)
        XCTAssertEqual(prefixResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(prefixResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1023/6000000")
        XCTAssertEqual(prefixResponse.value(forHTTPHeaderField: "Content-Length"), "1024")
        XCTAssertEqual(prefix, video.subdata(in: 0..<1024))
        XCTAssertEqual(clips.rangeCalls, [(0, ContentCache.readAhead)])
        XCTAssertEqual(clips.fullCalls, 0)
        let (middle, _) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=2000-2099"])
        XCTAssertEqual(middle, video.subdata(in: 2000..<2100))
        XCTAssertEqual(clips.rangeCalls.count, 1)
        let tail = video.count - 100
        let (ending, endingResponse) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=\(tail)-"])
        XCTAssertEqual(endingResponse.statusCode, 206)
        XCTAssertEqual(endingResponse.value(forHTTPHeaderField: "Content-Range"), "bytes \(tail)-\(video.count - 1)/\(video.count)")
        XCTAssertEqual(ending, video.suffix(100))
        XCTAssertEqual(clips.rangeCalls.count, 2)
        XCTAssertEqual(clips.rangeCalls[1].0, UInt64(tail))
        XCTAssertEqual(clips.rangeCalls[1].1, 100)
        XCTAssertEqual(clips.fullCalls, 0)
        let (full, fullResponse) = try await fileGET("DCIM/clip.mp4")
        XCTAssertEqual(fullResponse.statusCode, 200)
        XCTAssertEqual(fullResponse.value(forHTTPHeaderField: "Content-Length"), "6000000")
        XCTAssertNil(fullResponse.value(forHTTPHeaderField: "Content-Range"))
        XCTAssertEqual(full, video)
        XCTAssertEqual(clips.fullCalls, 1)
        let (cachedRange, _) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=10-20"])
        XCTAssertEqual(cachedRange, video.subdata(in: 10..<21))
        XCTAssertEqual(clips.fullCalls, 1)
        XCTAssertEqual(clips.rangeCalls.count, 2)

        let photo = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let photos = MemoryBackend(files: ["/DCIM/photo.jpg": photo])
        server.stop()
        server = WebDAVServer(backend: photos)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let (head, headResponse) = try await fileGET("DCIM/photo.jpg", headers: ["Range": "bytes=0-99"])
        XCTAssertEqual(headResponse.statusCode, 206)
        XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(head, photo.prefix(100))
        XCTAssertEqual(photos.fullCalls, 1)
        XCTAssertTrue(photos.rangeCalls.isEmpty)
        let (more, _) = try await fileGET("DCIM/photo.jpg", headers: ["Range": "bytes=1500-1599"])
        XCTAssertEqual(more, photo.subdata(in: 1500..<1600))
        let (opened, openedResponse) = try await fileGET("DCIM/photo.jpg")
        XCTAssertEqual(openedResponse.statusCode, 200)
        XCTAssertEqual(opened, photo)
        XCTAssertEqual(photos.fullCalls, 1)
        let replacement = Data(repeating: 9, count: photo.count)
        try await request("PUT", "DCIM/photo.jpg", data: replacement, status: 204)
        let (replaced, _) = try await fileGET("DCIM/photo.jpg")
        XCTAssertEqual(replaced, replacement)
        XCTAssertEqual(photos.fullCalls, 2)

        let failing = FailingRangeBackend(files: ["/DCIM/clip.mp4": video])
        server.stop()
        server = WebDAVServer(backend: failing)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let (fallback, fallbackResponse) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=0-63"])
        XCTAssertEqual(fallbackResponse.statusCode, 206)
        XCTAssertEqual(fallback, video.prefix(64))
        XCTAssertEqual(failing.rangeCalls.count, 1)
        XCTAssertEqual(failing.fullCalls, 1)

        let huge = HugePreviewBackend()
        server.stop()
        server = WebDAVServer(backend: huge)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let (_, refused) = try await fileGET("DCIM/clip.mp4", headers: ["Range": "bytes=0-10"])
        XCTAssertEqual(refused.statusCode, 500)
        XCTAssertEqual(huge.rangeCalls, 1)
        XCTAssertEqual(huge.fullCalls, 0)
    }
}
