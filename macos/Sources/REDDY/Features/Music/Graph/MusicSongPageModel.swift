import SwiftUI
import Observation

/// Everything the song page holds besides the shared entity model: the row the player can start, the provider's suggestions, the person's own
/// playlists and the playback sources. Every part loads on demand (a block asks when it scrolls into view), one at a time under the page's gate, and is
/// cancelled with the page. Nothing here starts playback: Play is a tap on a button, never a side effect of opening the page.
@MainActor @Observable
final class MusicSongPageModel {
    let hub: MusicHub
    let entity: MusicEntityID
    private(set) var lease: MusicEntityLease?
    /// The row the player can start, built from the graph's provider alias. Nil when the graph holds none (a recording known only from MusicBrainz).
    private(set) var track: MusicTrack?
    /// The row used for words only (matching copies, lyrics): `track`, or a stand-in carrying the same title and artists.
    private(set) var matchBase: MusicTrack?
    private(set) var uids: Set<String> = []
    private(set) var providerRelated: [MusicTrack] = []
    private(set) var providerRelatedState: MusicSongLoad = .idle
    private(set) var localPlaylists: [MusicSongPlaylistItem] = []
    private(set) var sources: [MusicSongSource] = []
    private(set) var sourcesState: MusicSongLoad = .idle
    /// True when a source search finished and found nothing at all.
    private(set) var sourcesSearched = false

    @ObservationIgnored let env = MusicSongLoaderEnv()
    @ObservationIgnored private var loaders: [MusicSongSectionKey: any MusicEntitySectionLoader] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var builtFor: Date?

    init(hub: MusicHub, entity: MusicEntityID) {
        self.hub = hub; self.entity = entity
        for l in env.loaders() {
            if let k = MusicSongSectionKey.allCases.first(where: { $0.loaderKey == l.key }) { loaders[k] = l }
        }
    }

    var model: MusicEntityModel? { lease?.model }

    func open() {
        guard lease == nil else { return }
        lease = MusicEntityRuntime.shared.center.acquire(entity)
    }

    func close() {
        for t in tasks.values { t.cancel() }
        tasks = [:]
        lease?.release(); lease = nil
        track = nil; matchBase = nil
        providerRelatedState = .idle; sourcesState = .idle; builtFor = nil
    }

    /// Asks the shared model to load one graph-backed section. It does nothing when the section is loaded or running.
    func ensure(_ key: MusicSongSectionKey) {
        guard let m = model, m.snapshot != nil, let l = loaders[key] else { return }
        m.load(l)
    }

    /// The page's derived content: the items and block states the views draw (pure, see `MusicSongPageData`).
    var data: MusicSongPageData {
        var d = MusicSongPageData(selfID: model?.id ?? entity)
        for k in MusicSongSectionKey.allCases { d.sections[k] = section(k) }
        d.selfName = model?.name ?? ""
        d.providerRelated = providerRelated; d.providerState = providerRelatedState; d.providerAvailable = track != nil
        d.providerName = track.map { hub.providerName($0.providerID) } ?? ""
        d.localPlaylists = localPlaylists; d.hasMatchBase = matchBase != nil; d.sourcesState = sourcesState
        return d
    }

    func section(_ key: MusicSongSectionKey) -> MusicEntitySection { model?.section(key.loaderKey) ?? MusicEntitySection(key: key.loaderKey) }

    // MARK: the playable row

    /// Builds `track` and `matchBase` from the graph once the entity row is here (and again when its row changes). Local reads only.
    func buildTrack() async {
        guard let m = model, let snap = m.snapshot, builtFor != snap.updatedAt else { return }
        builtFor = snap.updatedAt
        let graph = MusicEntityRuntime.shared.store.graph
        let ids = (try? await graph.externalIDs(of: snap.id)) ?? []
        let preferred = hub.registry.audio.map(\.id)
        var row = MusicSongPlayable.track(snapshot: snap, externalIDs: ids, artists: [], album: nil, preferredProviders: preferred)
        let providerID = row?.providerID
        // The performers are read side by side (each needs its row and its ids), not one after another: Play appears as soon as the slowest read is done.
        let performers = ((try? await graph.edges(of: snap.id, predicate: .performedBy, direction: .outgoing, limit: 8)) ?? []).filter { !$0.tombstone }
        let read: [(Int, String, String?)] = await withTaskGroup(of: (Int, String, String?)?.self) { group in
            for (i, e) in performers.enumerated() {
                group.addTask {
                    guard let p = try? await graph.entity(e.object) else { return nil }
                    let pids = (try? await graph.externalIDs(of: p.id)) ?? []
                    // A provider artist id is only meaningful to the provider the row belongs to.
                    let own = pids.compactMap { x -> String? in x.scheme == .provider ? MusicSongPlayable.split(x.value).flatMap { $0.0 == providerID ? $0.1 : nil } : nil }.first
                    return (i, p.name, own)
                }
            }
            var out: [(Int, String, String?)] = []
            for await r in group { if let r { out.append(r) } }
            return out.sorted { $0.0 < $1.0 }
        }
        var artists: [MusicArtistRef] = []
        var seen = Set<String>()
        for (_, name, own) in read where seen.insert(name).inserted { artists.append(MusicArtistRef(id: own ?? "", name: name)) }
        var album: MusicAlbumRef?
        if let placement = (try? await graph.edges(of: snap.id, predicate: .trackOn, direction: .outgoing, limit: 4))?.first(where: { !$0.tombstone }),
           let a = try? await graph.entity(placement.object) {
            let aids = (try? await graph.externalIDs(of: a.id)) ?? []
            let own = aids.compactMap { x -> String? in x.scheme == .provider ? MusicSongPlayable.split(x.value).flatMap { $0.0 == providerID ? $0.1 : nil } : nil }.first
            album = MusicAlbumRef(id: own ?? a.name, title: a.name)
        }
        guard !Task.isCancelled else { builtFor = nil; return }
        row?.artists = artists; row?.album = album
        uids = MusicSongPlayable.uids(ids)
        track = row
        matchBase = row ?? MusicSongPlayable.searchBase(snapshot: snap, artists: artists, album: album)
        refreshLocalPlaylists()
    }

