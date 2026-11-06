import Foundation

/// Builds a scrcpy launch for the phone already selected over ADB.
/// The tool is optional: file browsing keeps working when it is absent.
public struct ScreenMirrorPlan: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }
}

public enum ScreenMirror {
    public static let missingToolMessage = "scrcpy isn’t installed. Install it with Homebrew (brew install scrcpy) or choose the scrcpy executable. Finder still works without it."

    public static func defaultCandidates(bundleExecutable: String? = Bundle.main.path(forResource: "scrcpy", ofType: nil), home: String? = nil) -> [String] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        return [bundleExecutable, "/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy", "/opt/local/bin/scrcpy", home + "/bin/scrcpy"].compactMap { $0 }
    }

    /// `preferred` wins when it is still executable; otherwise the usual install locations are searched.
    public static func resolve(preferred: String?, candidates: [String]? = nil) -> String? {
        if let preferred, !preferred.isEmpty, isTool(preferred) { return preferred }
        return locate(candidates: candidates)
    }

    public static func locate(candidates: [String]? = nil) -> String? {
        (candidates ?? defaultCandidates()).first(where: isTool)
    }

    public static func isTool(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Homebrew keeps the server beside the resolved binary; a bundled copy sits next to the executable.
    public static func serverPath(executable: String, bundleServer: String? = Bundle.main.path(forResource: "scrcpy-server", ofType: nil)) -> String? {
        let given = URL(fileURLWithPath: executable)
        let resolved = given.resolvingSymlinksInPath()
        let prefix = resolved.deletingLastPathComponent().deletingLastPathComponent()
        // URL.path is ambiguous with path(percentEncoded:) on newer SDKs. NSURL.path is the file path.
        let candidates = [
            filesystemPath(given.deletingLastPathComponent().appendingPathComponent("scrcpy-server")),
            filesystemPath(resolved.deletingLastPathComponent().appendingPathComponent("scrcpy-server")),
            filesystemPath(prefix.appendingPathComponent("share/scrcpy/scrcpy-server")),
            bundleServer
        ].compactMap { $0 }
        return candidates.first(where: isReadableFile)
    }

    public static func validSerial(_ serial: String) -> Bool {
        !serial.isEmpty && serial.count <= 128 && !serial.hasPrefix("-")
            && !serial.contains(where: { $0.isWhitespace || $0 == "\0" || $0 == "'" || $0 == "\"" })
    }

    public static func sanitizedTitle(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\0", with: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Android" : trimmed
        return "MacDroid — " + String(value.prefix(80))
    }

    public static func plan(executable: String, adb: String, serial: String, title: String, server: String? = nil) throws -> ScreenMirrorPlan {
        guard isTool(executable) else { throw AppError(missingToolMessage) }
        guard isTool(adb) else { throw AppError("ADB is required to mirror the screen. Select adb and connect the phone first.") }
        guard validSerial(serial) else { throw AppError("Select a phone before mirroring its screen.") }
        var environment = ["ADB": adb]
        if let server, isReadableFile(server) { environment["SCRCPY_SERVER_PATH"] = server }
        let arguments = ["--serial", serial, "--stay-awake", "--window-title", sanitizedTitle(title)]
        return ScreenMirrorPlan(executable: executable, arguments: arguments, environment: environment)
    }

    private static func filesystemPath(_ url: URL) -> String { (url as NSURL).path ?? "" }
    private static func isReadableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isReadableFile(atPath: path)
    }
}
