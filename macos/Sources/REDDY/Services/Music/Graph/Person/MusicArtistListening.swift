import Foundation

// Personal listening stats for one artist, from the play history on this Mac. Kept apart from the factual catalog: it never changes a credit or the order of a public list.
// A play counts by the same rule Home uses (`HomeTaste.counts`: at least half the song, or 30 seconds when the length is unknown).

/// Who the person is in the player's own terms: the provider artist the page found (when it has one) and the name.
struct MusicArtistIdentity: Equatable, Sendable {
    var providerID: String?
    var artistID: String?
    var name: String
}

struct MusicArtistListeningStats: Equatable, Sendable {
    struct TopSong: Equatable, Sendable, Identifiable { var title: String; var plays: Int; var id: String; var track: MusicTrack? = nil }
    /// Counted plays.
    var plays = 0
    /// Time heard across every matching record, counted or not.
    var listenedMs: Int64 = 0
    var first: Date?
    var last: Date?
    var top: [TopSong] = []
    /// Songs of the loaded catalog that have no counted play, in the catalog's order.
    var unplayed: [MusicPersonEntry] = []
    var hasData: Bool { plays > 0 }
}

enum MusicArtistListening {
    static func matches(_ t: MusicTrack, identity: MusicArtistIdentity) -> Bool {
        let name = HomeKeys.fold(identity.name)
        return t.artists.contains { ref in
            // On the artist's own provider the id decides (two artists can share a name); elsewhere only the name is known.
            if let p = identity.providerID, let a = identity.artistID, !a.isEmpty, t.providerID == p, !ref.id.isEmpty { return ref.id == a }
            return !name.isEmpty && HomeKeys.fold(ref.name) == name
        }
    }

    static func compute(history: [PlayRecord], identity: MusicArtistIdentity, songs: [MusicPersonEntry], uids: [MusicEntityID: [String]] = [:], topLimit: Int = 10) -> MusicArtistListeningStats {
        var s = MusicArtistListeningStats()
        var byTitle: [String: (title: String, plays: Int, track: MusicTrack)] = [:]
        var playedUIDs = Set<String>()
        for r in history where !(r.track.isPodcast ?? false) && matches(r.track, identity: identity) {
            s.listenedMs += max(0, r.playedMs)
            guard HomeTaste.counts(r) else { continue }
            s.plays += 1
            if s.first == nil || r.at < s.first! { s.first = r.at }
            if s.last == nil || r.at > s.last! { s.last = r.at }
            playedUIDs.insert(r.track.uid)
            let key = HomeKeys.fold(r.track.title)
            var e = byTitle[key] ?? (title: r.track.title, plays: 0, track: r.track)
            e.plays += 1
            byTitle[key] = e
        }
        s.top = byTitle.map { MusicArtistListeningStats.TopSong(title: $0.value.title, plays: $0.value.plays, id: $0.key, track: $0.value.track) }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.title < $1.title }.prefix(topLimit).map { $0 }
        // A recording with provider ids is played when one of them was; the title decides only for a recording with no ids or with no stated version.
        s.unplayed = songs.filter { e in
            if let u = uids[e.id], !u.isEmpty {
                if u.contains(where: { playedUIDs.contains($0) }) { return false }
                if !MusicArtistPersonal.titleMayStandIn(e) { return true }
            }
            return byTitle[HomeKeys.fold(e.name)] == nil
        }
        return s
    }
}
