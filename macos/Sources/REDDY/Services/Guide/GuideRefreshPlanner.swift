import Foundation

/// Which guide sources are due. Pure; the background task and the "Refresh now" button both ask this.
/// Rules: switched-off sources never; a public source only when the person enabled it; at least the kind's minimum interval (public database 24 h, Starlite 3 h, user guides 1 h);
/// after a failure the next try waits the hub's back-off (10 s doubling to 15 min, but never less than the source's own interval for a success); metered networks skip large public files.
struct GuideRefreshPlanner: Sendable {
    struct SourceState: Sendable, Equatable {
        var id: String
        var kind: GuideSourceKind
        var enabled: Bool
        var priority: Int
        var refreshHours: Int
        var lastAttempt: Date?
        var lastSuccess: Date?
        var consecutiveFailures = 0
    }
    struct Conditions: Sendable, Equatable {
        var now: Date
        var onUnmeteredNetwork = true
        var wifiOnly = false
        var force = false
    }
    struct Due: Sendable, Equatable { var id: String; var reason: String }

    static func due(_ states: [SourceState], _ c: Conditions) -> [Due] {
        var out: [Due] = []
        for s in states.sorted(by: { $0.priority != $1.priority ? $0.priority < $1.priority : $0.id < $1.id }) where s.enabled {
            if c.wifiOnly, !c.onUnmeteredNetwork, !c.force { continue }
            if c.force { out.append(Due(id: s.id, reason: "requested")); continue }
            let hours = max(s.refreshHours, s.kind.minRefreshHours)
            guard let last = s.lastAttempt else { out.append(Due(id: s.id, reason: "never")); continue }
            if s.consecutiveFailures > 0 {
                let wait = NegativeCache.backoff(retryAfter: nil, previousFailures: s.consecutiveFailures - 1)
                if c.now.timeIntervalSince(last) >= wait { out.append(Due(id: s.id, reason: "retry")) }
                continue
            }
            let reference = s.lastSuccess ?? last
            if c.now.timeIntervalSince(reference) >= TimeInterval(hours) * 3600 { out.append(Due(id: s.id, reason: "interval")) }
        }
        return out
    }
}

/// Skeleton of the refresh run: asks the planner, imports each due source one after another (utility priority, cancellable), then lets the caller rebuild mappings. The wiring into the app's background task is a later stage.
struct GuideRefreshRunner: Sendable {
    let db: DatabaseManager
    let registry: GuideSourceRegistry
    var windowDays = 3

    @discardableResult
    func run(conditions: GuideRefreshPlanner.Conditions) async throws -> [String: GuideImportPipeline.Result] {
        let repo = SQLiteGuideRepository(db: db)
        let rows = try repo.sources()
        let states = rows.map { r in
            GuideRefreshPlanner.SourceState(id: r.id, kind: r.kind, enabled: r.enabled, priority: r.priority, refreshHours: r.refreshHours, lastAttempt: r.lastAttempt, lastSuccess: r.lastSuccess,
                                            consecutiveFailures: r.status == "failed" ? 1 : 0)
        }
        var results: [String: GuideImportPipeline.Result] = [:]
        for d in GuideRefreshPlanner.due(states, conditions) {
            try Task.checkCancellation()
            guard let src = registry.source(d.id) else { continue }
            results[d.id] = await GuideImportPipeline(db: db).run(src, row: rows.first { $0.id == d.id }, windowDays: windowDays, now: conditions.now)
        }
        return results
    }
}
