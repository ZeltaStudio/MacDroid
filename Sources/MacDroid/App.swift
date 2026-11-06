import SwiftUI
import AppKit
import MacDroidCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.mountURL != nil || model.busy || model.transferCenter.snapshots.contains(where: \.active) {
            model.quitSafely(); return .terminateCancel
        }
        return .terminateNow
    }
}

@main
struct MacDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("MacDroid", id: "main") {
            ContentView(model: model).frame(minWidth: 800, minHeight: 640)
                .onAppear { delegate.model = model }
        }.windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("MacDroid", systemImage: "externaldrive.connected.to.line.below") {
            MacDroidMenu(model: model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var adbPath = ADB.locate() ?? ""
    @Published var mirroring = false
    private var mirrorProcess: Process?
    private var mirrorLogHandle: FileHandle?
    private var mirrorStopRequested = false
    @Published var pairAddress = ""
    @Published var pairingCode = ""
    @Published var connectAddress = UserDefaults.standard.string(forKey: "connectAddress") ?? ""
    @Published var devices: [AndroidDevice] = []
    @Published var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true { didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") } }
    @Published var selected = ""
    @Published var status = "Ready to connect your phone."
    @Published var busy = false
    @Published var error: String?
    @Published var mountURL: URL?
    @Published var mountPath: String?
    @Published var transfers: [TransferSnapshot] = []
    let transferCenter = TransferCenter()
    private var transferMonitor: Timer?
    private var server: WebDAVServer?
    private var reconnectingBackend: ReconnectingBackend?
    private var mountedDevice: AndroidDevice?
    private var recoveryStore: RecoveryStore?
    @Published var recoveryItems: [RecoveryItem] = []
    @Published var showingRecovery = false
    @Published var recoveryExpiryEnabled = UserDefaults.standard.bool(forKey: "recoveryExpiryEnabled") {
        didSet { UserDefaults.standard.set(recoveryExpiryEnabled, forKey: "recoveryExpiryEnabled"); applyRecoveryExpiry(force: true) }
    }
    @Published var recoveryExpiryDays: Int = {
        let stored = UserDefaults.standard.integer(forKey: "recoveryExpiryDays")
        return stored == 0 ? 30 : min(RecoveryRetention.maximumDays, max(RecoveryRetention.minimumDays, stored))
    }() {
        didSet {
            let clamped = min(RecoveryRetention.maximumDays, max(RecoveryRetention.minimumDays, recoveryExpiryDays))
            if clamped != recoveryExpiryDays { recoveryExpiryDays = clamped; return }
            UserDefaults.standard.set(clamped, forKey: "recoveryExpiryDays")
            applyRecoveryExpiry(force: true)
        }
    }
    private var expiryRunning = false
    private var expiryAgain = false
    private var lastExpiry = Date.distantPast
    @Published var storage: StorageInfo?
    private var storageLoading = false
    private var storageChecked = Date.distantPast
    private var monitor: Timer?
    private var polling = false
    private var started = false
    private var desiredDeviceID = UserDefaults.standard.string(forKey: "resumeDeviceID")
    private var knownIDs = Set(UserDefaults.standard.stringArray(forKey: "knownDeviceIDs") ?? [])
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // macOS tears down a disconnected WebDAV mount; also attempt normal unmount before exiting.
            MainActor.assumeIsolated {
                self?.stopMirroring()
                if let path = self?.mountPath { _ = try? Command.run("/sbin/umount", [path], timeout: 5) }
                self?.server?.stop()
            }
        }
    }
    func chooseADB() {
        let panel = NSOpenPanel(); panel.message = "Select adb from Android SDK Platform Tools"; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { adbPath = url.path }
    }
    private var mirrorDevice: AndroidDevice? {
        if let mountedDevice { return mountedDevice }
        return devices.first { $0.endpoint == selected }
    }
    func mirrorScreen() {
        guard let device = mirrorDevice else {
            error = "Select a phone before mirroring its screen."; showWindow(); return
        }
        let tool = ScreenMirror.resolve() ?? ""
        guard !tool.isEmpty else { error = ScreenMirror.missingToolMessage; showWindow(); return }
        guard !mirroring else { status = "Screen mirroring is already running."; return }
        do {
            let plan = try ScreenMirror.plan(executable: tool, adb: adbPath, serial: device.endpoint, title: device.label, server: ScreenMirror.serverPath(executable: tool))
            try launchMirror(plan, device: device)
        } catch {
            self.error = error.localizedDescription
            showWindow()
        }
    }
    private func launchMirror(_ plan: ScreenMirrorPlan, device: AndroidDevice) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("macdroid-scrcpy-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.environment { environment[key] = value }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        let session = MirrorSession()
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finishMirror(proc, log: log, session: session) }
        }
        do { try process.run() } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: log); throw error
        }
        mirrorLogHandle = handle
        mirrorProcess = process
        mirrorStopRequested = false
        mirroring = process.isRunning
        status = "Mirroring \(device.label). Use the scrcpy window to view and control the phone."
        if !process.isRunning { finishMirror(process, log: log, session: session) }
    }
    func stopMirroring() {
        guard mirroring || mirrorProcess?.isRunning == true else { return }
        mirrorStopRequested = true
        if let process = mirrorProcess, process.isRunning { process.terminate() }
        mirroring = false
        status = "Screen mirroring stopped."
    }
    private func finishMirror(_ process: Process, log: URL, session: MirrorSession) {
        guard !session.handled else { return }
        session.handled = true
        try? mirrorLogHandle?.close(); mirrorLogHandle = nil
        if mirrorProcess === process { mirrorProcess = nil }
        let stopped = mirrorStopRequested
        mirrorStopRequested = false
        mirroring = false
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: log)
        guard !stopped, process.terminationStatus != 0 else {
            if !busy { status = stopped ? "Screen mirroring stopped." : "Screen mirroring ended." }
            return
        }
        let detail = output.split(whereSeparator: \.isNewline).suffix(6).joined(separator: " ")
        error = detail.isEmpty ? "Screen mirroring stopped unexpectedly." : String(detail.prefix(500))
        showWindow()
    }
    private func perform(_ message: String, work: @escaping () throws -> String, done: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        busy = true; error = nil; status = message
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let output): self.status = output; done?()
                case .failure(let error): self.error = error.localizedDescription; self.status = "Couldn’t complete the operation."; onFailure?()
                }
            }
        }
    }
    func pair() {
        let adb = ADB(executable: adbPath, serial: "")
        let address = pairAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validEndpoint(address), code.count == 6, code.allSatisfy(\.isNumber) else {
            error = "Enter the pairing IP:port and six-digit code shown on your phone."; return
        }
        perform("Pairing with your phone…", work: {
            let result = try adb.run(["pair", address, code], timeout: 30)
            guard result.localizedCaseInsensitiveContains("successfully paired") else { throw AppError(result) }
            return "Paired. Enter the connection address from the main Wireless debugging screen."
        }, done: { self.pairingCode = ""; self.refresh() })
    }
    func connect() {
        let address = connectAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validEndpoint(address) else { error = "Enter the connection IP:port from Wireless debugging."; return }
        let adb = ADB(executable: adbPath, serial: "")
        perform("Connecting…", work: {
            let result = try adb.run(["connect", address], timeout: 30)
            guard result.localizedCaseInsensitiveContains("connected to") else { throw AppError(result) }
            return "Connected."
        }, done: {
            UserDefaults.standard.set(address, forKey: "connectAddress")
            self.selected = address; self.refresh()
        })
    }
    func startMonitoring() {
        guard !started else { return }; started = true
        refresh()
        transferMonitor = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.transfers = self.transferCenter.snapshots }
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanDevices(manual: false) }
        }
    }
    func refresh() { scanDevices(manual: true) }
    private func scanDevices(manual: Bool) {
        guard !polling, !adbPath.isEmpty, !busy else { return }
        polling = true
        let executable = adbPath, known = knownIDs, reconnect = autoReconnect, oldMountPath = mountPath, savedEndpoint = connectAddress
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                let devices = try DeviceDiscovery.scan(executable: executable, knownIDs: known, reconnect: reconnect, savedEndpoint: savedEndpoint)
                let mounted = oldMountPath.map { path in ((try? Command.run("/sbin/mount", [])) ?? "").contains(" on " + path + " (") } ?? true
                return (devices, mounted)
            }
            DispatchQueue.main.async {
                self.polling = false
                switch result {
                case .success(let scan):
                    let (devices, stillMounted) = scan
                    if !stillMounted, oldMountPath == self.mountPath, !self.busy {
                        self.desiredDeviceID = nil; UserDefaults.standard.removeObject(forKey: "resumeDeviceID")
                        self.reconnectingBackend?.stop(); self.server?.stop()
                        self.reconnectingBackend = nil; self.server = nil; self.mountedDevice = nil; self.recoveryStore = nil
                        self.mountPath = nil; self.mountURL = nil; self.storage = nil
                        if let path = oldMountPath { FinderMount.removeEmptyDirectory(URL(fileURLWithPath: path)) }
                    }
                    self.devices = devices
                    if !devices.contains(where: { $0.endpoint == self.selected }) { self.selected = devices.first?.endpoint ?? "" }
                    if let mounted = self.mountedDevice {
                        let next = DeviceDiscovery.preferred(devices, hardwareID: mounted.hardwareID, currentEndpoint: mounted.endpoint)
                        // With reconnect disabled, retain only the exact transport chosen at mounting time.
                        let connection = self.autoReconnect ? next : devices.first { $0.endpoint == mounted.endpoint && $0.hardwareID == mounted.hardwareID }
                        self.reconnectingBackend?.update(device: connection, executable: executable)
                        if let connection {
                            self.mountedDevice = connection; self.selected = connection.endpoint
                            self.refreshStorage(device: connection)
                            self.applyRecoveryExpiry(force: false)
                            if !self.busy { self.status = "\(connection.label) is mounted. Keep MacDroid running while using Finder." }
                        } else if !self.busy { self.storage = nil; self.status = self.autoReconnect ? "Phone disconnected. Waiting to reconnect…" : "Phone disconnected. Reconnect or eject the volume." }
                    } else if self.autoReconnect, let identity = self.desiredDeviceID,
                              let device = DeviceDiscovery.preferred(devices, hardwareID: identity, currentEndpoint: nil), !self.busy, self.mountURL == nil {
                        self.selected = device.endpoint; self.mount(openFinder: false)
                    } else if manual && !self.busy {
                        self.status = devices.isEmpty ? "No authorized phones found. Pair or connect below." : "Phone available. Ready to open in Finder."
                    }
                case .failure(let error): if manual { self.error = error.localizedDescription }
                }
            }
        }
    }
    func mount(openFinder: Bool = true) {
        guard !busy, mountURL == nil, let device = devices.first(where: { $0.endpoint == selected }) else { return }
        let adb = ADB(executable: adbPath, serial: selected)
        perform("Checking shared storage…", work: { _ = try adb.stat("/"); return "Starting Finder bridge…" }, done: {
            let connection = ReconnectingBackend(device: device, executable: self.adbPath)
            self.reconnectingBackend = connection
            let recovery = RecoveryStore(backend: connection)
            self.recoveryStore = recovery
            let server = WebDAVServer(backend: RecoverableBackend(base: connection, recovery: recovery), transfers: self.transferCenter)
            self.server = server; self.busy = true
            server.onError = { [weak self] error in DispatchQueue.main.async { self?.error = error } }
            do {
                try server.start { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .failure(let error): self.busy = false; self.error = error.localizedDescription; server.stop(); self.server = nil
                        case .success(let url):
                            self.mountURL = url
                            // mount_webdav produces a real Finder volume without a filesystem extension.
                            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacDroid/Mounts", isDirectory: true)
                            let target = base.appendingPathComponent("Android-" + UUID().uuidString.prefix(8), isDirectory: true)
                            self.perform("Mounting Android in Finder…", work: {
                                try FinderMount.mount(url, at: target, name: device.name)
                                return "Android is mounted. Keep MacDroid running while using Finder."
                            }, done: {
                                self.mountPath = target.path
                                self.mountedDevice = device
                                self.storageChecked = .distantPast; self.refreshStorage(device: device)
                                self.desiredDeviceID = device.hardwareID
                                self.applyRecoveryExpiry(force: false)
                                self.knownIDs.insert(device.hardwareID)
                                UserDefaults.standard.set(Array(self.knownIDs), forKey: "knownDeviceIDs")
                                UserDefaults.standard.set(device.hardwareID, forKey: "resumeDeviceID")
                                if openFinder { self.openDirectory(target) }
                            }, onFailure: {
                                connection.stop(); server.stop(); self.reconnectingBackend = nil; self.recoveryStore = nil
                                self.server = nil; self.mountURL = nil
                            })
                        }
                    }
                }
            } catch { self.busy = false; self.error = error.localizedDescription; self.server = nil }
        })
    }
    func stop(after: (() -> Void)? = nil) {
        guard !busy, !transferCenter.snapshots.contains(where: \.active) else {
            error = "Wait for active operations to finish, or cancel the transfers, before ejecting."; return
        }
        desiredDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "resumeDeviceID")
        if let path = mountPath {
            perform("Ejecting Android…", work: {
                try FinderMount.eject(URL(fileURLWithPath: path))
                return "Android ejected."
            }, done: {
                self.reconnectingBackend?.stop(); self.reconnectingBackend = nil; self.mountedDevice = nil; self.recoveryStore = nil; self.storage = nil
                self.mountPath = nil; self.mountURL = nil; self.server?.stop(); self.server = nil
                after?()
            })
        } else { reconnectingBackend?.stop(); reconnectingBackend = nil; mountedDevice = nil; server?.stop(); server = nil; mountURL = nil; status = "Bridge stopped."; after?() }
    }
    private func refreshStorage(device: AndroidDevice) {
        guard !storageLoading, Date().timeIntervalSince(storageChecked) > 30 else { return }
        storageLoading = true; storageChecked = Date()
        let adb = ADB(executable: adbPath, serial: device.endpoint)
        DispatchQueue.global(qos: .utility).async {
            let result = try? adb.storage()
            DispatchQueue.main.async {
                self.storageLoading = false
                if self.mountedDevice?.hardwareID == device.hardwareID { self.storage = result }
            }
        }
    }
    var deviceLabel: String { mountedDevice?.label ?? devices.first(where: { $0.endpoint == selected })?.label ?? "No phone connected" }
    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "MacDroid" }?.makeKeyAndOrderFront(nil)
    }
    func quitSafely() {
        if busy || transferCenter.snapshots.contains(where: \.active) {
            error = "Wait for active operations to finish, or cancel the transfers, before quitting."
            showWindow(); return
        }
        stopMirroring()
        if mountURL != nil {
            let resume = mountedDevice?.hardwareID
            stop(after: {
                self.desiredDeviceID = resume
                if let resume { UserDefaults.standard.set(resume, forKey: "resumeDeviceID") }
                NSApp.terminate(nil)
            })
        }
        else { NSApp.terminate(nil) }
    }
    func loadRecovery() {
        guard let store = recoveryStore, !busy else { return }
        busy = true; error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.items() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let items): self.recoveryItems = items
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func restore(_ item: RecoveryItem) {
        guard let store = recoveryStore, !busy else { return }
        perform("Restoring \(item.name)…", work: { try store.restore(item); return "Restored \(item.originalPath)." }, done: { self.loadRecovery() })
    }
    func purge(_ item: RecoveryItem) {
        guard let store = recoveryStore, !busy else { return }
        perform("Deleting \(item.name)…", work: { try store.purge(item); return "Permanently deleted \(item.name)." }, done: { self.loadRecovery() })
    }
    func emptyRecovery() {
        guard let store = recoveryStore, !busy else { return }
        perform("Emptying recovery…", work: {
            let count = try store.empty()
            if count == 1 { return "Permanently deleted 1 recovered item." }
            return count == 0 ? "Recovery is already empty." : "Permanently deleted \(count) recovered items."
        }, done: { self.loadRecovery() })
    }
    func confirmEmptyRecovery() {
        guard recoveryStore != nil, !busy else { return }
        showWindow()
        let alert = NSAlert()
        alert.messageText = "Empty Recovery?"
        alert.informativeText = "Permanently delete every recovered item from the phone. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Recovery")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        emptyRecovery()
    }
    func applyRecoveryExpiry(force: Bool) {
        let due = force || expiryAgain
        guard recoveryExpiryEnabled, let store = recoveryStore else { return }
        if busy || expiryRunning || transferCenter.snapshots.contains(where: \.active) {
            if due { expiryAgain = true }
            return
        }
        if !due && Date().timeIntervalSince(lastExpiry) < 3600 { return }
        expiryAgain = false
        expiryRunning = true
        lastExpiry = Date()
        let retention = RecoveryRetention(enabled: true, days: recoveryExpiryDays)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try store.purgeExpired(retention: retention) }
            DispatchQueue.main.async {
                self.expiryRunning = false
                if case .success(let count) = result, count > 0 {
                    let noun = count == 1 ? "item" : "items"
                    self.status = "Permanently deleted \(count) recovered \(noun) older than \(retention.days) days."
                    if self.showingRecovery { self.loadRecovery() }
                }
                if self.expiryAgain { self.applyRecoveryExpiry(force: false) }
            }
        }
    }
    func openRecovery() { showingRecovery = true; loadRecovery() }
    func openFinder() {
        if let path = mountPath { openDirectory(URL(fileURLWithPath: path)) }
        else if let mountURL { NSWorkspace.shared.open(mountURL) }
    }
    private func openDirectory(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    private func validEndpoint(_ value: String) -> Bool { DeviceDiscovery.validEndpoint(value) }

}

