import Foundation

// Playback sources of a song (item 18) and the playable row the page hands the player when the person taps Play (items 1 and 18).
// Pure and Foundation-only. Reading sources never starts playback: the page asks the matcher for a dry run (no stream is opened) and lists what it
// found with a provider badge, a quality line and whether the copy is verified; "Play from <source>" is an explicit tap on one of those rows.

/// One place the song can be played from.
struct MusicSongSource: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case providerRow, twin, candidate }
    enum Trust: String, Sendable { case verified, unverified }

    var providerID: String
    var providerName: String
    var sourceID: String
    var title: String
    var artist: String?
    var durationMs: Int64?
    var kind: Kind
    var trust: Trust
    /// 0...1, the matcher's own score for the copy (1 for the provider row the song came from).
    var score: Float
    /// "Lossless", "256 kbps" or nil when the provider did not say.
    var quality: String?
    var externalURL: String?
    var thumbnails: [MusicThumbnail]
    /// The one the person chose for this song earlier ("In use").
    var isChosen: Bool

    var id: String { providerID + ":" + sourceID }
}

enum MusicSongSources {
    /// A copy is verified when the matcher's twin score is high, or lower but with the running time within two seconds of the catalogue's.
    static let verifiedScore: Float = 0.85
    static let acceptedScore: Float = 0.62
    static let exactRuntimeMs: Int64 = 2_000

    static func trust(score: Float, deltaMs: Int64?) -> MusicSongSource.Trust {
        if score >= verifiedScore { return .verified }
        if score >= acceptedScore, let d = deltaMs, abs(d) <= exactRuntimeMs { return .verified }
        return .unverified
    }

    /// "Lossless", the best lossy bitrate, or nil.
    static func qualityLabel(streams: [MusicStream]?) -> String? {
        guard let streams, !streams.isEmpty else { return nil }
        if streams.contains(where: { $0.isLossless }) { return "Lossless" }
        guard let best = streams.compactMap(\.bitrate).max() else { return nil }
        return String(best) + " kbps"
    }

    static func source(twin t: MusicCanonicalTwin, providerName: String, chosen: String?) -> MusicSongSource {
        MusicSongSource(providerID: t.providerID, providerName: providerName, sourceID: t.sourceID, title: t.title, artist: t.artist, durationMs: t.durationMs,
                        kind: .twin, trust: trust(score: t.score, deltaMs: t.deltaMs), score: t.score, quality: nil,
                        externalURL: t.externalURL, thumbnails: t.thumbnails, isChosen: chosen == t.uid)
    }

    static func source(candidate c: MusicAudioSource, score: Float, providerName: String, chosen: String?) -> MusicSongSource {
        MusicSongSource(providerID: c.providerID, providerName: providerName, sourceID: c.id, title: c.title, artist: c.artist, durationMs: c.durationMs,
                        kind: .candidate, trust: score >= verifiedScore ? .verified : .unverified, score: score, quality: qualityLabel(streams: c.streams),
                        externalURL: c.externalURL, thumbnails: c.thumbnails, isChosen: chosen == c.uid)
    }

    /// The provider row the page was opened from, when that provider plays audio itself: it is the song's own row, so it counts as verified.
    static func ownRow(of t: MusicTrack, providerName: String, isAudioProvider: Bool, chosen: String?) -> MusicSongSource? {
        guard isAudioProvider else { return nil }
        return MusicSongSource(providerID: t.providerID, providerName: providerName, sourceID: t.id, title: t.title, artist: t.artists.first?.name,
                               durationMs: t.durationMs > 0 ? t.durationMs : nil, kind: .providerRow, trust: .verified, score: 1,
                               quality: qualityLabel(streams: t.directStreams), externalURL: t.externalURL, thumbnails: t.thumbnails, isChosen: chosen == t.uid)
    }

    /// The key a copy is merged under: the YouTube providers serve the same videos by the same id, so "YouTube Music" and "YouTube Music (basic)" are one copy, not two.
    static func copyKey(_ r: MusicSongSource) -> String {
        ExternalID.youTubeFamily.contains(r.providerID) ? "ytmusic:" + r.sourceID : r.id
    }

