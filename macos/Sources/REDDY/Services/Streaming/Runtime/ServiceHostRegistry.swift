import Foundation
import WebKit

/// Owns the models of the embedded services: made lazily (one per service, only when first needed, never all at startup), kept for the life of
/// the app, and held to a memory budget. Web views are released least-recently-used first; their website data is never touched. Every switch
/// pauses the media of every other live web view, because separate data stores are not separate processes.
@MainActor final class ServiceHostRegistry: ServiceHostResolving {
    let registry: ProviderRegistry
    private let makeModel: (ProviderDefinition) -> ServiceWebModel
    private let clock: () -> Date
    var budget: MemoryBudget
    private var models: [ProviderID: ServiceWebModel] = [:]
    private var lastUsed: [ProviderID: Date] = [:]
    private var terminations: [Date] = []
    private(set) var visibleID: ProviderID?
    /// The cross-provider limit: this many stops within the recovery window across all services end automatic reloading.
    let circuitBreakerLimit = 3
    private(set) var circuitBreakerTrips = 0

    init(registry: ProviderRegistry = .standard, budget: MemoryBudget = .standard, clock: @escaping () -> Date = { Date() },
         makeModel: @escaping (ProviderDefinition) -> ServiceWebModel = { ServiceWebModel.forApp($0) }) {
        self.registry = registry; self.budget = budget; self.clock = clock; self.makeModel = makeModel
    }

    /// The service's model, made on first request. Nil for an unknown service or one the registry does not present as embedded.
    func model(for id: ProviderID) -> ServiceWebModel? {
        if let m = models[id] { return m }
        guard let d = registry.definition(for: id), d.platforms.contains(.macOS), d.presentation == .embedded else { return nil }
        let m = makeModel(d)
        m.onBecameVisible = { [weak self] id in self?.didBecomeVisible(id) }
        m.onBecameHidden = { [weak self] id in self?.didBecomeHidden(id) }
        m.onMemoryPressure = { [weak self] critical in self?.handleMemoryPressure(critical: critical) }
        m.onTermination = { [weak self] id, at in self?.recordTermination(of: id, at: at) ?? .reload }
        models[id] = m
        return m
    }

    func host(for id: ProviderID) -> (any ExternalServiceHost)? { model(for: id) }

    /// Models that have been made (for tests and diagnostics; no web view implied).
    var createdIDs: [ProviderID] { models.keys.sorted { $0.rawValue < $1.rawValue } }
    /// Models that currently own a web view.
    var liveIDs: [ProviderID] { models.filter { entry in entry.value.webView != nil }.keys.sorted { $0.rawValue < $1.rawValue } }

    // MARK: switching and retention

    /// A service is about to show: everything else stops and the retention plan is applied.
    func didBecomeVisible(_ id: ProviderID) {
        visibleID = id; lastUsed[id] = clock()
        pauseAll(except: id)
        applyRetention(budget: budget.maxLiveWebViews)
    }

    func didBecomeHidden(_ id: ProviderID) {
        if visibleID == id { visibleID = nil }
        lastUsed[id] = clock()
        applyRetention(budget: budget.maxLiveWebViews)
    }

    /// Pauses (and closes full-screen or picture-in-picture for) every live web view except one. Nothing resumes by itself.
    func pauseAll(except id: ProviderID? = nil) {
        for (key, m) in models where key != id { m.pauseMedia() }
    }

    /// The same, returning once every page has actually paused.
    func pauseAllAndWait(except id: ProviderID? = nil) async {
        for (key, m) in models where key != id { await m.pauseMediaAndWait() }
    }

    func applyRetention(budget: Int) {
        let live = liveIDs
        for id in RetentionPlan.releaseList(live: live, lastUsed: lastUsed, visible: visibleID, budget: budget) { evict(id) }
    }

    /// Pauses, then releases the web view of a hidden service. Its website data stays, so signing in again is not needed.
    private func evict(_ id: ProviderID) {
        guard let m = models[id], !m.isVisible else { return }
        m.releaseResources()          // pauses first; the page is torn down either way
    }

    /// Memory is tight: hidden web views go (one stays on a warning when the budget allows it).
    func handleMemoryPressure(critical: Bool) { applyRetention(budget: critical ? 0 : budget.warningMaxLive) }

    func releaseHidden() { for id in liveIDs where id != visibleID { evict(id) } }

    // MARK: termination circuit breaker

    /// Records a stopped web process. When several services stop within the window, a shared process is probably failing: automatic reloading
    /// ends everywhere, hidden web views are released and only the visible service shows its Retry card.
    @discardableResult func recordTermination(of id: ProviderID, at: Date) -> TerminationAction {
        terminations = RecoveryPolicy.standard.recent(terminations, now: at) + [at]
        guard terminations.count >= circuitBreakerLimit else { return .reload }
        circuitBreakerTrips += 1
        for other in liveIDs where other != id && other != visibleID { evict(other) }
        return .showRetryCard
    }
}
