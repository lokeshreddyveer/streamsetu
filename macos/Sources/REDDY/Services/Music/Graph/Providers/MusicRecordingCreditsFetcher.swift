import Foundation

/// Fetches a provider's own credits for a recording the graph already holds and writes them as claims (YouTube Music's "Song credits" panel, through
/// `YouTubeMusicClient.trackCredits(videoID:)`). It runs inside the enrichment hook that fires when a page opens the recording: in the background,
/// one request at a time, never on the playback path, only when the recording has a YouTube video id, and at most once per freshness window.
/// What it writes is exactly what the panel listed (names and the roles the panel gave); no role is guessed and no person is merged by name.
struct MusicRecordingCreditsFetcher: Sendable {
    typealias Fetch = @Sendable (_ videoID: String) async -> [MusicCredit]

    let store: any MusicGraphStoring
    /// Nil when the provider is off, locked, or not built: nothing is asked.
    let youTubeMusic: Fetch?
    var now: @Sendable () -> Date = { Date() }

    static let facet = "providerCredits"
    static let source = MusicSourceID("ytmusic")
    /// A panel that listed nothing (or failed) is not asked again for this long.
    static let emptyTTL: TimeInterval = 86_400

    init(store: any MusicGraphStoring, youTubeMusic: Fetch?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.youTubeMusic = youTubeMusic; self.now = now
    }

    /// What changed: the recording, when new credits were written.
    func run(_ recording: MusicEntityID) async -> MusicEnrichmentResult {
        guard let fetch = youTubeMusic, MusicSongReads.isSong(recording) else { return .none }
        let ids = (try? await store.externalIDs(of: recording)) ?? []
        guard let videoID = MusicSongPlayable.youTubeVideoID(ids) else { return .none }
        let t = now()
        if let st = try? await store.cacheState(entity: recording, facet: Self.facet, source: Self.source), !st.needsFetch(at: t) { return .none }
        guard !Task.isCancelled else { return .none }

        let credits = await fetch(videoID).filter { $0.level == .track }
        guard !Task.isCancelled else { return .none }
        guard !credits.isEmpty else {
            try? await store.setCacheState(entity: recording, facet: Self.facet, source: Self.source, outcome: .empty, ttl: Self.emptyTTL)
            return .none
        }
        // The recording's own provider alias keeps its draft on the same entity, so the claims attach to the row the page holds.
        let alias = ids.first { $0.scheme == .provider && MusicSongPlayable.split($0.value)?.0 == "ytmusic" } ?? ids.first { $0.scheme == .ytVideo }
        guard let alias else { return .none }
        var b = MusicCreditsAdapter.Builder(providerID: "ytmusic", sourceRef: "ytmusic:" + videoID, now: t)
        guard let snap = try? await store.entity(recording), !snap.name.isEmpty else { return .none }
        let draft = MusicEntityDraft(kind: .recording, name: snap.name, externalIDs: [alias], provisional: true)
        let rid = b.draft(draft)
        b.addCredits(credits, subjects: .init(track: rid, album: rid, film: nil), hints: nil)
        do {
            try await MusicCreditsAdapter.commit(b.batch, to: store)
            try? await store.setCacheState(entity: recording, facet: Self.facet, source: Self.source, outcome: .ok, ttl: MusicCreditsAdapter.providerTTL)
            return MusicEnrichmentResult(changed: [recording])
        } catch {
            try? await store.setCacheState(entity: recording, facet: Self.facet, source: Self.source, outcome: .error, ttl: 0)
            return .none
        }
    }
}
