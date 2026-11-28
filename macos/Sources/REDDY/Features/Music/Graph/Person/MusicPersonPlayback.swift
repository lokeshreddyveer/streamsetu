import Foundation
import Observation

/// What the person page's buttons do: Play, Shuffle, Start radio, Follow. It turns the graph's recordings into playable tracks through the providers'
/// own ids (the same ones the rest of Music plays), and keeps the provider's top tracks for this artist ready, so Play works the moment the page is open
/// even before the graph has loaded a single section. Playing replaces the queue only here, on the person's own press; opening a page never does.
@MainActor @Observable
final class MusicPersonPlayback {
    let hub: MusicHub
    let person: MusicEntityID
    let graph: any MusicGraphStoring
    private(set) var fallback: [MusicTrack] = []
    private(set) var providerArtist: (providerID: String, id: String)?
    private(set) var busy = false
    /// The person's display name, set by the page once the header is known: the queue's "Playing from" shows it.
    @ObservationIgnored var sourceName: String?
    /// The provider artist's own top tracks stand in only for a musical role; an actor or director never gets someone's singing as their own music.
    var allowsProviderFallback = true
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private var prefetchFinished = false
    /// Counts row plays, so a slow earlier tap never replaces a later one and a repeated tap queues the rest once.
    @ObservationIgnored private var songPlayGeneration = 0

    init(hub: MusicHub, person: MusicEntityID, graph: any MusicGraphStoring) { self.hub = hub; self.person = person; self.graph = graph }

    // MARK: ready before the graph is

    /// Looks up the person's provider artist (from the `provider` alias) and fetches its top tracks, once.
    /// `retry` is for a page that learned more about the person since (a provider alias lands after enrichment): it looks again only when the first look found no provider artist and has finished.
    func prefetchFallback(retry: Bool = false) {
        guard Self.shouldPrefetch(started: prefetch != nil, retry: retry, hasProviderArtist: providerArtist != nil, finished: prefetchFinished) else { return }
        prefetchFinished = false
        let hub = self.hub, person = self.person, graph = self.graph
        prefetch = Task { [weak self] in
            defer { Task { @MainActor in self?.prefetchFinished = true } }
            let uids = MusicProviderUID.uids(in: (try? await graph.externalIDs(of: person)) ?? [])
            // A person known under two provider ids, followed under one of them, keeps showing that one: Follow, Share and the listening stats use it.
            let followed = Set(hub.library.followedArtists.map(\.uid))
            let preferred = MusicProviderUID.followedArtist(in: uids, followed: followed)
            if let preferred { self?.providerArtist = preferred }
            for uid in uids {
                guard let (pid, aid) = MusicProviderUID.split(uid), let provider = hub.registry.metadataProvider(id: pid) else { continue }
                if preferred == nil { self?.providerArtist = (pid, aid) }
                if let tracks = try? await MusicStreamResolver.withDeadline(8, { try await provider.artistTopTracks(id: aid) }), !tracks.isEmpty { self?.fallback = tracks; return }
            }
        }
    }
    /// The first call always looks; a retry looks again only when the earlier look has finished without finding a provider artist.
    nonisolated static func shouldPrefetch(started: Bool, retry: Bool, hasProviderArtist: Bool, finished: Bool) -> Bool {
        !started || (retry && !hasProviderArtist && finished)
    }

    func cancel() { prefetch?.cancel(); prefetch = nil; prefetchFinished = false }

    /// The provider artist as the library knows it, for Follow. Nil for a person with no provider id (nothing to follow on a service).
    func followTarget(name: String, imageRef: String?) -> MusicArtist? {
        guard let (pid, aid) = providerArtist else { return nil }
        var a = MusicArtist(id: aid, providerID: pid, name: name)
        if let url = MusicPersonImage.address(imageRef) { a.thumbnails = [MusicThumbnail(url: url, width: 300, height: 300)] }
        return a
    }

    // MARK: graph to tracks

    /// Playable tracks for these recordings, in order (at most `limit`): each one's provider uid, fetched through that provider. A recording with no
    /// provider id (a name-only credit from a film database) is skipped; it has nothing to play.
    func tracks(forSongs ids: [MusicEntityID], limit: Int = MusicPersonPlaySource.maxSongs) async -> [MusicTrack] {
        let hub = self.hub, graph = self.graph
        var out: [Int: MusicTrack] = [:]
        await withTaskGroup(of: (Int, MusicTrack?).self) { group in
            var next = 0, inFlight = 0
            func launch(_ i: Int) {
                let id = ids[i]
                group.addTask {
                    for uid in MusicProviderUID.uids(in: (try? await graph.externalIDs(of: id)) ?? []) {
                        guard let (pid, tid) = MusicProviderUID.split(uid), let provider = await hub.registry.metadataProvider(id: pid) else { continue }
                        if let t = try? await MusicStreamResolver.withDeadline(8, { try await provider.track(id: tid) }) { return (i, t) }
                    }
                    return (i, nil)
                }
            }
            let cap = min(ids.count, limit)
            while next < cap && inFlight < 5 { launch(next); next += 1; inFlight += 1 }
            for await (i, t) in group {
                inFlight -= 1
                if let t { out[i] = t }
                if next < cap { launch(next); next += 1; inFlight += 1 }
            }
        }
        return out.keys.sorted().compactMap { out[$0] }
    }