    /// Merges the rows: one per copy, the own row first, then verified before unverified, higher score first, then by provider name. Copies the matcher is not sure of
    /// (a different song with a similar name) are shown only when nothing verified was found and the person has not chosen one: a verified copy makes them noise.
    static func combine(_ rows: [MusicSongSource], limit: Int = 8) -> [MusicSongSource] {
        var best: [String: MusicSongSource] = [:]
        for r in rows {
            let k = copyKey(r)
            if let cur = best[k] {
                if rank(r) < rank(cur) || (rank(r) == rank(cur) && r.providerName.count < cur.providerName.count) { var m = r; m.isChosen = r.isChosen || cur.isChosen; best[k] = m } else if r.isChosen { best[k]?.isChosen = true }
            } else { best[k] = r }
        }
        var merged = Array(best.values)
        if merged.contains(where: { $0.trust == .verified }) { merged.removeAll { $0.trust == .unverified && !$0.isChosen } }
        return Array(merged.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.score != b.score { return a.score > b.score }
            if a.providerName != b.providerName { return a.providerName < b.providerName }
            return a.id < b.id
        }.prefix(limit))
    }

    private static func rank(_ s: MusicSongSource) -> Int {
        (s.kind == .providerRow ? 0 : 2) + (s.trust == .verified ? 0 : 1)
    }

    /// The row to give the player for "Play from <source>": that copy's identity with the page song's own words, running time, cover and credits.
    static func playable(from s: MusicSongSource, base: MusicTrack, youTubeFamily: Set<String> = ["youtube-music", "ytmusic", "youtube", "piped", "invidious"]) -> MusicTrack {
        var t = MusicTrack(id: s.sourceID, providerID: s.providerID, title: base.title, durationMs: base.durationMs > 0 ? base.durationMs : (s.durationMs ?? 0),
                           artists: base.artists, album: base.album, thumbnails: base.thumbnails.isEmpty ? s.thumbnails : base.thumbnails,
                           explicit: base.explicit, isrc: base.isrc)
        t.externalURL = s.externalURL ?? base.externalURL
        t.creditBundle = base.creditBundle
        if youTubeFamily.contains(s.providerID) { t.videoID = s.sourceID }
        return t
    }
}

/// The player row of a song page, built from what the graph holds about the recording: no network, so Play is available the moment the row is.
enum MusicSongPlayable {
    /// `videoID` of a YouTube Music song: the explicit external id, else the id of a `ytmusic:` provider alias when it has the shape of a video id.
    static func youTubeVideoID(_ ids: [ExternalID]) -> String? {
        if let v = ids.first(where: { $0.scheme == .ytVideo })?.value, !v.isEmpty { return v }
        for x in ids where x.scheme == .provider {
            guard let (p, id) = split(x.value), p == "ytmusic", isVideoID(id) else { continue }
            return id
        }
        return nil
    }

    static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_" }
    }

    /// "ytmusic:abc" into ("ytmusic", "abc"); nil without a colon or with an empty half.
    static func split(_ uid: String) -> (String, String)? {
        guard let i = uid.firstIndex(of: ":") else { return nil }
        let p = String(uid[..<i]), id = String(uid[uid.index(after: i)...])
        return p.isEmpty || id.isEmpty ? nil : (p, id)
    }

    /// The song as a row the player can start. `preferredProviders` orders the recording's provider aliases (audio providers first). Nil when the
    /// graph has no provider alias for the recording; then the page offers to find a playable copy instead.
    static func track(snapshot: MusicEntitySnapshot, externalIDs: [ExternalID], artists: [MusicArtistRef], album: MusicAlbumRef?,
                      preferredProviders: [String] = []) -> MusicTrack? {
        let aliases = externalIDs.filter { $0.scheme == .provider }.compactMap { x -> (String, String)? in split(x.value) }
        guard !aliases.isEmpty else { return nil }
        func rank(_ p: String) -> Int { preferredProviders.firstIndex(of: p) ?? preferredProviders.count }
        let pick = aliases.sorted { a, b in rank(a.0) != rank(b.0) ? rank(a.0) < rank(b.0) : (a.0 + ":" + a.1) < (b.0 + ":" + b.1) }[0]
        var t = MusicTrack(id: pick.1, providerID: pick.0, title: snapshot.name, durationMs: Int64(snapshot.durationMs ?? 0), artists: artists, album: album,
                           thumbnails: snapshot.imageRef.map { [MusicThumbnail(url: $0, width: 600, height: 600)] } ?? [],
                           explicit: snapshot.attrs["explicit"] == "1", isrc: externalIDs.first(where: { $0.scheme == .isrc })?.value)
        t.videoID = youTubeVideoID(externalIDs)
        return t
    }

    /// A row used only for its words (matching copies, looking up lyrics) when the graph has no provider alias for the recording. It is never played
    /// or saved: Play stays off until a source is picked from the list.
    static func searchBase(snapshot: MusicEntitySnapshot, artists: [MusicArtistRef], album: MusicAlbumRef?) -> MusicTrack {
        MusicTrack(id: snapshot.id.token, providerID: "graph", title: snapshot.name, durationMs: Int64(snapshot.durationMs ?? 0), artists: artists, album: album,
                   thumbnails: snapshot.imageRef.map { [MusicThumbnail(url: $0, width: 600, height: 600)] } ?? [], explicit: snapshot.attrs["explicit"] == "1")
    }

    static let searchBaseProviderID = "graph"

    /// Every provider uid the recording is known by (a local playlist holding any of them holds this song).
    static func uids(_ ids: [ExternalID]) -> Set<String> { Set(ids.filter { $0.scheme == .provider }.map(\.value)) }
}
