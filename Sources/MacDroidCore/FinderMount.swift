import Foundation
import Darwin

public enum FinderMount {
    private static func canonicalPath(_ directory: URL) -> String {
        // Foundation deliberately preserves /var aliases on macOS; mount(8) reports /private/var.
        let parent = directory.deletingLastPathComponent().path
        guard let resolved = realpath(parent, nil) else { return directory.path }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + directory.lastPathComponent
    }
    public static func isMounted(_ directory: URL) throws -> Bool {
        let mounts = try Command.run("/sbin/mount", [], timeout: 5)
        let canonical = canonicalPath(directory)
        return [directory.path, canonical].contains { mounts.contains(" on " + $0 + " (") }
    }
    /// Never recursively remove a mount point: it can still expose the phone after a helper error.
    @discardableResult
    public static func removeEmptyDirectory(_ directory: URL) -> Bool { rmdir(directory.path) == 0 }
    public static func mount(_ url: URL, at directory: URL, name: String, helper: String = "/sbin/mount_webdav") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { _ = try Command.run(helper, ["-v", name, url.absoluteString, canonicalPath(directory)], timeout: 30) }
        catch {
            // The helper can report failure after creating the mount. Preserve that live volume.
            if (try? isMounted(directory)) == true { return }
            removeEmptyDirectory(directory)
            throw error
        }
    }
    public static func eject(_ directory: URL) throws {
        if try isMounted(directory) {
            do { _ = try Command.run("/sbin/umount", [canonicalPath(directory)], timeout: 15) }
            catch { _ = try Command.run("/usr/sbin/diskutil", ["unmount", canonicalPath(directory)], timeout: 20) }
        }
        guard try !isMounted(directory) else { throw AppError("The volume is still mounted. Close files in Finder and try Eject again.") }
        removeEmptyDirectory(directory)
    }
}
