import Foundation

/// The app's one entity store and model center, over the app's graph store. Created on first use; nothing opens a database until a page asks.
@MainActor
final class MusicEntityRuntime {
    static let shared = MusicEntityRuntime()
    private(set) var store: MusicEntityStore
    private(set) var center: MusicEntityModelCenter
    private init() {
        let s = MusicEntityStore(graph: MusicGraphRuntime.shared.store)
        store = s
        center = MusicEntityModelCenter(store: s)
    }
    /// G2/G3 install their enrichers through this.
    func install(enricher: any MusicEntityEnriching) { store.enricher = enricher }
    /// The full-list pass that rides the model center's leases (see `MusicEntityCompletenessCoordinator`).
    func install(completeness: any MusicEntityCompleting) { self.completeness = completeness; center.completeness = completeness }
    private(set) var completeness: (any MusicEntityCompleting)?
    /// Points the pages at another graph (tests and the snapshot harness seed an in-memory graph this way). Models of the old store are dropped.
    func use(graph: any MusicGraphStoring) {
        center.dropAll()
        completeness = nil
        let s = MusicEntityStore(graph: graph)
        store = s
        center = MusicEntityModelCenter(store: s)
    }
    /// Part of the privacy wipe.
    func wipe() { center.dropAll(); store.reset(); MusicCompletenessTracker.shared.reset() }
}
