import Foundation
import UniformTypeIdentifiers

struct HTTPFileRepresentation {
    let size: UInt64
    let modified: Date
    let contentType: String
    var etag: String { "\"\(size)-\(Int(modified.timeIntervalSince1970))\"" }
    var headers: [String: String] {
        ["Accept-Ranges": "bytes", "ETag": etag, "Last-Modified": Self.dateString(modified), "Content-Type": contentType]
    }
    init(entry: RemoteEntry) {
        size = entry.size; modified = entry.modified
        contentType = UTType(filenameExtension: (entry.path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
    static func dateString(_ date: Date) -> String { dateFormatter().string(from: date) }
    func unchanged(headers: [String: String]) -> Bool {
        if let condition = headers["if-none-match"] {
            return condition.split(separator: ",").contains {
                let value = $0.trimmingCharacters(in: .whitespaces)
                return value == "*" || value == etag || value == "W/" + etag
            }
        }
        if let value = headers["if-modified-since"], let date = Self.dateFormatter().date(from: value) {
            return Int(modified.timeIntervalSince1970) <= Int(date.timeIntervalSince1970)
        }
        return false
    }
    func range(headers: [String: String]) -> HTTPFileRange {
        if let condition = headers["if-range"] {
            if condition != etag {
                guard let date = Self.dateFormatter().date(from: condition),
                      Int(modified.timeIntervalSince1970) == Int(date.timeIntervalSince1970) else { return .full }
            }
        }
        return HTTPFileRange.parse(headers["range"], size: size)
    }
}

enum HTTPFileRange {
    case full
    case partial(offset: UInt64, length: UInt64)
    case unsatisfiable

    static func parse(_ value: String?, size: UInt64) -> HTTPFileRange {
        guard let value else { return .full }
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else { return .full }
        let specification = parts[1].trimmingCharacters(in: .whitespaces)
        // Multi-range responses are optional. Ignore unsupported or malformed ranges and send the whole file.
        guard !specification.contains(",") else { return .full }
        let bounds = specification.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .full }
        if bounds[0].isEmpty {
            guard let suffix = UInt64(bounds[1]) else { return .full }
            guard size > 0, suffix > 0 else { return .unsatisfiable }
            let length = min(size, suffix)
            return .partial(offset: size - length, length: length)
        }
        guard let first = UInt64(bounds[0]) else { return .full }
        var last: UInt64?
        if !bounds[1].isEmpty {
            guard let end = UInt64(bounds[1]), end >= first else { return .full }
            last = end
        }
        guard first < size else { return .unsatisfiable }
        let end = min(last ?? (size - 1), size - 1)
        return .partial(offset: first, length: end - first + 1)
    }
}