private final class MirrorSession: @unchecked Sendable { var handled = false }

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "externaldrive.connected.to.line.below.fill").font(.system(size: 42)).foregroundStyle(.mint)
                Text("MacDroid").font(.largeTitle.bold())
                Text("Your phone.\nRight in Finder.").font(.title2.weight(.medium))
                Text("Connect over local Wi-Fi. No Android app, cable, or cloud account.").foregroundStyle(.secondary)
                Spacer()
                Label("Local connection", systemImage: "wifi").font(.callout)
                Text("Android 11 or later\nSame Wi-Fi as this Mac").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 220).frame(maxHeight: .infinity).background(.quaternary.opacity(0.45))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Android Platform Tools", systemImage: "wrench.and.screwdriver").font(.headline)
                            if model.adbPath.isEmpty {
                                Text("ADB is required on this Mac. Install Android SDK Platform Tools, then select its adb executable.").foregroundStyle(.secondary)
                                Text("brew install --cask android-platform-tools").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            } else { Text(model.adbPath).font(.caption.monospaced()).textSelection(.enabled) }
                            HStack {
                                Button("Select adb…") { model.chooseADB() }
                                Link("Download from Google ↗", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1  Pair your phone").font(.headline)
                            Text("On Android, enable Developer options → Wireless debugging → Pair device with pairing code. Keep that dialog open.").foregroundStyle(.secondary)
                            TextField("Pairing IP:port (192.168.1.25:37123)", text: $model.pairAddress)
                            HStack {
                                SecureField("Six-digit pairing code", text: $model.pairingCode)
                                Button("Pair") { model.pair() }.disabled(model.busy || model.adbPath.isEmpty || model.mountURL != nil)
                            }
                            Toggle("Reconnect automatically", isOn: $model.autoReconnect)
                            Text("Already paired? Skip to Connect.").font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("2  Connect and open Finder").font(.headline)
                            Text("Close the pairing dialog. Use IP address & Port on the main Wireless debugging screen. The connection port differs from the pairing port.").foregroundStyle(.secondary)
                            HStack {
                                TextField("Connection IP:port", text: $model.connectAddress).textFieldStyle(.roundedBorder)
                                Button("Connect") { model.connect() }.disabled(model.busy || model.adbPath.isEmpty || model.mountURL != nil)
                            }
                            HStack {
                                Picker("Phone", selection: $model.selected) {
                                    Text("Select phone").tag("")
                                    ForEach(model.devices) { Text($0.label).tag($0.endpoint) }
                                }.disabled(model.mountURL != nil)
                                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy || model.adbPath.isEmpty)
                            }
                            if let storage = model.storage {
                                VStack(alignment: .leading, spacing: 5) {
                                    ProgressView(value: storage.usedFraction)
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.available), countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.total), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if model.mountURL == nil {
                                Button("Open Android in Finder", systemImage: "folder") { model.mount() }
                                    .buttonStyle(.borderedProminent).disabled(model.busy || model.selected.isEmpty)
                            } else {
                                HStack {
                                    Button("Open Finder") { model.openFinder() }.disabled(model.busy)
                                    Button("Recovery") { model.openRecovery() }.disabled(model.busy || model.mountPath == nil)
                                    Button(model.mountPath == nil ? "Stop bridge" : "Eject") { model.stop() }.disabled(model.busy || model.transfers.contains(where: \.active))
                                }
                            }
                            if model.mirroring {
                                Button("Stop mirroring") { model.stopMirroring() }
                            } else {
                                Button("Mirror screen", systemImage: "rectangle.on.rectangle") { model.mirrorScreen() }
                                    .disabled(model.adbPath.isEmpty || (model.selected.isEmpty && model.mountURL == nil))
                            }
                            Text("Included with the app. A development build uses Homebrew when scrcpy is not bundled. Finder does not need it.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Deleted files move to MacDroid Recovery on the phone. Restore them, or permanently delete them, from Recovery. Automatic deletion is off unless you set an age limit. Replaced files are not backed up.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    TransferList(model: model)
                    HStack(alignment: .top) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                }.padding(28)
            }
        }.onAppear { model.startMonitoring() }
        .sheet(isPresented: $model.showingRecovery) { RecoveryView(model: model) }
    }
}

