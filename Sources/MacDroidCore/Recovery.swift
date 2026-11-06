import Foundation

public struct RecoveryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let originalPath: String
    public let deletedAt: Date
    public let directory: Bool
    public var name: String { (originalPath as NSString).lastPathComponent }
    public init(id: String, originalPath: String, deletedAt: Date, directory: Bool) {
        self.id = id; self.originalPath = originalPath; self.deletedAt = deletedAt; self.directory = directory
    }
}

/// Optional age limit for recovered deletions. Disabled leaves every item on the phone.
public struct RecoveryRetention: Equatable, Sendable {
    public static let minimumDays = 1
    public static let maximumDays = 365
    public let enabled: Bool
    public let days: Int
    public init(enabled: Bool, days: Int) {
        self.enabled = enabled
        self.days = min(Self.maximumDays, max(Self.minimumDays, days))
    }
    public func expires(deletedAt: Date, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        return deletedAt.addingTimeInterval(TimeInterval(days) * 86_400) <= now
    }
}

public final class RecoveryStore: @unchecked Sendable {
    public static let root = "/.MacDroid Recovery"
    private let backend: FileBackend
    private let lock = NSRecursiveLock()
    public init(backend: FileBackend) { self.backend = backend }
    public static func protected(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    public static func validOriginal(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\0") && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) && !protected(path)
    }
    private func container(_ id: String) -> String { Self.root + "/" + id }
    private func payload(_ item: RecoveryItem) -> String { container(item.id) + "/contents/" + item.name }
    @discardableResult
    public func recover(_ path: String) throws -> RecoveryItem {
        lock.lock(); defer { lock.unlock() }
        guard Self.validOriginal(path) else { throw AppError("The recovery folder and storage root are protected. Restore recovered files using MacDroid.") }
        let entry = try backend.stat(path)
        let item = RecoveryItem(id: UUID().uuidString, originalPath: path, deletedAt: Date(), directory: entry.directory)
        if (try? backend.stat(Self.root)) == nil { try backend.mkdir(Self.root) }
        let folder = container(item.id)
        try backend.mkdir(folder)
        do {
            try backend.mkdir(folder + "/contents")
            let metadata = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: metadata) }
            try JSONEncoder().encode(item).write(to: metadata)
            try backend.upload(metadata, to: folder + "/.macdroid-recovery.json")
            try backend.move(path, to: payload(item), overwrite: false)
        } catch {
            // Never delete a successfully moved payload even if the underlying transport reports a late error.
            if (try? backend.stat(payload(item))) == nil { try? backend.delete(folder) }
            throw error
        }
        return item
    }
    public func items() throws -> [RecoveryItem] {
        lock.lock(); defer { lock.unlock() }
        guard (try? backend.stat(Self.root)) != nil else { return [] }
        var result: [RecoveryItem] = []
        for entry in try backend.list(Self.root) where entry.directory {
            let id = (entry.path as NSString).lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            let manifest = entry.path + "/.macdroid-recovery.json"
            guard let info = try? backend.stat(manifest), info.size < 65536 else { continue }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: local) }
            do {
                try backend.download(manifest, to: local)
                let item = try JSONDecoder().decode(RecoveryItem.self, from: Data(contentsOf: local))
                guard item.id == id, Self.validOriginal(item.originalPath), (try? backend.stat(payload(item))) != nil else { continue }
                result.append(item)
            } catch { continue }
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }
    public func restore(_ item: RecoveryItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: item.id) != nil, Self.validOriginal(item.originalPath) else { throw AppError("Invalid recovery record.") }
        guard (try? backend.stat(item.originalPath)) == nil else { throw AppError("A file already exists at \(item.originalPath). Rename it before restoring; nothing was overwritten.") }
        let parent = (item.originalPath as NSString).deletingLastPathComponent
        guard let parentEntry = try? backend.stat(parent), parentEntry.directory else { throw AppError("Recreate the original folder \(parent) before restoring this item.") }
        try backend.move(payload(item), to: item.originalPath, overwrite: false)
        // Only metadata remains after a successful move. Cleanup failure must not undo a restored file.
        try? backend.delete(container(item.id))
    }
    /// Permanently removes one recovered item. The id must be the record’s own UUID.
    public func purge(_ item: RecoveryItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: item.id) != nil else { throw AppError("Invalid recovery record.") }
        let folder = container(item.id)
        if (try? backend.stat(folder)) == nil { return }
        try backend.delete(folder)
    }
    /// Permanently removes every recovery record. Other phone files are left in place.
    public func empty() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard (try? backend.stat(Self.root)) != nil else { return 0 }
        var count = 0
        for entry in try backend.list(Self.root) where entry.directory {
            let id = (entry.path as NSString).lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            try backend.delete(entry.path)
            count += 1
        }
        return count
    }
    /// Deletes recovered items older than the retention period. A disabled policy deletes nothing.
    public func purgeExpired(retention: RecoveryRetention, now: Date = Date()) throws -> Int {
        guard retention.enabled else { return 0 }
        let stale = try items().filter { retention.expires(deletedAt: $0.deletedAt, now: now) }
        for item in stale { try purge(item) }
        return stale.count
    }
}

public final class RecoverableBackend: FileBackend {
    private let base: FileBackend
    public let recovery: RecoveryStore
    public init(base: FileBackend, recovery: RecoveryStore) { self.base = base; self.recovery = recovery }
    private func writable(_ path: String) throws {
        guard !RecoveryStore.protected(path) else { throw AppError("Recovery files are protected. Use Restore in MacDroid.") }
    }
    public func storage() throws -> StorageInfo? { try base.storage() }
    public func stat(_ path: String) throws -> RemoteEntry { try base.stat(path) }
    public func list(_ path: String) throws -> [RemoteEntry] { try base.list(path) }
    public func download(_ path: String, to local: URL, transfer: TransferOperation?) throws { try base.download(path, to: local, transfer: transfer) }
    public func downloadRange(_ path: String, offset: UInt64, length: UInt64, to local: URL, transfer: TransferOperation?) throws {
        try base.downloadRange(path, offset: offset, length: length, to: local, transfer: transfer)
    }
    public func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws { try writable(path); try base.upload(local, to: path, transfer: transfer) }
    public func mkdir(_ path: String) throws { try writable(path); try base.mkdir(path) }
    public func delete(_ path: String) throws { _ = try recovery.recover(path) }
    public func move(_ path: String, to destination: String, overwrite: Bool) throws {
        try writable(path); try writable(destination); try base.move(path, to: destination, overwrite: overwrite)
    }
}
