import Foundation
import Observation

/// What the entity model center tells a completeness runner: a page (or panel) took the model of this entity for the first time, and the model was
/// dropped (its last lease was released and the grace window ended). `begin` starts the one run for the entity; `end` cancels it.
@MainActor
protocol MusicEntityCompleting: AnyObject {
    func begin(_ id: MusicEntityID)
    func end(_ id: MusicEntityID)
}

/// Where a page reads "is the full list still loading". One value per entity, changed only on the main actor.
@MainActor @Observable
final class MusicCompletenessTracker {
    static let shared = MusicCompletenessTracker()
    enum State: Equatable, Sendable { case idle, running, done(complete: Bool) }
    private(set) var states: [MusicEntityID: State] = [:]
    func state(_ id: MusicEntityID) -> State { states[id] ?? .idle }
    func isRunning(_ id: MusicEntityID) -> Bool { states[id] == .running }
    func set(_ s: State, for id: MusicEntityID) { if states[id] != s { states[id] = s } }
    func reset() { states = [:] }
}

/// Runs the completeness pass for the entities the model center holds: one run per entity at a time, started when its model is first taken, cancelled
/// when the model is dropped, results announced as the pass writes them (so open pages refresh while it runs). Persons and groups get the person pass,
/// films the soundtrack pass, albums the editions pass; every other kind is ignored.
@MainActor
final class MusicEntityCompletenessCoordinator: MusicEntityCompleting {
    let pass: MusicPersonCompleteness
    let tracker: MusicCompletenessTracker
    /// Announces changed entities to the entity store (its `notifyChanged`).
    let announce: @MainActor (Set<MusicEntityID>) -> Void
    private var tasks: [MusicEntityID: Task<Void, Never>] = [:]
    /// How many runs started (tests: one per entity however many views take it).
    private(set) var started = 0

    init(pass: MusicPersonCompleteness, tracker: MusicCompletenessTracker = .shared, announce: @escaping @MainActor (Set<MusicEntityID>) -> Void) {
        self.pass = pass; self.tracker = tracker; self.announce = announce
    }

    static func handles(_ k: MusicEntityKind) -> Bool {
        switch k { case .person, .group, .film, .series, .album, .release: true; default: false }
    }

    func begin(_ id: MusicEntityID) {
        guard Self.handles(id.kind), tasks[id] == nil else { return }
        started += 1
        tracker.set(.running, for: id)
        let pass = self.pass, tracker = self.tracker, announce = self.announce
        tasks[id] = Task { [weak self] in
            let progress: MusicPersonCompleteness.Progress = { changed, _ in
                guard !changed.isEmpty, !Task.isCancelled else { return }
                await MainActor.run { announce(changed) }
            }
            let outcome: MusicPersonCompleteness.Outcome
            switch id.kind {
            case .person, .group: outcome = await pass.run(id, progress: progress)
            case .film, .series: outcome = await pass.runFilm(id, progress: progress)
            default: outcome = await pass.runAlbum(id, progress: progress)
            }
            await MainActor.run {
                guard let self, self.tasks[id] != nil else { return }
                self.tasks[id] = nil
                tracker.set(outcome.cancelled ? .idle : .done(complete: outcome.complete), for: id)
            }
        }
    }

    func end(_ id: MusicEntityID) {
        guard let t = tasks.removeValue(forKey: id) else { return }
        t.cancel()
        tracker.set(.idle, for: id)
    }

    func endAll() { for id in Array(tasks.keys) { end(id) } }
}
