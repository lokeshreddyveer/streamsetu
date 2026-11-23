import Foundation
import Observation

/// The one live hub of the app: real providers, the Keychain, the app's HTTP client. Created on first use.
enum HubRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instance: MetadataHub?

    static func shared(container c: AppContainer) -> MetadataHub {
        lock.withLock {
            if let i = instance { return i }
            let http = c.http
            let fetch: HubFetch = { try await http.data($0, maxBytes: 2_000_000) }
            let secrets = KeychainSecretStore()
            let accessFor: @Sendable (HubSource) -> HubAccess = { HubAccess.standard($0, secrets: secrets) }
            let fanart = FanartProvider(keys: { FanartKeys.resolve(accessFor(.fanart)) }, fetch: fetch)
            let tvdb = TVDBProvider(session: TVDBSession(access: accessFor(.tvdb), fetch: fetch))
            let metadata = c.metadata
            let hub = MetadataHub(store: HubStore(db: c.db), artwork: [fanart, tvdb], episodes: [TVmazeProvider(fetch: fetch)],
                                  access: [.fanart: accessFor(.fanart), .tvdb: accessFor(.tvdb), .tvmaze: accessFor(.tvmaze)],
                                  isSendable: { metadata.isSendable($0) })
            instance = hub
            return hub
        }
    }
}

/// What a title page reads. Create one per page; call `open` when the page appears and `close` when it goes away. It never waits on the network: it shows what is saved
/// and updates itself when the hub lands something (the same `titleMetadataLanded` notification the page already listens to).
@MainActor @Observable final class TitleHubModel {
    private(set) var logoURL: String?
    private(set) var backdropURL: String?
    private(set) var posterURL: String?
    /// ISO time of the next episode (a series), with its time zone: "2026-12-01T02:00:00+00:00".
    private(set) var nextEpisodeStamp: String?
    /// The sources behind what is saved for this title: kept for the Credits wording only (no screen shows a footer from it now).
    private(set) var provenance: Set<HubSource> = []

    private var item: String?
    private var hub: MetadataHub?
    private var observer: NSObjectProtocol?

    func open(itemID: String, isSeries: Bool, container c: AppContainer) {
        close()
        item = itemID
        let hub = HubRuntime.shared(container: c); self.hub = hub
        let store = HubStore(db: c.db)
        var ids = store.identity(itemID)?.ids ?? HubIdentity()
        if let p = ProviderIDStore(db: c.db).ids(for: itemID) { ids = HubIdentity.merge(ids, HubIdentity(tmdb: p.tmdb, imdb: p.imdb), incomingRank: 0, existingRank: 1) }
        if ids.tmdb == nil, let t = try? c.db.read({ try $0.queryOne("SELECT tmdb_id FROM metadata_matches WHERE item_id=? AND tmdb_id IS NOT NULL", [itemID]) { $0.optInt(0) } }) ?? nil { ids.tmdb = t }
        observer = NotificationCenter.default.addObserver(forName: .titleMetadataLanded, object: nil, queue: .main) { [weak self] n in
            let hit = TitleMetadataEvent(n).ids.contains(itemID)
            if hit { Task { @MainActor in await self?.reload() } }
        }
        Task { await reload(); await hub.titleAppeared(itemID, identity: ids, kind: isSeries ? .series : .movie) }
    }
    func close() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if let i = item, let h = hub { Task { await h.titleGone(i) } }
        item = nil
    }
    private func reload() async {
        guard let item, let hub else { return }
        logoURL = await hub.image(item, .logo); backdropURL = await hub.image(item, .backdrop); posterURL = await hub.image(item, .poster)
        nextEpisodeStamp = await hub.text(item, "nextepisode"); provenance = await hub.provenance(item)
    }
}
