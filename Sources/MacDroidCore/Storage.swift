import Foundation

public struct StorageInfo: Equatable, Sendable {
    public let total: UInt64
    public let available: UInt64
    public var used: UInt64 { total - available }
    public var usedFraction: Double { Double(used) / Double(total) }
    public static func parseDF(_ output: String) throws -> StorageInfo {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6, let totalKB = UInt64(fields[1]), let usedKB = UInt64(fields[2]), let availableKB = UInt64(fields[3]),
                  totalKB > 0, usedKB <= totalKB, availableKB <= totalKB else { continue }
            let (total, totalOverflow) = totalKB.multipliedReportingOverflow(by: 1024)
            let (available, freeOverflow) = availableKB.multipliedReportingOverflow(by: 1024)
            guard !totalOverflow, !freeOverflow else { continue }
            return StorageInfo(total: total, available: available)
        }
        throw AppError("The phone did not return usable storage information.")
    }
}
