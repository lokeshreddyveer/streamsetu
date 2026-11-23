import Foundation

/// Runs blocking work (a database read) off the main actor and applies its result on the main actor, with two guards a plain `Task.detached` does not give:
/// a result that was overtaken by a newer request (or cancelled) is dropped instead of applied, and `coalesced` never runs the same scan twice at once.
@MainActor
final class LatestLoad {
    private var generation = 0
    private var task: Task<Void, Never>?
    private var running = false
    private var again = false

    /// Latest wins: starting a request makes every earlier one stale, so a slow read finishing late cannot overwrite a newer answer.
    @discardableResult
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T, apply: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
        generation &+= 1
        let mine = generation
        task?.cancel()
        let t = Task { @MainActor [weak self] in
            let value = await offMain(work)
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            apply(value)
        }
        task = t
        return t
    }

    /// One scan at a time: a request made while one is running is folded into a single follow-up run that starts when the first ends (so the last change is never missed, and N requests cost at most 2 scans).
    func coalesced<T: Sendable>(_ work: @escaping @Sendable () -> T, apply: @escaping @MainActor (T) -> Void) {
        if running { again = true; return }
        running = true
        task = Task { @MainActor [weak self] in
            var repeatRun = true
            while repeatRun {
                let value = await offMain(work)
                guard let self else { return }
                if Task.isCancelled { running = false; again = false; return }
                apply(value)
                repeatRun = again; again = false
            }
            self?.running = false
        }
    }

    /// Makes anything in flight stale: its result is not applied.
    func cancel() { generation &+= 1; task?.cancel(); running = false; again = false }

    /// Waits for the work started so far (tests; nothing in the app needs it).
    func settle() async { await task?.value }
}
