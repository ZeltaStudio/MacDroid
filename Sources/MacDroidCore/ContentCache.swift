import Foundation

/// Finder and Quick Look never ask a WebDAV mount for a thumbnail property or a side preview.
/// `mount_webdav` turns their reads into ordinary HTTP Range requests. Replacing those bytes
/// with a smaller image would break opening the file, including the partial-read fix.
/// Small photos are therefore pulled once and reused. Larger files, especially video, answer
/// with the real bytes from the requested offset plus a short read-ahead.
public final class ContentCache: @unchecked Sendable {
    public static let smallFileLimit: UInt64 = 1_048_576
    public static let imageFullLimit: UInt64 = 8 * 1_048_576
    public static let readAhead: UInt64 = 1_048_576
    public static let maxWindow: UInt64 = 4 * 1_048_576
    /// A failed narrow read may fall back to a full pull only under this size.
    public static let fallbackFullLimit: UInt64 = 32 * 1_048_576
    public enum Plan: Equatable, Sendable {
        case complete
        case window(offset: UInt64, length: UInt64)
    }
    private struct Span { var offset: UInt64; var data: Data }
    private struct Entry { var size: UInt64; var modified: Int; var spans: [Span]; var used: Date }
    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    private var stored = 0
    private let capacity: Int
    public init(capacity: Int = 64 * 1024 * 1024) { self.capacity = capacity }
    public static func isImage(_ path: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"].contains((path as NSString).pathExtension.lowercased())
    }
    public static func plan(path: String, fileSize: UInt64, offset: UInt64, length: UInt64) -> Plan {
        let photo = isImage(path) && fileSize <= imageFullLimit
        if fileSize == 0 || fileSize <= smallFileLimit || photo || length > maxWindow || length == fileSize { return .complete }
        guard fileSize > offset, length > 0 else { return .window(offset: offset, length: 0) }
        return .window(offset: offset, length: min(max(length, readAhead), fileSize - offset))
    }
    public func read(path: String, size: UInt64, modified: Date, offset: UInt64, length: UInt64) -> Data? {
        guard length <= UInt64(Int.max), offset <= UInt64.max - length else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var entry = files[path], entry.size == size, entry.modified == stamp(modified) else { return nil }
        for span in entry.spans {
            let end = span.offset + UInt64(span.data.count)
            guard span.offset <= offset, end >= offset + length else { continue }
            let start = Int(offset - span.offset)
            entry.used = Date(); files[path] = entry
            return span.data.subdata(in: start..<(start + Int(length)))
        }
        return nil
    }
    public func store(path: String, size: UInt64, modified: Date, offset: UInt64, data: Data) {
        guard size == 0 || !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var entry = files[path] ?? Entry(size: size, modified: stamp(modified), spans: [], used: Date())
        if entry.size != size || entry.modified != stamp(modified) {
            stored -= entry.spans.reduce(0) { $0 + $1.data.count }
            entry = Entry(size: size, modified: stamp(modified), spans: [], used: Date())
        }
        let newEnd = offset + UInt64(data.count)
        entry.spans.removeAll { existing in
            let end = existing.offset + UInt64(existing.data.count)
            let overlaps = existing.offset < newEnd && offset < end
            if overlaps { stored -= existing.data.count }
            return overlaps
        }
        entry.spans.append(Span(offset: offset, data: data))
        entry.used = Date()
        stored += data.count
        files[path] = entry
        while stored > capacity, files.count > 1 {
            let candidates = files.filter { $0.key != path }
            guard let oldest = candidates.min(by: { $0.value.used < $1.value.used }) else { break }
            stored -= oldest.value.spans.reduce(0) { $0 + $1.data.count }
            files.removeValue(forKey: oldest.key)
        }
        if stored < 0 { stored = 0 }
    }
    public func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let keys = files.keys.filter { $0 == path || $0.hasPrefix(prefix) }
        for key in keys {
            if let entry = files.removeValue(forKey: key) { stored -= entry.spans.reduce(0) { $0 + $1.data.count } }
        }
        if stored < 0 { stored = 0 }
    }
    public func removeAll() { lock.lock(); files.removeAll(); stored = 0; lock.unlock() }
    private func stamp(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }
}
