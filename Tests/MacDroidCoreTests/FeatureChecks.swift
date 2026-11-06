import Foundation
import MacDroidCore

extension WebDAVTests {
    func testRealTransportHandoff() async throws {
        guard let executable = ProcessInfo.processInfo.environment["MACDROID_ADB_PATH"] else { throw XCTSkip("Enable physical-device checks.") }
        let devices = try DeviceDiscovery.scan(executable: executable, knownIDs: [], reconnect: false)
        guard let usb = devices.first(where: { !$0.wireless }), let wifi = devices.first(where: { $0.wireless && $0.hardwareID == usb.hardwareID }) else { throw XCTSkip("The same phone must have authorized USB and Wi-Fi connections.") }
        let connection = ReconnectingBackend(device: wifi, executable: executable)
        XCTAssertTrue(try connection.stat("/Download").directory)
        connection.update(device: nil, executable: executable)
        let waiting = Task.detached { try connection.stat("/Download") }
        try await Task.sleep(nanoseconds: 150_000_000)
        connection.update(device: usb, executable: executable)
        let resumed = try await waiting.value
        XCTAssertTrue(resumed.directory)
        connection.update(device: wifi, executable: executable)
        XCTAssertTrue(try connection.stat("/Download").directory)
        connection.stop()
    }

    func testSafeMountCleanup() async throws {
        let directory = root.appendingPathComponent("mount-point")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("must-keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertFalse(FinderMount.removeEmptyDirectory(directory))
        XCTAssertThrowsError(try FinderMount.mount(URL(string: "http://127.0.0.1:1/test/")!, at: directory, name: "test", helper: "/usr/bin/false"), "Failed mount must not remove nonempty directories")
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        try FileManager.default.removeItem(at: sentinel)
        XCTAssertTrue(FinderMount.removeEmptyDirectory(directory))
    }
    func testRealPhoneFinderMount() async throws {
        guard ProcessInfo.processInfo.environment["MACDROID_TEST_MOUNT"] == "1", let executable = ProcessInfo.processInfo.environment["MACDROID_ADB_PATH"], let serial = ProcessInfo.processInfo.environment["MACDROID_TEST_SERIAL"] else { throw XCTSkip("Enable real-device and mount checks together.") }
        let devices = try DeviceDiscovery.scan(executable: executable, knownIDs: [], reconnect: false)
        let device = try XCTUnwrap(devices.first { $0.endpoint == serial })
        let connection = ReconnectingBackend(device: device, executable: executable)
        let recovery = RecoveryStore(backend: connection)
        server.stop()
        server = WebDAVServer(backend: RecoverableBackend(base: connection, recovery: recovery))
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FinderMount.eject(mount) }
        try FinderMount.mount(base, at: mount, name: device.name)
        let listing = try FileManager.default.contentsOfDirectory(atPath: mount.path)
        XCTAssertTrue(listing.contains("Download"))
        XCTAssertTrue(listing.contains("DCIM"))
        XCTAssertTrue(try FinderMount.isMounted(mount))
        try FinderMount.eject(mount)
        XCTAssertFalse(try FinderMount.isMounted(mount))
    }

