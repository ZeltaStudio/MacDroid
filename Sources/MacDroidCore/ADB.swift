import Foundation

public struct AppError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Command {
    /// Output is spooled to disk so a large transfer cannot fill a pipe and deadlock.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120, cancellation: CancellationToken? = nil, onTick: (() -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        if let cancellation { try cancellation.launch(process) } else { try process.run() }
        defer { cancellation?.remove(process) }
        let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MacDroid.TransferProgress"))
        progressTimer.schedule(deadline: .now(), repeating: 0.75)
        progressTimer.setEventHandler { onTick?() }
        progressTimer.resume()
        defer { progressTimer.cancel() }
        let timeoutLock = NSLock()
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            timeoutLock.lock(); timedOut = true; timeoutLock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        // Wait on the launching thread: Foundation must pump that thread’s process run loop.
        process.waitUntilExit()
        timer.cancel()
        timeoutLock.lock(); let didTimeOut = timedOut; timeoutLock.unlock()
        if didTimeOut { throw AppError("The operation timed out. Check the phone’s Wi-Fi and wireless debugging.") }
        try cancellation?.check()
        let output = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
}

public struct RemoteEntry {
    public let path: String
    public let directory: Bool
    public let size: UInt64
    public let modified: Date
    public init(path: String, directory: Bool, size: UInt64, modified: Date) {
        self.path = path; self.directory = directory; self.size = size; self.modified = modified
    }
}

public protocol FileBackend {
    func storage() throws -> StorageInfo?
    func stat(_ path: String) throws -> RemoteEntry
    func list(_ path: String) throws -> [RemoteEntry]
    func download(_ path: String, to local: URL, transfer: TransferOperation?) throws
    func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws
    func mkdir(_ path: String) throws
    func delete(_ path: String) throws
    func move(_ path: String, to destination: String, overwrite: Bool) throws
}

public extension FileBackend {
    func storage() throws -> StorageInfo? { nil }
    func download(_ path: String, to local: URL) throws { try download(path, to: local, transfer: nil) }
    func upload(_ local: URL, to path: String) throws { try upload(local, to: path, transfer: nil) }
}

public final class ADB: FileBackend, Sendable {
    public let executable: String
    public let serial: String
    public init(executable: String, serial: String) { self.executable = executable; self.serial = serial }
    public static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [Bundle.main.path(forResource: "adb", ofType: nil), "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(home)/Library/Android/sdk/platform-tools/adb"].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public func run(_ arguments: [String], timeout: TimeInterval = 120) throws -> String {
        try Command.run(executable, (serial.isEmpty ? [] : ["-s", serial]) + arguments, timeout: timeout)
    }
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func remote(_ path: String) -> String { Self.quote("/sdcard" + path) }
    private func shell(_ command: String) throws -> String { try run(["shell", command]) }
    private let format = "%f|%s|%Y|%n"
    private func parse(_ row: Substring) throws -> RemoteEntry {
        let parts = row.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let mode = UInt32(parts[0], radix: 16), let size = UInt64(parts[1]), let seconds = Double(parts[2]), parts[3].hasPrefix("/sdcard") else { throw AppError("Unexpected Android file metadata.") }
        let path = String(parts[3].dropFirst(7))
        return RemoteEntry(path: path.isEmpty ? "/" : path, directory: mode & 0xf000 == 0x4000, size: size, modified: Date(timeIntervalSince1970: seconds))
    }
    public func storage() throws -> StorageInfo? { try StorageInfo.parseDF(run(["shell", "df -k /sdcard"], timeout: 5)) }
    public func stat(_ path: String) throws -> RemoteEntry {
        let result = try shell("stat -L -c '\(format)' -- \(remote(path))")
        guard !result.isEmpty else { throw AppError("File not found.") }
        return try parse(Substring(result.hasSuffix("\n") ? String(result.dropLast()) : result))
    }
    public func list(_ path: String) throws -> [RemoteEntry] {
        // NUL records preserve spaces, quotes, pipes and newlines in file names.
        let result = try shell("find \(remote(path)) -mindepth 1 -maxdepth 1 -exec stat -L -c '\(format)' -- {} \\; -exec printf '\\0' \\;")
        return try result.split(separator: "\0").map { try parse(Substring($0.hasSuffix("\n") ? $0.dropLast() : $0)) }
    }
    public func download(_ path: String, to local: URL, transfer: TransferOperation?) throws {
        let size = try stat(path).size
        transfer?.stage("Reading from phone", total: size)
        _ = try Command.run(executable, ["-s", serial, "pull", "/sdcard" + path, local.path], timeout: 3600, cancellation: transfer?.cancellation, onTick: {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
            transfer?.progress(bytes, phase: "Reading from phone")
        })
        transfer?.progress(size)
    }
    public func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws {
        // Upload beside the destination, then rename so interrupted transfers do not truncate it.
        let parent = (path as NSString).deletingLastPathComponent
        let staging = parent + "/.macdroid-" + UUID().uuidString
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
            transfer?.stage("Writing to phone", total: size)
            _ = try Command.run(executable, ["-s", serial, "push", local.path, "/sdcard" + staging], timeout: 3600, cancellation: transfer?.cancellation, onTick: {
                if transfer != nil, let bytes = try? self.run(["shell", "stat -c %s -- " + self.remote(staging)], timeout: 2) {
                    transfer?.progress(UInt64(bytes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, phase: "Writing to phone")
                }
            })
            try transfer?.cancellation.check()
            transfer?.progress(size)
            _ = try shell("mv -f -- \(remote(staging)) \(remote(path))")
        } catch { _ = try? shell("rm -f -- \(remote(staging))"); throw error }
    }
    public func mkdir(_ path: String) throws { _ = try shell("mkdir -- \(remote(path))") }
    public func delete(_ path: String) throws {
        guard path != "/" else { throw AppError("Cannot delete shared storage.") }
        _ = try shell("rm -rf -- \(remote(path))")
    }
    public func move(_ path: String, to destination: String, overwrite: Bool) throws {
        guard path != "/", destination != "/" else { throw AppError("Cannot move shared storage.") }
        if !overwrite, (try? stat(destination)) != nil { throw AppError("Destination already exists.") }
        _ = try shell("mv \(overwrite ? "-f" : "-n") -- \(remote(path)) \(remote(destination))")
        if !overwrite, (try? stat(path)) != nil { throw AppError("The destination changed during the move. Nothing was overwritten.") }
    }
}
