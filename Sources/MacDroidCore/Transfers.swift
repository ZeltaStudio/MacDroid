import Foundation

public struct TransferSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let direction: String
    public let phase: String
    public let completed: UInt64
    public let total: UInt64?
    public let bytesPerSecond: Double
    public let active: Bool
    public let cancellationRequested: Bool
    public let outcome: String?
    public var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(completed) / Double($0)) : nil } }
    public var secondsRemaining: Double? { guard let total, bytesPerSecond > 0 else { return nil }; return Double(total > completed ? total - completed : 0) / bytesPerSecond }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [ObjectIdentifier: Process] = [:]
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw CancellationError() } }
    public func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); processes[ObjectIdentifier(process)] = process
    }
    public func remove(_ process: Process) { lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock() }
    public func cancel() {
        lock.lock(); cancelled = true; let running = Array(processes.values); lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
}

public final class TransferOperation: @unchecked Sendable {
    public let id = UUID()
    public let cancellation = CancellationToken()
    private let lock = NSLock()
    private let name: String
    private let direction: String
    private var phase = "Preparing"
    private var completed: UInt64 = 0
    private var total: UInt64?
    private var began = Date()
    private var active = true
    private var outcome: String?
    public init(path: String, direction: String) { name = (path as NSString).lastPathComponent; self.direction = direction }
    public func stage(_ phase: String, total: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        guard active, !cancellation.isCancelled else { return }
        self.phase = phase; self.total = total; completed = 0; began = Date()
    }
    public func progress(_ bytes: UInt64, phase expectedPhase: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard active, expectedPhase == nil || phase == expectedPhase else { return }; completed = max(completed, total.map { min(bytes, $0) } ?? bytes)
    }
    public func finish(_ outcome: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }; active = false
        self.outcome = cancellation.isCancelled ? "Cancelled" : (outcome ?? "Complete")
    }
    public func cancel() {
        cancellation.cancel()
        lock.lock(); if active { phase = "Cancelling…" }; lock.unlock()
    }
    public var snapshot: TransferSnapshot {
        lock.lock(); defer { lock.unlock() }
        let elapsed = Date().timeIntervalSince(began)
        return TransferSnapshot(id: id, name: name, direction: direction, phase: phase, completed: completed, total: total,
                                bytesPerSecond: active && elapsed > 0.2 ? Double(completed) / elapsed : 0, active: active, cancellationRequested: cancellation.isCancelled, outcome: outcome)
    }
}

public final class TransferCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [TransferOperation] = []
    public init() {}
    public func begin(path: String, direction: String) -> TransferOperation {
        let operation = TransferOperation(path: path, direction: direction)
        lock.lock(); defer { lock.unlock() }
        if operations.count >= 40 { operations.removeAll { !$0.snapshot.active } }
        operations.append(operation); return operation
    }
    public var snapshots: [TransferSnapshot] { lock.lock(); let copy = operations; lock.unlock(); return copy.reversed().map(\.snapshot) }
    public func cancel(_ id: UUID) { lock.lock(); let operation = operations.first { $0.id == id }; lock.unlock(); operation?.cancel() }
    public func cancelAll() { lock.lock(); let copy = operations; lock.unlock(); copy.forEach { $0.cancel() } }
    public func clearFinished() { lock.lock(); operations.removeAll { !$0.snapshot.active }; lock.unlock() }
}
