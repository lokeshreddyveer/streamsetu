import Foundation

/// The one front door of "what picture belongs to this thing" for every Music screen. Main actor; the work happens in `MusicEntityArtworkResolver`
/// (an actor) behind it. Nothing here runs until a cover asks, nothing waits on the playback path, and every picture is downloaded, sized and cached by
/// Music's own `MusicArtworkService`, never by the app-wide artwork code.
@MainActor
final class MusicEntityArtwork {
    static let shared = MusicEntityArtwork()

    /// Settings > Plugins & Sources > Metadata sources: "Find pictures online" (default on). Off: only pictures the app already holds are used.
    nonisolated static let onlineKey = "music.artwork.online"
    nonisolated static var onlineEnabled: Bool { UserDefaults.standard.object(forKey: onlineKey) as? Bool ?? true }

    private(set) var resolver: MusicEntityArtworkResolver?
    /// Addresses that failed to load after being resolved: asked about again once, then left to the designed tile.
    private var reported: Set<String> = []

    /// The governed transport and the same gate the artwork lookups use, for the other small public lookups of the person page (the Wikipedia summary).
    private(set) var networkTransport: (any MusicMetadataTransport)?
    /// The app's TMDB client (the one the movie pages use), for a person's biography.
    private(set) var tmdbFetch: (@Sendable (String, [URLQueryItem]) async throws -> Data)?
    private(set) var networkAllowed: @Sendable () -> Bool = { false }
    func transportIfAllowed() -> (any MusicMetadataTransport)? { networkAllowed() ? networkTransport : nil }

    /// The sources in chain order of use (the plan per kind decides the order; this is only the set).
    nonisolated static func defaultSources() -> [any MusicArtworkSource] {
        [WikimediaArtworkSource(), TMDBArtworkSource(), IMDbArtworkSource(), CoverArtArtworkSource(), DeezerArtworkSource(), ITunesArtworkSource(), JioSaavnArtworkSource()]
    }

    /// Called once by the metadata runtime with the governed transport (host lanes, single flight, breaker), the graph and the app's TMDB client.
    func install(transport: any MusicMetadataTransport, graph: (any MusicArtworkGraphContext)?,
                 tmdb: (@Sendable (String, [URLQueryItem]) async throws -> Data)?, flags: MusicEnrichmentFlags = .shared,
                 switches: MusicMetadataSwitches = .shared, directory: URL = MusicStorage.subfolder("ArtworkResolution")) {
        let gate = MusicArtworkGate(
            networkAllowed: { flags.consentGiven && !flags.kidsOrLocked && !flags.offline && MusicEntityArtwork.onlineEnabled },
            sourceOn: { switches.isOn($0) })
        let context = MusicArtworkContext(transport: transport, tmdb: tmdb)
        networkTransport = transport
        tmdbFetch = tmdb
        networkAllowed = { flags.consentGiven && !flags.kidsOrLocked && !flags.offline && MusicEntityArtwork.onlineEnabled }
        let cache = MusicArtworkResolutionCache(file: directory.appendingPathComponent("resolution.json"))
        // The probe loads the picture through Music's own artwork service: a dead link or a non-picture falls to the next source, and the disk cache is warm.
        let probe: @Sendable (String) async -> Bool = { address in await MusicArtworkService.shared.load(address, targetPixelSize: 256) != nil }
        resolver = MusicEntityArtworkResolver(sources: Self.defaultSources(), graph: graph, cache: cache, gate: gate, context: context, maxConcurrent: 2, probe: probe)
    }

    /// The remembered picture address, with no waiting and no network: lets a card seen before paint its picture on the first frame.
    func cachedAddress(_ subject: MusicArtworkSubject) -> String? { MusicArtworkOverrides.shared.address(for: subject) ?? resolver?.cached(subject)?.address }

    func cachedResult(_ subject: MusicArtworkSubject) -> MusicResolvedArtwork? { resolver?.cached(subject) }

    /// Resolves (or reads the remembered answer). Cancelling the caller (a cover that scrolled away) drops its interest.
    func resolve(_ subject: MusicArtworkSubject) async -> MusicResolvedArtwork? {
        if let chosen = MusicArtworkOverrides.shared.address(for: subject) {
            return MusicResolvedArtwork(address: chosen, source: "chosen", confidence: 1, evidence: [], credit: nil, resolvedAt: Date(), borrowedFrom: nil)
        }
        guard let resolver else { return nil }
        return await resolver.resolve(subject)
    }

    /// A resolved address that would not load: forgotten so the next ask resolves again, but only once per address in a session.
    func reportBroken(_ subject: MusicArtworkSubject, address: String) {
        guard reported.insert(subject.key + "|" + address).inserted, let resolver else { return }
        Task { await resolver.forget(subject, address: address) }
    }

    /// Privacy wipe (called from the Music wipe): every remembered answer, in memory and on disk.
    func clear() { resolver?.cache.clear(); reported.removeAll() }
}

extension MusicArtworkClass {
    /// The slot (and so the size to request from the host) each existing artwork class draws in.
    var slot: MusicArtworkSlot {
        switch self {
        case .trackThumb: .row
        case .mini: .miniPlayer
        case .tile, .artistPortrait, .playlistCover: .card
        case .hero, .nowPlaying, .fullscreen: .nowPlaying
        }
    }
}
