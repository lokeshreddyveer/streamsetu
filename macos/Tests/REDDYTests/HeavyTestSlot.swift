import Foundation

/// One slot for the few CPU-heavy tests (long sweeps, fuzzing, benchmark banks, 100,000-row imports, render loops).
///
/// Why: Swift Testing starts every test at once. In a full run these few tests together kept the main thread about 95 % busy for the first one to two minutes (stack samples of the
/// test process taken during full runs), and every test with a wall-clock check (a one-minute time limit, a ten-second real-time wait, "finished within 30 s") spent that time
/// queued, not working, so a different handful failed in each run while all of them passed alone. Taking this slot makes the heavy tests run one after another; a test waiting for
/// the slot is suspended, so it holds neither the main actor nor a thread. Nothing about what the tests check changes.
actor HeavyTestSlot {
    static let shared = HeavyTestSlot()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Runs `body` while holding the slot, on the caller's actor.
    static func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        await shared.acquire()
        do { let r = try await body(); await shared.release(); return r }
        catch { await shared.release(); throw error }
    }
}
