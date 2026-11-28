import Foundation

/// A page paints from the data it already has and improves afterwards. `load` returns the plain value the moment `base` finishes; `enrich`
/// runs after that, under its own deadline, and its answer (when it differs) is handed to `improve`. A slow, failed or cancelled enrichment
/// never delays or changes the first paint.
enum MusicFirstPaint {
    /// Runs `enrich` in the background with a deadline. Returns the improved value, or nil when it is not ready in time, throws, or is cancelled.
    static func improved<T: Sendable>(deadline: TimeInterval, _ enrich: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once<T>()
        let work = Task { once.finish(await enrich()) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            once.finish(nil)
        }
        return await withTaskCancellationHandler {
            let value = await once.value()
            work.cancel(); timer.cancel()
            return value
        } onCancel: {
            work.cancel(); timer.cancel(); once.finish(nil)
        }
    }

    /// The first answer wins; later ones are ignored. The loser is cancelled but never awaited, so a slow job cannot hold the page.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: T??
        private var waiter: CheckedContinuation<T?, Never>?
        func finish(_ v: T?) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = .some(v)
            let w = waiter; waiter = nil
            lock.unlock()
            w?.resume(returning: v)
        }
        func value() async -> T? {
            await withCheckedContinuation { c in
                lock.lock()
                if let r = result { lock.unlock(); c.resume(returning: r) } else { waiter = c; lock.unlock() }
            }
        }
    }

    /// True when the enriched list is worth replacing the painted one with: same songs plus additions or reordering, never fewer songs.
    static func shouldReplace(painted: [String], enriched: [String]) -> Bool {
        guard !enriched.isEmpty, enriched.count >= painted.count, enriched != painted else { return false }
        return true
    }
}

/// Runs at most `limit` jobs at once, in the order given, and stops starting new ones when cancelled. For the secondary loads of a page
/// (credits, film info, artwork) so a page never fans out into dozens of requests.
enum MusicBoundedRunner {
    static func run<T: Sendable>(_ jobs: [@Sendable () async -> T], limit: Int) async -> [T?] {
        let n = max(1, limit)
        var results = [T?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, T?).self) { group in
            var next = 0
            func launch() {
                guard next < jobs.count, !Task.isCancelled else { return }
                let i = next; next += 1
                let job = jobs[i]
                group.addTask { Task.isCancelled ? (i, nil) : (i, await job()) }
            }
            for _ in 0..<min(n, jobs.count) { launch() }
            while let (i, value) = await group.next() {
                results[i] = value
                launch()
            }
        }
        return results
    }
}