    func testHTTPTransferProgressAndCancellation() async throws {
        server.stop()
        let center = TransferCenter()
        server = WebDAVServer(backend: LocalBackend(root: root), transfers: center)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        let data = Data(repeating: 0x53, count: 512_000)
        try await request("PUT", "complete.bin", data: data, status: 201)
        let downloaded = try await request("GET", "complete.bin", status: 200)
        XCTAssertEqual(downloaded, data)
        XCTAssertEqual(center.snapshots.first?.completed, UInt64(data.count))
        XCTAssertEqual(center.snapshots.first?.outcome, "Complete")
        center.clearFinished()
        let source = root.appendingPathComponent("slow-source")
        try Data(repeating: 0x61, count: 2_000_000).write(to: source)
        let destination = base.appendingPathComponent("cancelled.bin").absoluteString
        let task = Task.detached {
            try Command.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--limit-rate", "64k", "-T", source.path, destination], timeout: 10)
        }
        for _ in 0..<50 {
            if let transfer = center.snapshots.first(where: { $0.active && $0.completed > 0 }) { center.cancel(transfer.id); break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        do { _ = try await task.value; XCTAssertTrue(false) } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.bin").path))
        XCTAssertEqual(center.snapshots.first?.outcome, "Cancelled")
    }

    func testStorageParsing() async throws {
        let info = try StorageInfo.parseDF("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/fuse 1000 600 400 60% /storage/emulated\n")
        XCTAssertEqual(info.total, 1_024_000)
        XCTAssertEqual(info.available, 409_600)
        XCTAssertEqual(info.usedFraction, 0.6)
        XCTAssertThrowsError(try StorageInfo.parseDF("/dev/fuse 0 0 0 0% /sdcard"), "Zero capacity is invalid")
        XCTAssertThrowsError(try StorageInfo.parseDF("/dev/fuse 10 11 10 99% /sdcard"), "Invalid capacity is rejected")
        XCTAssertThrowsError(try StorageInfo.parseDF("/dev/fuse 18446744073709551615 1 1 1% /sdcard"), "Overflow is rejected")
    }

    func testRecoverableDeletion() async throws {
        let backend = LocalBackend(root: root)
        let store = RecoveryStore(backend: backend)
        let safe = RecoverableBackend(base: backend, recovery: store)
        try backend.mkdir("/Documents")
        let file = root.appendingPathComponent("Documents/hello café.txt")
        try Data("keep this".utf8).write(to: file)
        try safe.delete("/Documents/hello café.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let items = try store.items()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.originalPath, "/Documents/hello café.txt")
        try Data("new version".utf8).write(to: file)
        XCTAssertThrowsError(try store.restore(item), "Restore must not overwrite a newer file")
        XCTAssertEqual(try String(contentsOf: file), "new version")
        try FileManager.default.removeItem(at: file)
        try store.restore(item)
        XCTAssertEqual(try String(contentsOf: file), "keep this")
        XCTAssertTrue(try store.items().isEmpty)
        try safe.delete("/Documents")
        let folder = try XCTUnwrap(store.items().first)
        XCTAssertTrue(folder.directory)
        try store.restore(folder)
        XCTAssertEqual(try String(contentsOf: file), "keep this")
        XCTAssertThrowsError(try safe.delete("/"), "Storage root is protected")
        XCTAssertThrowsError(try safe.delete(RecoveryStore.root), "Recovery folder is protected")
        XCTAssertThrowsError(try safe.move("/Documents", to: RecoveryStore.root + "/stolen", overwrite: false), "Cannot mutate recovery directly")
        XCTAssertFalse(RecoveryStore.validOriginal("/../private"))
        XCTAssertFalse(RecoveryStore.validOriginal(RecoveryStore.root + "/file"))
        server.stop()
        server = WebDAVServer(backend: safe)
        base = try await withCheckedThrowingContinuation { continuation in
            do { try server.start { continuation.resume(with: $0) } } catch { continuation.resume(throwing: error) }
        }
        try await request("DELETE", "Documents/hello café.txt", status: 204)
        XCTAssertEqual(try store.items().count, 1)
    }

    func testTransferCancellation() async throws {
        let center = TransferCenter()
        let transfer = center.begin(path: "/Download/example.bin", direction: "Mac → Phone")
        transfer.stage("Writing to phone", total: 100)
        transfer.progress(25)
        XCTAssertEqual(transfer.snapshot.fraction, 0.25)
        transfer.progress(300, phase: "Wrong stage")
        XCTAssertEqual(transfer.snapshot.completed, 25)
        let began = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { transfer.cancel() }
        do {
            _ = try Command.run("/bin/sleep", ["10"], cancellation: transfer.cancellation)
            XCTAssertTrue(false)
        } catch is CancellationError { transfer.finish() } catch { throw error }
        XCTAssertTrue(Date().timeIntervalSince(began) < 3)
        XCTAssertEqual(transfer.snapshot.outcome, "Cancelled")
        XCTAssertFalse(transfer.snapshot.active)
        center.clearFinished()
        XCTAssertTrue(center.snapshots.isEmpty)
        for _ in 0..<45 { center.begin(path: "/test", direction: "test").finish() }
        XCTAssertTrue(center.snapshots.count <= 40)
    }

    func testReconnectPolicy() async throws {
        let usb = AndroidDevice(endpoint: "phone-A", hardwareID: "phone-A", name: "Redmi", wireless: false)
        let wifi = AndroidDevice(endpoint: "192.168.1.4:4000", hardwareID: "phone-A", name: "Redmi", wireless: true)
        let other = AndroidDevice(endpoint: "other", hardwareID: "phone-B", name: "Other", wireless: false)
        XCTAssertEqual(DeviceDiscovery.preferred([other, wifi, usb], hardwareID: "phone-A", currentEndpoint: wifi.endpoint), wifi)
        XCTAssertEqual(DeviceDiscovery.preferred([other, usb], hardwareID: "phone-A", currentEndpoint: wifi.endpoint), usb)
        XCTAssertEqual(DeviceDiscovery.preferred([other], hardwareID: "phone-A", currentEndpoint: wifi.endpoint), nil)
        XCTAssertEqual(DeviceDiscovery.authorizedEndpoints("List of devices attached\nphone-A\tdevice\nblocked\tunauthorized\noff\toffline\n"), ["phone-A"])
        let services = "adb-phone-A-abc\t_adb-tls-connect._tcp.\t192.168.1.8:5000\nadb-phone-B-def\t_adb-tls-connect._tcp.\t192.168.1.9:6000\nadb-phone-A-abc\t_adb-tls-pairing._tcp.\t192.168.1.8:7000"
        XCTAssertEqual(DeviceDiscovery.wirelessEndpoints(services, knownIDs: ["phone-A"]), ["192.168.1.8:5000"])
        XCTAssertEqual(DeviceDiscovery.wirelessEndpoints(services.replacingOccurrences(of: "._tcp.", with: "._tcp"), knownIDs: ["phone-A"]), ["192.168.1.8:5000"])
        XCTAssertEqual(usb.label, "Redmi — USB")
        XCTAssertEqual(wifi.label, "Redmi — Wi-Fi")
        let backend = ReconnectingBackend(device: usb, executable: "/no-adb")
        backend.stop()
        XCTAssertThrowsError(try backend.stat("/"), "Stopped reconnect backend rejects file access")
    }

    func testScreenMirrorCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("scrcpy")
        let adb = root.appendingPathComponent("adb")
        try Data("tool".utf8).write(to: tool)
        try Data("adb".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        XCTAssertNil(ScreenMirror.locate(candidates: [root.appendingPathComponent("missing").path]))
        XCTAssertEqual(ScreenMirror.locate(candidates: [tool.path]), tool.path)
        XCTAssertEqual(ScreenMirror.resolve(preferred: "/missing/scrcpy", candidates: [tool.path]), tool.path)
        XCTAssertEqual(ScreenMirror.resolve(preferred: tool.path, candidates: [root.appendingPathComponent("missing").path]), tool.path)
        XCTAssertFalse(ScreenMirror.validSerial(""))
        XCTAssertFalse(ScreenMirror.validSerial("-serial"))
        XCTAssertFalse(ScreenMirror.validSerial("phone one"))
        XCTAssertTrue(ScreenMirror.validSerial("192.168.1.8:5555"))
        let server = root.appendingPathComponent("scrcpy-server")
        try Data("server".utf8).write(to: server)
        XCTAssertEqual(ScreenMirror.serverPath(executable: tool.path, bundleServer: nil), server.path)
        let prefix = root.appendingPathComponent("Cellar/scrcpy/1")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("share/scrcpy"), withIntermediateDirectories: true)
        let real = prefix.appendingPathComponent("bin/scrcpy")
        try Data("tool".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        let linked = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("scrcpy"), withDestinationURL: real)
        let share = prefix.appendingPathComponent("share/scrcpy/scrcpy-server")
        try Data("server".utf8).write(to: share)
        XCTAssertEqual(ScreenMirror.serverPath(executable: linked.appendingPathComponent("scrcpy").path, bundleServer: nil), share.path)
        let plan = try ScreenMirror.plan(executable: tool.path, adb: adb.path, serial: "192.168.1.8:5555", title: "Pixel\n8 — USB", server: server.path)
        XCTAssertEqual(plan.executable, tool.path)
        XCTAssertEqual(plan.arguments, ["--serial", "192.168.1.8:5555", "--stay-awake", "--window-title", "MacDroid — Pixel 8 — USB"])
        XCTAssertEqual(plan.environment["ADB"], adb.path)
        XCTAssertEqual(plan.environment["SCRCPY_SERVER_PATH"], server.path)
        let withoutServer = try ScreenMirror.plan(executable: tool.path, adb: adb.path, serial: "phone-A", title: " ", server: nil)
        XCTAssertNil(withoutServer.environment["SCRCPY_SERVER_PATH"])
        XCTAssertEqual(withoutServer.arguments.last, "MacDroid — Android")
        XCTAssertThrowsError(try ScreenMirror.plan(executable: "/no/scrcpy", adb: adb.path, serial: "phone-A", title: "Pixel", server: nil), "Missing scrcpy is rejected")
        XCTAssertThrowsError(try ScreenMirror.plan(executable: tool.path, adb: "/no/adb", serial: "phone-A", title: "Pixel", server: nil), "Missing adb is rejected")
        XCTAssertThrowsError(try ScreenMirror.plan(executable: tool.path, adb: adb.path, serial: "bad serial", title: "Pixel", server: nil), "Unsafe serials are rejected")
        XCTAssertTrue(ScreenMirror.missingToolMessage.contains("brew install scrcpy"))
    }
}
