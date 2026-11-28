import Foundation
import Observation

// Keeps imports that came from a Spotify link up to date, but only the ones the person switched auto-update on for (off by default), and only while Music is
// consented. It looks once shortly after launch and then at most once an hour. With nothing switched on there is no task and no timer at all.

extension ImportBudget {
    /// Searches left in the current hour without spending any (admit() would count one).
    func remaining(now: Date) -> Int {
        if let c = cooldownUntil, c > now { return 0 }
        guard let s = windowStart, now.timeIntervalSince(s) < 3600 else { return Self.searchesPerHour }
        return max(0, Self.searchesPerHour - count)
    }
}

/// What the last automatic check of one import found, for the import page to show.
struct ImportUpdateOutcome: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case upToDate, updated, failed }
    var at: Date
    var kind: Kind
    var added = 0
    var removed = 0
    var message: String? = nil

    var summary: String {
        switch kind {
        case .upToDate: String(localized: "Up to date")
        case .updated: String(localized: "Added \(added), removed \(removed)")
        case .failed: message ?? String(localized: "Could not update")
        }
    }
}

enum ImportSchedule {
    static let initialDelay: TimeInterval = 45
    static let interval: TimeInterval = 3600
    /// A run needs at least this many searches left in the hour, so it does not stall half way waiting for the window to turn over.
    static let minimumBudget = 25

    /// How long to wait before the next look: soon after launch, otherwise an hour after the previous one.
    static func delay(now: Date, lastRun: Date?) -> TimeInterval {
        guard let lastRun else { return initialDelay }
        return max(0, interval - now.timeIntervalSince(lastRun))
    }

    /// Whether a pass may start at all, and which imports are due. Empty when Music is not consented, an import is running, the service is resting or the budget is low.
    static func due(records: [String: SpotifySourceRecord], now: Date, consented: Bool, busy: Bool, budget: ImportBudget) -> [String] {
        guard consented, !busy, budget.remaining(now: now) >= minimumBudget else { return [] }
        return ImportUpdate.due(records, now: now)
    }

    static func anyEnabled(_ records: [String: SpotifySourceRecord]) -> Bool { records.values.contains { $0.auto } }
}

@MainActor @Observable
final class MusicImportScheduler {
    static let shared = MusicImportScheduler()

    /// Everything the scheduler touches, injectable so the rules are tested with a fake clock and no network.
    struct Environment {
        var now: @MainActor () -> Date = { Date() }
        var consented: @MainActor () -> Bool
        var records: @MainActor () -> [String: SpotifySourceRecord]
        var setRecord: @MainActor (SpotifySourceRecord, UUID) -> Void
        var budget: @MainActor () -> ImportBudget
        var isBusy: @MainActor () -> Bool
        var update: @MainActor (UUID) async throws -> SpotifyImportJob.UpdateSummary
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    }

    private(set) var outcomes: [String: ImportUpdateOutcome] = [:]
    private(set) var lastRun: Date?
    @ObservationIgnored private var env: Environment?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let outcomesKey = "music.import.autoUpdate.outcomes"

    init(environment: Environment? = nil, defaults: UserDefaults = .standard) {
        self.env = environment
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.outcomesKey), let o = try? JSONDecoder().decode([String: ImportUpdateOutcome].self, from: d) { outcomes = o }
    }

    // MARK: start and stop

    /// The one entry point for the app: call it when the hub is ready and again whenever consent changes. Cheap and safe to repeat.
    func start(hub: MusicHub) {
        if env == nil {
            let job = SpotifyImportJob.shared
            let library = hub.library
            env = Environment(consented: { library.settings.consentDone }, records: { job.sources.records },
                              setRecord: { job.sources.set($0, for: $1) }, budget: { job.budgetState }, isBusy: { job.isBusy },
                              update: { try await job.update(playlist: $0) })
        }
        start()
    }

    /// Starts the loop when it is allowed and there is something to watch. Nothing is scheduled otherwise.
    func start() {
        guard loop == nil, let env, env.consented(), ImportSchedule.anyEnabled(env.records()) else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() { loop?.cancel(); loop = nil }

    var isRunning: Bool { loop != nil }

    // MARK: the person's switch

    func isAutoUpdate(_ playlist: UUID) -> Bool { env?.records()[playlist.uuidString]?.auto ?? false }

    /// Whether this playlist came from a link that can be read again.
    func canUpdate(_ playlist: UUID) -> Bool { env?.records()[playlist.uuidString] != nil }

    func setAutoUpdate(_ on: Bool, for playlist: UUID) {
        guard let env, var r = env.records()[playlist.uuidString] else { return }
        r.auto = on
        env.setRecord(r, playlist)
        if on { start() } else if !ImportSchedule.anyEnabled(env.records()) { stop() }
    }

    func outcome(for playlist: UUID) -> ImportUpdateOutcome? { outcomes[playlist.uuidString] }

    // MARK: the loop

    private func run() async {
        defer { loop = nil }
        while !Task.isCancelled {
            guard let env, env.consented(), ImportSchedule.anyEnabled(env.records()) else { return }
            await env.sleep(ImportSchedule.delay(now: env.now(), lastRun: lastRun))
            if Task.isCancelled { return }
            await checkNow()
        }
    }

    /// One pass over the imports that are due. Reads are spaced 5 s apart; a block from the service ends the pass. Returns how many were checked.
    @discardableResult
    func checkNow() async -> Int {
        guard let env else { return 0 }
        let now = env.now()
        lastRun = now
        var checked = 0
        let ids = ImportSchedule.due(records: env.records(), now: now, consented: env.consented(), busy: env.isBusy(), budget: env.budget())
        for key in ids {
            if Task.isCancelled { break }
            guard let id = UUID(uuidString: key) else { continue }
            // Conditions can change while an earlier playlist was being read.
            let again = ImportSchedule.due(records: env.records(), now: env.now(), consented: env.consented(), busy: env.isBusy(), budget: env.budget())
            guard again.contains(key) else { continue }
            if checked > 0 { await env.sleep(ImportUpdate.readSpacing) }
            checked += 1
            var resting = false
            do {
                let s = try await env.update(id)
                record(ImportUpdateOutcome(at: env.now(), kind: s.upToDate ? .upToDate : .updated, added: s.added, removed: s.removed), for: key)
            } catch let e as ImportError {
                record(ImportUpdateOutcome(at: env.now(), kind: .failed, message: ImportMessages.text(e)), for: key)
                if case .cooldown = e { resting = true }
            } catch {
                record(ImportUpdateOutcome(at: env.now(), kind: .failed), for: key)
            }
            // A failed read still counts as a look, so a broken link is not retried every hour.
            if resting { break }
            if var r = env.records()[key] { r.checked = env.now(); env.setRecord(r, id) }
        }
        return checked
    }

    private func record(_ o: ImportUpdateOutcome, for key: String) {
        outcomes[key] = o
        defaults.set(try? JSONEncoder().encode(outcomes), forKey: Self.outcomesKey)
    }
}
