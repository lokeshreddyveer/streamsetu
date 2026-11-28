import Foundation

/// Shared lookups by key: callers asking for the same key share one running task. Cancellation reaches the task through the callers: when the last
/// caller still waiting is cancelled, the task is cancelled too (so a pre-resolve or a skipped song stops fanning out to every provider); while any
/// other caller waits, the task keeps running. Thread-safe; the waiter count and the task live under one lock.
final class MusicFlightBoard<Value: Sendable>: @unchecked Sendable {
    private final class Ticket: @unchecked Sendable { var left = false }
    private struct Flight { var task: Task<Value, Error>; var waiters: Int }

    private let lock = NSLock()
    private var flights: [String: Flight] = [:]

    init() {}

    /// Joins the running task for `key`, or starts one with `start`.
    func value(key: String, start: @Sendable () -> Task<Value, Error>) async throws -> Value {
        let ticket = Ticket()
        let task: Task<Value, Error> = lock.withLock {
            if var f = flights[key] { f.waiters += 1; flights[key] = f; return f.task }
            let t = start()
            flights[key] = Flight(task: t, waiters: 1)
            return t
        }
        return try await withTaskCancellationHandler {
            defer { leave(key, task, ticket) }
            return try await task.value
        } onCancel: {
            leave(key, task, ticket)
        }
    }

    /// True while a task for this key is registered.
    func isRunning(_ key: String) -> Bool { lock.withLock { flights[key] != nil } }
    func waiters(_ key: String) -> Int { lock.withLock { flights[key]?.waiters ?? 0 } }

    /// The task is finished or must not be joined any more (its answer was refused): later callers start a new one. Current waiters keep waiting.
    func forget(_ key: String, task: Task<Value, Error>) {
        lock.withLock { if flights[key]?.task == task { flights[key] = nil } }
    }

    /// Same as `forget(_:task:)` without the task in hand.
    func forgetKey(_ key: String) { lock.withLock { flights[key] = nil } }

    /// Cancels every task whose key starts with `prefix` (the person skipped that song).
    func cancelAll(prefix: String) {
        let victims: [Task<Value, Error>] = lock.withLock {
            let keys = flights.keys.filter { $0.hasPrefix(prefix) }
            return keys.compactMap { k in flights.removeValue(forKey: k)?.task }
        }
        victims.forEach { $0.cancel() }
    }

    private func leave(_ key: String, _ task: Task<Value, Error>, _ ticket: Ticket) {
        let cancelIt: Bool = lock.withLock {
            guard !ticket.left else { return false }
            ticket.left = true
            guard var f = flights[key], f.task == task else { return false }
            f.waiters -= 1
            if f.waiters <= 0 { flights[key] = nil; return true }
            flights[key] = f
            return false
        }
        if cancelIt { task.cancel() }
    }
}
