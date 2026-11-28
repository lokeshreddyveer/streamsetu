import Foundation
import Observation

/// The two facts the enrichment policy reads from any thread: Music consent given, and the app locked or a Kids profile on. The hub keeps them current;
/// until it has, both read as "not allowed", so nothing is asked.
final class MusicEnrichmentFlags: @unchecked Sendable {
    static let shared = MusicEnrichmentFlags()
    private let lock = NSLock()
    private var _consent = false
    private var _held = true
    private var _offline = false
    var consentGiven: Bool { lock.withLock { _consent } }
    var kidsOrLocked: Bool { lock.withLock { _held } }
    var offline: Bool { lock.withLock { _offline } }
    func setOffline(_ v: Bool) { lock.withLock { _offline = v } }
    func update(consent: Bool, held: Bool) { lock.withLock { _consent = consent; _held = held } }
}

/// The resolver the film layer writes into once the metadata layer is installed (nil before, so the film page behaves exactly as it did).
final class MusicFilmGraphLink: @unchecked Sendable {
    static let shared = MusicFilmGraphLink()
    private let lock = NSLock()
    private var _resolver: MusicEntityResolver?
    var resolver: MusicEntityResolver? { get { lock.withLock { _resolver } } set { lock.withLock { _resolver = newValue } } }
}

extension MusicEntityRuntime {
    /// Builds the metadata layer over the app's graph store and installs it as the entity store's enricher. Everything here is lazy and in the
    /// background: a page asks, a task runs behind it, and nothing on the playback path awaits any of it. A source that is off, offline, over its rate
    /// lane or failing only means the page shows what the graph already holds.
    private static func keepFlagsCurrent(hub: MusicHub) {
        MusicEnrichmentFlags.shared.update(consent: !hub.needsConsent, held: hub.gated)
        withObservationTracking { _ = hub.library.settings; _ = hub.gated } onChange: { [weak hub] in
            Task { @MainActor in if let hub { keepFlagsCurrent(hub: hub) } }
        }
    }

    func installMetadata(hub: MusicHub) {
        let flags = MusicEnrichmentFlags.shared
        Self.keepFlagsCurrent(hub: hub)
        flags.setOffline(!MusicNetwork.watch.isOnline)
        let governor = MusicRequestGovernor()
        // The page the person is on (album, film, song enrichment) queues ahead of person completeness on a shared lane such as MusicBrainz's.
        let transport = MusicGovernedTransport(governor: governor, background: true, priority: .foreground)
        let completenessTransport = MusicGovernedTransport(governor: governor, background: true, priority: .background)
        let gate = MusicFilmTMDBGate.shared
        let tmdb: MusicFilmTMDBGate.Fetch = { path, query in
            guard let f = gate.fetch else { throw MusicError.notFound }
            return try await f(path, query)
        }
        let switches = MusicMetadataSwitches.shared
        let policy = MusicEnrichmentPolicy(consentGiven: { flags.consentGiven }, sourceOn: { switches.isOn($0) },
                                           kidsOrLocked: { flags.kidsOrLocked }, offline: { flags.offline })
        let resolver = MusicEntityResolver(store: MusicGraphRuntime.shared.store, sources: MusicMetadataSources.make(transport: transport, tmdb: tmdb), gate: policy)
        MusicFilmGraphLink.shared.resolver = resolver
        // Pictures for every screen: one resolver over the same governed transport (host lanes, single flight, breaker), the graph and the app's TMDB client.
        let artworkTMDB: @Sendable (String, [URLQueryItem]) async throws -> Data = { path, query in
            do { return try await tmdb(path, query) } catch let e as MusicError where e == .notFound { return Data() }
        }
        let artworkTransport = MusicGovernedTransport(governor: governor)
        let artworkGraph = MusicGraphArtworkContext(store: MusicGraphRuntime.shared.store)
        Task { @MainActor in MusicEntityArtwork.shared.install(transport: artworkTransport, graph: artworkGraph, tmdb: artworkTMDB) }
        // YouTube Music's "Song credits" panel: only for a recording with a video id, only while Music is allowed, on, online and unlocked, one request at a time.
        let ytCredits: MusicRecordingCreditsFetcher.Fetch? = {
            guard let yt = hub.registry.provider(id: YTM.providerID) as? YouTubeMusicFullProvider else { return nil }
            return { videoID in
                guard flags.consentGiven, !flags.kidsOrLocked, !flags.offline, await hub.registry.isEnabled(YTM.providerID) else { return [] }
                return await yt.client.trackCredits(videoID: videoID)
            }
        }()
        installCompleteness(resolver: resolver, transport: completenessTransport, gate: policy, catalogue: MusicPersonCatalogueFetcher.app(hub: hub))
        install(enricher: MusicGraphEnricher(resolver: resolver, credits: MusicRecordingCreditsFetcher(store: MusicGraphRuntime.shared.store, youTubeMusic: ytCredits)))
    }
}