    /// The first album with a provider tracklist, played from the provider's own list.
    func tracks(forAlbums ids: [MusicEntityID]) async -> [MusicTrack] {
        for id in ids {
            for uid in MusicProviderUID.uids(in: (try? await graph.externalIDs(of: id)) ?? []) {
                guard let (pid, aid) = MusicProviderUID.split(uid), let provider = hub.registry.metadataProvider(id: pid) else { continue }
                if let t = try? await provider.albumTracks(id: aid, page: nil).items, !t.isEmpty { return t }
            }
        }
        return []
    }

    /// The tracks of a play source; falls back to the provider's artist tracks when the graph gives none.
    func tracks(for source: MusicPersonPlaySource) async -> [MusicTrack] {
        var list: [MusicTrack] = []
        switch source {
        case .songs(let ids): list = await tracks(forSongs: ids)
        case .albums(let ids): list = await tracks(forAlbums: ids)
        case .providerArtist: break
        }
        if list.isEmpty, allowsProviderFallback { list = fallback }
        return list
    }

    // MARK: actions

    func play(_ source: MusicPersonPlaySource, shuffle: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let list = await tracks(for: source)
        guard !list.isEmpty else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        if shuffle { hub.playShuffled(list, sourceName: sourceName) } else { hub.play(list, at: 0, sourceName: sourceName) }
    }

    func radio(_ source: MusicPersonPlaySource) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        guard let seed = await tracks(for: source).first else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        await MusicQueueActions.startRadio(seed, hub: hub)
    }

    /// One song, from its row's play button.
    /// With `queue` (the list the row sits in, from this row onward) the rest of that list follows it, so a row inside Songs or Not played yet plays on instead of stopping after one.
    func playSong(_ id: MusicEntityID, queue: [MusicEntityID] = []) async {
        songPlayGeneration += 1
        let generation = songPlayGeneration
        let list = await tracks(forSongs: [id], limit: 1)
        guard generation == songPlayGeneration else { return }
        guard let t = list.first else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        hub.play([t], at: 0, sourceName: sourceName)
        let rest = Array(queue.filter { $0 != id }.prefix(MusicArtistPlayCap.songs))
        guard !rest.isEmpty else { return }
        let more = await tracks(forSongs: rest, limit: MusicArtistPlayCap.songs).filter { $0.uid != t.uid }
        // Only while this song is still the one playing: the person may have chosen something else meanwhile.
        guard !Task.isCancelled, generation == songPlayGeneration, !more.isEmpty, hub.player.current?.uid == t.uid else { return }
        hub.player.enqueue(more, quiet: true)
    }
    // MARK: bounded sets (the artist page's pills and radio modes)

    /// Plays or shuffles a bounded set of recordings through the same player calls every other page uses. The caller bounds the set (`MusicArtistPlayCap`); this cuts at the cap again.
    func playSet(_ ids: [MusicEntityID], shuffle: Bool) async {
        guard !busy, !ids.isEmpty else { return }
        busy = true; defer { busy = false }
        let list = await tracks(forSongs: ids, limit: MusicArtistPlayCap.songs)
        guard !list.isEmpty else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        if shuffle { hub.playShuffled(list, sourceName: sourceName) } else { hub.play(list, at: 0, sourceName: sourceName) }
    }

    /// A new playlist of a bounded set of recordings (at most `MusicArtistPlayCap.songs`), each resolved through its own provider like every other play.
    func createPlaylist(name: String, ids: [MusicEntityID]) async {
        guard !busy, !ids.isEmpty else { return }
        busy = true; defer { busy = false }
        let list = await tracks(forSongs: ids, limit: MusicArtistPlayCap.songs)
        guard !list.isEmpty else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        _ = hub.library.createPlaylist(name: name, tracks: list)
        MusicToasts.shared.show(Localized.string("Playlist created: %1$@", name))
    }

    /// Puts a bounded set after the current song (`next`) or at the end of the queue. Never replaces the queue.
    func queueSet(_ ids: [MusicEntityID], next: Bool) async {
        guard !busy, !ids.isEmpty else { return }
        busy = true; defer { busy = false }
        let list = await tracks(forSongs: ids, limit: MusicArtistPlayCap.queue)
        guard !list.isEmpty else { MusicToasts.shared.show(MusicPersonWording.nothingToPlay); return }
        if next { hub.player.playNext(list) } else { hub.player.enqueue(list) }
    }
}
