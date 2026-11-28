import Foundation

/// A deadline that is really enforced. A structured task group cannot give this: it waits for every child before it returns, so one child
/// that ignores cancellation holds the caller long past the limit. Here the caller is resumed exactly once, by whichever of the work, the
/// timer or the caller's own cancellation comes first; the losers are cancelled and abandoned. The sleep is injectable so tests run on a
/// virtual clock.
enum MusicDeadline {
    struct Timeout: Error {}

    private final class Gate<T: Sendable>: Sendable {
        private struct State: @unchecked Sendable {
            var cont: CheckedContinuation<T, Error>?
            var result: Result<T, Error>?
            var tasks: [Task<Void, Never>] = []
        }
        private let state = Locked(State())

        func install(_ c: CheckedContinuation<T, Error>) {
            let ready: Result<T, Error>? = state.withLock { s in
                if let r = s.result { return r }
                s.cont = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }

        func add(_ t: Task<Void, Never>) {
            let stale = state.withLock { s -> Bool in
                if s.result != nil { return true }
                s.tasks.append(t)
                return false
            }
            if stale { t.cancel() }
        }

        func finish(_ r: Result<T, Error>) {
            let (c, tasks): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = state.withLock { s in
                guard s.result == nil else { return (nil, []) }
                s.result = r
                let c = s.cont; s.cont = nil
                let t = s.tasks; s.tasks = []
                return (c, t)
            }
            for t in tasks { t.cancel() }
            c?.resume(with: r)
        }
    }

    /// Runs `op`; throws `onTimeout` when it has not answered after `seconds` of the injected clock.
    static func race<T: Sendable>(seconds: Double, sleep: @escaping @Sendable (Double) async throws -> Void,
                                  _ op: @escaping @Sendable () async throws -> T, onTimeout: Error) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                gate.install(cont)
                gate.add(Task { do { gate.finish(.success(try await op())) } catch { gate.finish(.failure(error)) } })
                gate.add(Task { do { try await sleep(seconds); gate.finish(.failure(onTimeout)) } catch {} })
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }

    /// Same, but a timeout is a nil answer instead of an error (an error from `op` is still thrown).
    static func orNil<T: Sendable>(seconds: Double, sleep: @escaping @Sendable (Double) async throws -> Void,
                                   _ op: @escaping @Sendable () async -> T) async -> T? {
        return try? await race(seconds: seconds, sleep: sleep, { await op() }, onTimeout: Timeout())
    }
}