    // MARK: playlists (item 16)

    func refreshLocalPlaylists() {
        let summaries = hub.library.playlists.map { MusicSongPlaylists.LocalSummary(id: $0.id, name: $0.name, trackUIDs: $0.tracks.map(\.uid), created: $0.created) }
        localPlaylists = MusicSongPlaylists.local(containing: uids.union(track.map { [$0.uid] } ?? []), in: summaries)
    }

    // MARK: provider suggestions (item 12)

    func loadProviderRelated() {
        guard providerRelatedState == .idle, let t = track else { return }
        providerRelatedState = .loading
        tasks["providerRelated"]?.cancel()
        tasks["providerRelated"] = Task { [weak self] in
            guard let self else { return }
            let resolver = MusicRelatedShared.resolver(for: self.hub)
            let list = (try? await self.env.gate.run { await resolver.suggestions(for: t) }) ?? []
            guard !Task.isCancelled else { return }
            self.providerRelated = Array(list.prefix(24))
            self.providerRelatedState = .loaded
            // The suggestions become graph rows, so a tap on one opens its own page.
            MusicGraphIngest.shared.ingest(tracks: self.providerRelated, limit: 20)
        }
    }

    // MARK: playback sources (item 18)

    /// Lists the copies that can play this song. Reading only: the matcher's dry run and the provider candidate lists open no stream.
    func loadSources() {
        guard sourcesState == .idle, let base = matchBase else { return }
        sourcesState = .loading
        tasks["sources"]?.cancel()
        tasks["sources"] = Task { [weak self] in
            guard let self else { return }
            let hub = self.hub
            let audioIDs = Set(hub.registry.audio.map(\.id))
            let chosen = hub.matchOverrides.entry(for: base).map { $0.providerID + ":" + $0.sourceID }
            var rows: [MusicSongSource] = []
            if let t = self.track, let own = MusicSongSources.ownRow(of: t, providerName: hub.providerName(t.providerID), isAudioProvider: audioIDs.contains(t.providerID), chosen: chosen) {
                rows.append(own)
            }
            if let canon = MusicCanonicalStore.shared.canonical(for: base) {
                rows += canon.twins.map { MusicSongSources.source(twin: $0, providerName: hub.providerName($0.providerID), chosen: chosen) }
            }
            self.sources = MusicSongSources.combine(rows)
            if let matcher = MusicCatalogRuntime.shared.matcher, !Task.isCancelled {
                let dry = await matcher.dryRun(MusicCatalogCanon.make(from: base))
                rows += dry.twins.map { MusicSongSources.source(twin: $0, providerName: hub.providerName($0.providerID), chosen: chosen) }
                self.sources = MusicSongSources.combine(rows)
            }
            if !Task.isCancelled, !hub.registry.audio.isEmpty {
                let cands = await hub.matchOverrides.candidates(for: base, registry: hub.registry)
                rows += cands.prefix(8).map { MusicSongSources.source(candidate: $0, score: MusicStreamResolver.score(track: base, candidate: $0), providerName: hub.providerName($0.providerID), chosen: chosen) }
                self.sources = MusicSongSources.combine(rows)
            }
            guard !Task.isCancelled else { return }
            self.sourcesSearched = self.sources.isEmpty
            // A copy the matcher is sure of becomes the song's playable row, so the page shows Play: the button did its searches and then left the page as it was.
            if self.track == nil, let best = self.sources.first(where: { $0.trust == .verified }) { self.track = MusicSongSources.playable(from: best, base: base) }
            self.sourcesState = .loaded
        }
    }

    // MARK: actions (each one is a tap)

    func play() {
        guard let t = track else { return }
        hub.play([t], at: 0)
    }

    func play(from s: MusicSongSource) {
        guard let base = matchBase else { return }
        hub.play([MusicSongSources.playable(from: s, base: base, youTubeFamily: MusicTwinRules.standard.youTubeFamily)], at: 0)
    }

    func enqueue() { if let t = track { hub.player.enqueue([t]) } }
    func playNext() { if let t = track { hub.player.playNext([t]) } }
    func toggleLike() { if let t = track { hub.library.toggleLike(t) } }
    var isLiked: Bool { track.map { hub.library.isLiked($0) } ?? false }

    func open(_ id: MusicEntityID, role: MusicRole? = nil) { hub.open(id, role: role) }
}
