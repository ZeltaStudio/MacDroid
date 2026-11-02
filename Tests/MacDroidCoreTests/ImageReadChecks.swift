import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacDroidCore

func testJPEG() throws -> Data {
    let width = 1536, height = 2048
    var pixels = Data(count: width * height * 3)
    pixels.withUnsafeMutableBytes { (storage: UnsafeMutableRawBufferPointer) in
        var state: UInt32 = 0x12345678
        for i in storage.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            storage[i] = UInt8(truncatingIfNeeded: state)
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                    bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw AppError("Could not create the image fixture.") }
    return output as Data
}

func checkJPEG(_ bytes: Data) throws {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
    XCTAssertEqual(CGImageSourceGetStatusAtIndex(source, 0), .statusComplete)
    XCTAssertEqual(image.width, 1536); XCTAssertEqual(image.height, 2048)
}

extension WebDAVTests {
    func fileGET(_ path: String, headers: [String: String] = [:], method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        return (body, try XCTUnwrap(response as? HTTPURLResponse))
    }
    func testHTTPByteRanges() async throws {
        let bytes = Data((0..<8192).map { UInt8(($0 / 31 + $0 % 17) % 251) })
        try bytes.write(to: root.appendingPathComponent("image.bin"))
        for (range, offset, length) in [("bytes=3072-4095", 3072, 1024), ("bytes=7000-", 7000, 1192),
                                        ("bytes=-100", 8092, 100), ("bytes=8000-99999", 8000, 192),
                                        ("bytes=-99999", 0, 8192), ("BYTES=0-0", 0, 1)] {
            let (body, response) = try await fileGET("image.bin", headers: ["Range": range])
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes \(offset)-\(offset + length - 1)/8192")
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(length))
            XCTAssertEqual(body.count, length)
            XCTAssertTrue(body == bytes.subdata(in: offset..<(offset + length)))
        }
        for range in ["bytes=8192-", "bytes=99999-100000", "bytes=-0"] {
            let (body, response) = try await fileGET("image.bin", headers: ["Range": range])
            XCTAssertEqual(response.statusCode, 416)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes */8192")
            XCTAssertTrue(body.isEmpty)
        }
        for invalid in ["bytes=7-3", "bytes=abc", "items=0-1", "bytes=1-2,5-6"] {
            let (body, response) = try await fileGET("image.bin", headers: ["Range": invalid])
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(body == bytes)
        }
        try Data().write(to: root.appendingPathComponent("empty"))
        let (_, empty) = try await fileGET("empty", headers: ["Range": "bytes=0-"])
        XCTAssertEqual(empty.statusCode, 416)
        let (headBody, head) = try await fileGET("image.bin", headers: ["Range": "bytes=2-3"], method: "HEAD")
        XCTAssertEqual(head.statusCode, 200); XCTAssertTrue(headBody.isEmpty)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Length"), "8192")
    }
    func testHTTPFileValidators() async throws {
        try Data(repeating: 0x42, count: 1024).write(to: root.appendingPathComponent("image.jpg"))
        let (_, head) = try await fileGET("image.jpg", method: "HEAD")
        let etag = try XCTUnwrap(head.value(forHTTPHeaderField: "ETag"))
        let modified = try XCTUnwrap(head.value(forHTTPHeaderField: "Last-Modified"))
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        for validator in [etag, modified] {
            let (body, response) = try await fileGET("image.jpg", headers: ["Range": "bytes=100-199", "If-Range": validator])
            XCTAssertEqual(response.statusCode, 206); XCTAssertEqual(body.count, 100)
        }
        let (full, changed) = try await fileGET("image.jpg", headers: ["Range": "bytes=100-199", "If-Range": "\"different-version\""])
        XCTAssertEqual(changed.statusCode, 200); XCTAssertEqual(full.count, 1024)
        let (_, unchangedETag) = try await fileGET("image.jpg", headers: ["If-None-Match": etag])
        XCTAssertEqual(unchangedETag.statusCode, 304)
        let (_, unchangedDate) = try await fileGET("image.jpg", headers: ["If-Modified-Since": modified])
        XCTAssertEqual(unchangedDate.statusCode, 304)
        let (_, newVersion) = try await fileGET("image.jpg", headers: ["If-None-Match": "\"old\"", "If-Modified-Since": modified])
        XCTAssertEqual(newVersion.statusCode, 200)
    }
    func testImageRangeReassembly() async throws {
        let original = try testJPEG()
        XCTAssertTrue(original.count > 1_000_000)
        try original.write(to: root.appendingPathComponent("preview.jpg"))
        var reconstructed = Data(count: original.count)
        let block = 512 * 1024
        let offsets = Array(stride(from: 0, to: original.count, by: block)).reversed()
        for offset in offsets {
            let end = min(original.count, offset + block)
            let (body, response) = try await fileGET("preview.jpg", headers: ["Range": "bytes=\(offset)-\(end - 1)"])
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(body.count, end - offset)
            guard body.count == end - offset else { throw AppError("Partial image response has the wrong byte count.") }
            reconstructed.replaceSubrange(offset..<end, with: body)
        }
        XCTAssertTrue(reconstructed == original)
        try checkJPEG(reconstructed)
        let (full, response) = try await fileGET("preview.jpg")
        XCTAssertEqual(response.statusCode, 200); XCTAssertTrue(full == original)
        try checkJPEG(full)
    }
    func testRealPhoneImageIntegrity() async throws {
        guard ProcessInfo.processInfo.environment["MACDROID_TEST_MOUNT"] == "1", let executable = ProcessInfo.processInfo.environment["MACDROID_ADB_PATH"], let serial = ProcessInfo.processInfo.environment["MACDROID_TEST_SERIAL"] else { throw XCTSkip("Enable physical-device and mount checks together.") }
        let adb = ADB(executable: executable, serial: serial)
        let directory = "/Download/.macdroid-image-check-" + UUID().uuidString
        try adb.mkdir(directory)
        defer { try? adb.delete(directory) }
        let original = try testJPEG()
        let local = root.appendingPathComponent("source.jpg")
        try original.write(to: local)
        let remote = directory + "/preview.jpg"
        try adb.upload(local, to: remote)
        let direct = root.appendingPathComponent("adb-copy.jpg")
        try adb.download(remote, to: direct)
        XCTAssertTrue(try Data(contentsOf: direct) == original)
        server.stop(); server = WebDAVServer(backend: adb)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FinderMount.eject(mount) }
        try FinderMount.mount(base, at: mount, name: "MacDroid Image Check")
        let image = mount.appendingPathComponent(String(remote.dropFirst()))
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        for offset in [original.count - 65536, original.count / 2, 0, 256 * 1024] {
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: 65536)
            XCTAssertTrue(bytes == original.subdata(in: offset..<(offset + 65536)))
        }
        let mountedBytes = try Data(contentsOf: image)
        XCTAssertTrue(mountedBytes == original)
        try checkJPEG(mountedBytes)
        try handle.close()
        try FinderMount.eject(mount)
    }
}