struct TransferList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.transfers.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transfers").font(.headline)
                        Spacer()
                        Button("Clear finished") { model.transferCenter.clearFinished(); model.transfers = model.transferCenter.snapshots }
                    }
                    ForEach(Array(model.transfers.prefix(8))) { transfer in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if transfer.active { Button("Cancel") { model.transferCenter.cancel(transfer.id) }.disabled(transfer.cancellationRequested) }
                                else { Text(transfer.outcome ?? "Finished").foregroundStyle(.secondary) }
                            }
                            Text(transfer.direction + " · " + transfer.phase).font(.caption).foregroundStyle(.secondary)
                            if transfer.active {
                                if let fraction = transfer.fraction { ProgressView(value: fraction) }
                                else { ProgressView().controlSize(.small) }
                                Text(detail(transfer)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                    Text("Cancel stops this transfer. Finder may show an error or offer to retry. Estimates apply to the stage shown.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }
    private func detail(_ transfer: TransferSnapshot) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.completed), countStyle: .file)
        let total = transfer.total.map { " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? ""
        guard transfer.bytesPerSecond > 0 else { return completed + total }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file) + "/s"
        let time = transfer.secondsRemaining.map { " · about \(Int(ceil($0)))s left in this stage" } ?? ""
        return completed + total + " · " + speed + time
    }
}

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingEmpty = false
    @State private var pendingDelete: RecoveryItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recovered deletions").font(.title2.bold())
                Spacer()
                Button("Refresh") { model.loadRecovery() }.disabled(model.busy)
                Button("Empty Recovery") { confirmingEmpty = true }.disabled(model.busy || model.recoveryItems.isEmpty)
                Button("Done") { model.showingRecovery = false }
            }
            Text("Recovered files stay on the phone until you restore them or permanently delete them. Automatic deletion stays off until you set an age limit.").foregroundStyle(.secondary)
            Toggle("Delete items older than \(model.recoveryExpiryDays) days", isOn: $model.recoveryExpiryEnabled).disabled(model.mountURL == nil)
            Stepper("Age limit: \(model.recoveryExpiryDays) days", value: $model.recoveryExpiryDays, in: RecoveryRetention.minimumDays...RecoveryRetention.maximumDays)
            if model.busy { ProgressView() }
            if model.recoveryItems.isEmpty && !model.busy { Text("No recoverable deletions.").foregroundStyle(.secondary) }
            List(model.recoveryItems) { item in
                HStack {
                    Image(systemName: item.directory ? "folder" : "doc")
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                        Text(item.originalPath).font(.caption).foregroundStyle(.secondary)
                        Text(item.deletedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.restore(item) }.disabled(model.busy)
                    Button("Delete") { pendingDelete = item }.disabled(model.busy)
                }.padding(.vertical, 5)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }
        .confirmationDialog("Empty Recovery?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Empty Recovery", role: .destructive) { model.emptyRecovery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently delete every recovered item from the phone. This cannot be undone.")
        }
        .confirmationDialog("Permanently delete this recovered item?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let item = pendingDelete { model.purge(item) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\($0.name) will be removed from the phone and cannot be restored." } ?? "This cannot be undone.")
        }
        .padding(24).frame(width: 700, height: 560)
    }
}

