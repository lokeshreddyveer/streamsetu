import Foundation

// Where a station's songs come from. Each adapter turns one source (the provider's own recommendations, the graph recommender, the person's
// library) into the same candidate shape, so the station logic never knows which source a song came from. An adapter never throws: a source that
// fails answers with nothing, and the service then tries the next one.

@MainActor
struct RadioAdapters {
    let hub: MusicHub

    /// Songs for one seed from the providers. `found` is false when the provider knew nothing about the seed (it may have vanished).
    func provider(for seed: RadioSeed, limit: Int = 30, mode: RadioMode = .mixed) async -> (candidates: [RadioCandidate], found: Bool) {
        var out: [RadioCandidate] = []
        switch seed.kind {
        case .song:
            guard let t = seed.track else { return ([], false) }
            out.append(RadioCandidate(track: t, source: .provider, rank: 0, reason: MusicAutoplayReason(.radio, t.title), fromSeed: true))
            out += await recommendations(from: t, limit: limit, startRank: 1)
        case .artist:
            guard let a = seed.artist, let p = hub.registry.metadataProvider(id: a.providerID) else { return ([], false) }
            let top = (try? await p.artistTopTracks(id: a.id)) ?? []
            for (i, t) in top.enumerated() { out.append(RadioCandidate(track: t, source: .provider, rank: i, reason: MusicAutoplayReason(.artist, a.name), fromSeed: true)) }
            if let first = top.first { out += await recommendations(from: first, limit: limit, startRank: 20) }
            // Newly released and deep cuts need songs the top list does not hold: the artist's recent albums, or the older ones.
            if mode == .newlyReleased || mode == .deepCuts { out += await albumSongs(of: a, provider: p, newest: mode == .newlyReleased, startRank: 5) }
            // One hop to similar artists, so a station about one artist still brings others.
            let related = Array(((try? await p.relatedArtists(id: a.id)) ?? []).prefix(3))
            var rank = 60
            for r in related {
                let songs = (try? await p.artistTopTracks(id: r.id)) ?? []
                for t in songs.prefix(6) { out.append(RadioCandidate(track: t, source: .provider, rank: rank, reason: MusicAutoplayReason(.radio, a.name))); rank += 1 }
            }
        case .genre, .language, .mood:
            guard let q = seed.query, let p = hub.registry.activeMetadata else { return ([], false) }
            var found = ((try? await p.searchTracks(q, page: nil))?.items ?? []).filter { $0.isPodcast != true }
            if let key = seed.languageKey {
                let inLanguage = found.filter { MusicLanguageDetector.language(of: $0)?.rawValue == key }
                if !inLanguage.isEmpty { found = inLanguage }
            }
            for (i, t) in found.enumerated() { out.append(RadioCandidate(track: t, source: .provider, rank: i, reason: MusicAutoplayReason(.radio, seed.name), fromSeed: true)) }
            for t in found.prefix(2) { out += await recommendations(from: t, limit: limit / 2, startRank: 30) }
        }
        return (out, !out.isEmpty)
    }

    /// Songs from an artist's albums with the album's release date put on each song (the mode rules read it): the newest albums, or the older ones for deep cuts.
    func albumSongs(of artist: MusicArtist, provider p: any MusicMetadataProvider, newest: Bool, startRank: Int, albums want: Int = 3) async -> [RadioCandidate] {
        guard let page = try? await p.artistAlbums(id: artist.id, page: nil) else { return [] }
        let dated = page.items.filter { ($0.releaseDate ?? "").count >= 4 }.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        let chosen = newest ? Array(dated.prefix(want)) : Array(dated.dropFirst(1).prefix(want))
        var out: [RadioCandidate] = []
        var rank = startRank
        for album in chosen {
            guard let tracks = try? await p.albumTracks(id: album.id, page: nil) else { continue }
            let ref = MusicAlbumRef(id: album.id, title: album.title, artists: album.artists, thumbnails: album.thumbnails, releaseDate: album.releaseDate)
            for var t in tracks.items.prefix(8) where t.isPodcast != true {
                if t.album == nil { t.album = ref } else if t.album?.releaseDate == nil { t.album?.releaseDate = album.releaseDate }
                out.append(RadioCandidate(track: t, source: .provider, rank: rank, reason: MusicAutoplayReason(.artist, artist.name), fromSeed: true))
                rank += 1
            }
        }
        let songCount = out.count, albumCount = chosen.count, kind = newest ? "newest" : "older", name = artist.name
        MusicDebugLog.log("radio", "\(kind) albums of \(name): \(songCount) songs from \(albumCount) albums")
        return out
    }

    /// The provider's own "more like this" for one song (the song's own provider answers).
    func recommendations(from t: MusicTrack, limit: Int, startRank: Int) async -> [RadioCandidate] {
        guard let p = hub.registry.metadataProvider(id: t.providerID),
              let more = try? await p.recommendations(seedTrackIDs: [t.id], limit: limit) else { return [] }
        return more.enumerated().map { RadioCandidate(track: $1, source: .provider, rank: startRank + $0, reason: MusicAutoplayReason(.radio, t.title)) }
    }

    /// The graph recommender (when the hub has one) around one song.
    func graph(around seed: MusicTrack, want: Int) async -> [RadioCandidate] {
        guard let g = hub.player.autoplayGraphSource else { return [] }
        var req = MusicAutoplayRequest(seed: seed)
        req.want = want
        return await g.candidates(for: req).map { RadioCandidate(track: $0.track, source: .graph, rank: $0.rank, reason: $0.reason) }
    }

    /// The person's own library around one song (works offline).
    func local(around seed: MusicTrack, want: Int) async -> [RadioCandidate] {
        let pool = Array((hub.library.liked + hub.library.recent).prefix(400))
        var req = MusicAutoplayRequest(seed: seed)
        req.want = want
        return await MusicLocalAffinitySource(library: { pool }).candidates(for: req)
            .map { RadioCandidate(track: $0.track, source: .local, rank: $0.rank, reason: $0.reason) }
    }
}
