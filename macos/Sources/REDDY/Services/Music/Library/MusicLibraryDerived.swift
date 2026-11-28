import Foundation

/// The Library's Albums and Artists, built the way Apple Music and YouTube Music build them: what the person saved or followed, plus the albums and artists of the
/// songs they liked and of their own files. Pure: no screen, no network.
enum MusicLibraryDerived {
    struct Albums: Equatable, Sendable {
        var albums: [MusicAlbum]
        /// uids of the albums that are there only because of songs (not saved by hand).
        var fromSongs: Set<String>
    }
    struct Artists: Equatable, Sendable {
        var artists: [MusicArtist]
        var fromSongs: Set<String>
    }

    /// Plays an album or artist needs before it joins the Library from listening alone.
    static let minPlays = 2

    private static func isUnknown(_ name: String) -> Bool {
        let n = MusicText.normalize(name)
        return n.isEmpty || n == "unknown artist" || n == "various artists" || n == "unknown album" || n == "unknown"
    }

    /// Saved albums first (in their saved order, which is newest first), then the albums of the songs, the one with the most songs first. An album the person saved is
    /// never repeated, and two copies of one album (same title and lead artist, whichever source) count once.
    static func albums(saved: [MusicAlbum], songs: [MusicTrack], played: [MusicTrack] = []) -> Albums {
        func key(_ title: String, _ artist: String?) -> String { MusicText.normalize(title) + "|" + MusicText.normalize(artist ?? "") }
        var seenUID = Set<String>(), seenKey = Set<String>()
        var out: [MusicAlbum] = []
        for a in saved where seenUID.insert(a.uid).inserted { seenKey.insert(key(a.title, a.artists.first?.name)); out.append(a) }
        struct Acc { var album: MusicAlbum; var count: Int; var first: Int }
        var acc: [String: Acc] = [:]
        for (i, t) in songs.enumerated() {
            guard let ref = t.album, !isUnknown(ref.title), !ref.id.isEmpty else { continue }
            let uid = t.providerID + ":" + ref.id
            if seenUID.contains(uid) { continue }
            let k = key(ref.title, ref.artists.first?.name ?? t.artists.first?.name)
            if seenKey.contains(k) { continue }
            if var a = acc[k] { a.count += 1; acc[k] = a }
            else { acc[k] = Acc(album: MusicAlbum(id: ref.id, providerID: t.providerID, title: ref.title, artists: ref.artists.isEmpty ? t.artists : ref.artists, thumbnails: ref.thumbnails.isEmpty ? t.thumbnails : ref.thumbnails), count: 1, first: i) }
        }
        var derived: [Acc] = []
        for a in acc.values { derived.append(a) }
        derived.sort { (x: Acc, y: Acc) -> Bool in x.count != y.count ? x.count > y.count : (x.first != y.first ? x.first < y.first : x.album.title < y.album.title) }
        var from = Set<String>()
        for a in derived { out.append(a.album); from.insert(a.album.uid) }
        // Albums the person plays: an album with at least `minPlays` counted plays that is not already above. The same rule for everyone, from their own plays only.
        var have = Set(out.map(\.uid)), haveKey = Set(out.map { key($0.title, $0.artists.first?.name) })
        var playedAcc: [String: Acc] = [:]
        for (i, t) in played.enumerated() {
            guard let ref = t.album, !isUnknown(ref.title), !ref.id.isEmpty else { continue }
            let k = key(ref.title, ref.artists.first?.name ?? t.artists.first?.name)
            if have.contains(t.providerID + ":" + ref.id) || haveKey.contains(k) { continue }
            if var a = playedAcc[k] { a.count += 1; playedAcc[k] = a }
            else { playedAcc[k] = Acc(album: MusicAlbum(id: ref.id, providerID: t.providerID, title: ref.title, artists: ref.artists.isEmpty ? t.artists : ref.artists, thumbnails: ref.thumbnails.isEmpty ? t.thumbnails : ref.thumbnails), count: 1, first: i) }
        }
        let more = playedAcc.values.filter { $0.count >= minPlays }.sorted { (x: Acc, y: Acc) -> Bool in x.count != y.count ? x.count > y.count : (x.first != y.first ? x.first < y.first : x.album.title < y.album.title) }
        for a in more where have.insert(a.album.uid).inserted && haveKey.insert(key(a.album.title, a.album.artists.first?.name)).inserted { out.append(a.album); from.insert(a.album.uid) }
        return Albums(albums: out, fromSongs: from)
    }

    /// Followed artists first, then the artists of the songs, the one with the most songs first. An artist who is followed is never repeated, even when a source
    /// spells or numbers them differently (matched on the name).
    static func artists(followed: [MusicArtist], songs: [MusicTrack], played: [MusicTrack] = []) -> Artists {
        var seenUID = Set<String>(), seenName = Set<String>()
        var out: [MusicArtist] = []
        for a in followed where seenUID.insert(a.uid).inserted { seenName.insert(MusicText.normalize(a.name)); out.append(a) }
        struct Acc { var artist: MusicArtist; var count: Int; var first: Int }
        var acc: [String: Acc] = [:]
        for (i, t) in songs.enumerated() {
            for ref in t.artists where !isUnknown(ref.name) && !ref.id.isEmpty && !ref.isUploaderChannel(of: t) {
                let name = MusicText.normalize(ref.name)
                if seenName.contains(name) { continue }
                if var a = acc[name] { a.count += 1; acc[name] = a }
                else { acc[name] = Acc(artist: MusicArtist(id: ref.id, providerID: t.providerID, name: ref.name, thumbnails: ref.thumbnails), count: 1, first: i) }
            }
        }
        var derived: [Acc] = []
        for a in acc.values { derived.append(a) }
        derived.sort { (x: Acc, y: Acc) -> Bool in x.count != y.count ? x.count > y.count : (x.first != y.first ? x.first < y.first : x.artist.name < y.artist.name) }
        var from = Set<String>()
        for a in derived { out.append(a.artist); from.insert(a.artist.uid) }
        // Artists the person plays: at least `minPlays` counted plays by an artist that is not already above (video-upload channels are not artists).
        var haveName = Set(out.map { MusicText.normalize($0.name) })
        var playedAcc: [String: Acc] = [:]
        for (i, t) in played.enumerated() {
            for ref in t.artists.prefix(2) where !isUnknown(ref.name) && !ref.id.isEmpty && !ref.isUploaderChannel(of: t) {
                let name = MusicText.normalize(ref.name)
                if haveName.contains(name) { continue }
                if var a = playedAcc[name] { a.count += 1; playedAcc[name] = a }
                else { playedAcc[name] = Acc(artist: MusicArtist(id: ref.id, providerID: t.providerID, name: ref.name, thumbnails: ref.thumbnails), count: 1, first: i) }
            }
        }
        let more = playedAcc.values.filter { $0.count >= minPlays }.sorted { (x: Acc, y: Acc) -> Bool in x.count != y.count ? x.count > y.count : (x.first != y.first ? x.first < y.first : x.artist.name < y.artist.name) }
        for a in more where haveName.insert(MusicText.normalize(a.artist.name)).inserted { out.append(a.artist); from.insert(a.artist.uid) }
        return Artists(artists: out, fromSongs: from)
    }
}
