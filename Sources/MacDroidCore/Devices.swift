import Foundation

public struct AndroidDevice: Identifiable, Equatable, Sendable {
    public var id: String { endpoint }
    public let endpoint: String
    public let hardwareID: String
    public let name: String
    public let wireless: Bool
    public var label: String { "\(name) — \(wireless ? "Wi-Fi" : "USB")" }
    public init(endpoint: String, hardwareID: String, name: String, wireless: Bool) {
        self.endpoint = endpoint; self.hardwareID = hardwareID; self.name = name; self.wireless = wireless
    }
}

public enum DeviceDiscovery {
    public static func authorizedEndpoints(_ output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
    }
    public static func wirelessEndpoints(_ output: String, knownIDs: Set<String>) -> [String] {
        output.components(separatedBy: .newlines).compactMap {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "_adb-tls-connect._tcp",
                  knownIDs.contains(where: { fields[0].hasPrefix("adb-" + $0 + "-") }) else { return nil }
            return String(fields[2])
        }
    }
    public static func preferred(_ devices: [AndroidDevice], hardwareID: String, currentEndpoint: String?) -> AndroidDevice? {
        let matches = devices.filter { $0.hardwareID == hardwareID }
        // Keep a working connection instead of disrupting an in-flight transfer to switch transports.
        return matches.first { $0.endpoint == currentEndpoint } ?? matches.first { !$0.wireless } ?? matches.first
    }
    public static func validEndpoint(_ value: String) -> Bool {
        guard !value.hasPrefix("-"), !value.contains(where: \.isWhitespace),
              let url = URLComponents(string: "http://" + value), let host = url.host, !host.isEmpty,
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        return true
    }
    public static func scan(executable: String, knownIDs: Set<String>, reconnect: Bool, savedEndpoint: String? = nil) throws -> [AndroidDevice] {
        let host = ADB(executable: executable, serial: "")
        if reconnect, !knownIDs.isEmpty {
            let services = (try? host.run(["mdns", "services"], timeout: 5)) ?? ""
            let connected = authorizedEndpoints((try? host.run(["devices"], timeout: 5)) ?? "")
            var endpoints = wirelessEndpoints(services, knownIDs: knownIDs)
            if let savedEndpoint, validEndpoint(savedEndpoint), !endpoints.contains(savedEndpoint) { endpoints.append(savedEndpoint) }
            for endpoint in endpoints where !connected.contains(endpoint) && validEndpoint(endpoint) {
                _ = try? host.run(["connect", endpoint], timeout: 4)
            }
        }
        return try authorizedEndpoints(host.run(["devices"], timeout: 5)).compactMap { endpoint in
            let adb = ADB(executable: executable, serial: endpoint)
            // Read identity every scan: an IP:port can later belong to a different phone.
            guard let properties = try? adb.run(["shell", "getprop ro.serialno; getprop ro.product.marketname; getprop ro.product.model; getprop ro.product.manufacturer"], timeout: 5) else { return nil }
            let lines = properties.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard lines.count >= 4 else { return nil }
            let wireless = endpoint.contains(":") || endpoint.contains("._adb-tls-connect.")
            let identity = lines[0].isEmpty ? (wireless ? "" : endpoint) : lines[0]
            guard !identity.isEmpty else { return nil }
            let name = !lines[1].isEmpty ? lines[1] : [lines[3].capitalized, lines[2]].filter { !$0.isEmpty }.joined(separator: " ")
            return AndroidDevice(endpoint: endpoint, hardwareID: identity, name: name.isEmpty ? "Android phone" : name, wireless: wireless)
        }
    }
}

/// Keeps a Finder mount attached to the same physical phone as its address/transport changes.
/// Waiting operations resume on reconnection; they never fall through to a different phone.
public final class ReconnectingBackend: FileBackend, @unchecked Sendable {
    private let condition = NSCondition()
    private var backend: ADB?
    private var stopped = false
    public let hardwareID: String
    public init(device: AndroidDevice, executable: String) {
        hardwareID = device.hardwareID; backend = ADB(executable: executable, serial: device.endpoint)
    }
    public func update(device: AndroidDevice?, executable: String) {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { return }
        backend = device.flatMap { $0.hardwareID == hardwareID ? ADB(executable: executable, serial: $0.endpoint) : nil }
        condition.broadcast()
    }
    public func stop() { condition.lock(); stopped = true; backend = nil; condition.broadcast(); condition.unlock() }
    private func connected() throws -> ADB {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(20)
        while backend == nil && !stopped {
            if !condition.wait(until: deadline) { break }
        }
        guard !stopped, let backend else { throw AppError("Phone disconnected. Waiting for the same phone to return; do not start new transfers yet.") }
        return backend
    }
    public func storage() throws -> StorageInfo? { try connected().storage() }
    public func stat(_ path: String) throws -> RemoteEntry { try connected().stat(path) }
    public func list(_ path: String) throws -> [RemoteEntry] { try connected().list(path) }
    public func download(_ path: String, to local: URL, transfer: TransferOperation?) throws { try connected().download(path, to: local, transfer: transfer) }
    public func upload(_ local: URL, to path: String, transfer: TransferOperation?) throws { try connected().upload(local, to: path, transfer: transfer) }
    public func mkdir(_ path: String) throws { try connected().mkdir(path) }
    public func delete(_ path: String) throws { try connected().delete(path) }
    public func move(_ path: String, to destination: String, overwrite: Bool) throws { try connected().move(path, to: destination, overwrite: overwrite) }
}