struct MacDroidMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.deviceLabel)
        Text(model.status)
        if let storage = model.storage { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.available), countStyle: .file) + " free on phone") }
        let active = model.transfers.filter(\.active)
        if !active.isEmpty { Text("\(active.count) active transfer(s)") }
        Divider()
        if model.mountURL != nil {
            Button("Open in Finder") { model.openFinder() }.disabled(model.busy)
            Button("Recovery…") { openWindow(id: "main"); model.showWindow(); model.openRecovery() }.disabled(model.busy)
            Button("Empty Recovery…") { model.confirmEmptyRecovery() }.disabled(model.busy)
            Button("Eject") { model.stop() }.disabled(model.busy || !active.isEmpty)
        } else {
            ForEach(model.devices) { device in
                Button("Mount " + device.label) { model.selected = device.endpoint; model.mount() }.disabled(model.busy)
            }
            Button("Find phones") { model.refresh() }.disabled(model.busy)
            if !model.connectAddress.isEmpty { Button("Connect saved Wi-Fi address") { model.connect() }.disabled(model.busy) }
        }
        if model.mirroring {
            Button("Stop screen mirroring") { model.stopMirroring() }
        } else {
            Button("Mirror screen") { model.mirrorScreen() }
                .disabled(model.adbPath.isEmpty || (model.selected.isEmpty && model.mountURL == nil))
        }
        Toggle("Reconnect automatically", isOn: $model.autoReconnect)
        Divider()
        Button("Open MacDroid") { openWindow(id: "main"); model.showWindow() }
        Button("Quit MacDroid") { model.quitSafely() }
    }
}
