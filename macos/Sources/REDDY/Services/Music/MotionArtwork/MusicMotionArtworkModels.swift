import Foundation

/// What is asked of a motion artwork source: the playing song and, when known, the ids Apple's catalogue already uses.
struct MusicMotionQuery: Sendable, Hashable {
    var title: String
    var artists: [String]
    var album: String?
    var isrc: String?
    /// The numeric catalogue id of the album when the track came from the iTunes source (iTunes and Apple Music share album ids).
    var catalogAlbumID: String?
    var storefront: String

    init(title: String, artists: [String], album: String? = nil, isrc: String? = nil, catalogAlbumID: String? = nil, storefront: String = "us") {
        self.title = title; self.artists = artists; self.album = album; self.isrc = isrc; self.catalogAlbumID = catalogAlbumID
        self.storefront = Self.cleanStorefront(storefront)
    }

    init(track: MusicTrack, storefront: String = "us") {
        let album = track.album?.title.trimmingCharacters(in: .whitespaces)
        self.init(title: track.title, artists: track.artists.map(\.name), album: (album?.isEmpty ?? true) ? nil : album,
                  isrc: track.isrc, catalogAlbumID: Self.albumID(of: track), storefront: storefront)
    }

    static func cleanStorefront(_ raw: String) -> String {
        let s = raw.lowercased().filter { $0.isLetter }
        return s.count == 2 ? s : "us"
    }

    /// Apple album ids are plain numbers. They are only trusted when the track says it came from the iTunes catalogue or links to Apple's own pages.
    static func albumID(of track: MusicTrack) -> String? {
        guard let album = track.album else { return nil }
        if track.providerID == "itunes", !album.id.isEmpty, album.id.allSatisfy(\.isNumber) { return album.id }
        if let s = album.externalURL, let u = URL(string: s), let host = u.host?.lowercased(),
           host == "music.apple.com" || host == "itunes.apple.com" {
            return u.pathComponents.last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        }
        return nil
    }

    /// Clips hang off albums, so every song of an album shares one answer. A song with no album is asked on its own.
    var cacheKey: String {
        if let id = catalogAlbumID { return "apple-album|\(id)" }
        let who = MusicText.normalize(artists.joined(separator: " "))
        if let album, !MusicText.normalize(album).isEmpty { return "album|\(MusicText.normalize(album))|\(who)" }
        return "song|\(MusicText.normalize(title))|\(who)"
    }
    var knowsAlbum: Bool { catalogAlbumID != nil || !(album ?? "").isEmpty }
}

/// A looping clip a source found. `masterURL` is the clip's playlist (or the file itself).
struct MusicMotionClip: Codable, Hashable, Sendable {
    var masterURL: URL
    /// A second rendition tried once when the first will not play.
    var fallbackURL: URL?
    /// The tall rendition, for a full-screen phone player.
    var portraitURL: URL?
    var title: String?
    var artist: String?
    var album: String?
    var source: String
}

/// A place that can hold a looping clip for an album. More can be added beside the Apple one.
protocol MusicMotionArtworkProvider: Sendable {
    var info: MusicProviderInfo { get }
    func clip(for query: MusicMotionQuery) async throws -> MusicMotionClip?
}

/// Every answer is re-checked against the song that is playing: a free text search will happily answer with another album's clip.
enum MusicMotionMatch {
    static let artistSeparators = [",", "&", " x ", "×", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "]

    static func artistList(_ names: [String]) -> [String] {
        var out: [String] = []
        for name in names {
            var parts = [name.lowercased()]
            for sep in artistSeparators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
            for p in parts { let n = MusicText.normalize(p); if !n.isEmpty, !out.contains(n) { out.append(n) } }
        }
        return out
    }

    /// At least one wanted artist is credited (as a whole name or inside one). An album is credited to its lead names, and a film album to its
    /// composer, so asking for every singer of one song would refuse the right clip.
    static func credits(_ credited: String, include wanted: [String]) -> Bool {
        let have = MusicText.normalize(credited)
        let list = artistList([credited])
        guard !have.isEmpty else { return false }
        let want = artistList(wanted)
        guard !want.isEmpty else { return false }
        return want.contains { w in list.contains(w) || have.contains(w) }
    }

    /// Album names are equal when both are known, and not required when either side does not know.
    static func albumAgrees(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !MusicText.normalize(a).isEmpty, !MusicText.normalize(b).isEmpty else { return true }
        let x = MusicText.normalize(a), y = MusicText.normalize(b)
        return x == y || x.hasPrefix(y + " ") || y.hasPrefix(x + " ")
    }

    static func matches(_ clip: MusicMotionClip, query: MusicMotionQuery) -> Bool {
        if let artist = clip.artist, !credits(artist, include: query.artists) { return false }
        return albumAgrees(clip.album, query.album)
    }
}

/// A short, fixed-size memory of answers: 64 entries, the longest unused leaves first, and "nothing found" is remembered for six hours.
struct MusicMotionAnswerCache: Sendable {
    struct Entry: Sendable { var clip: MusicMotionClip?; var at: Date; var provisional: Bool }
    static let capacity = 64
    static let missLifetime: TimeInterval = 6 * 3600

    private(set) var order: [String] = []
    private var entries: [String: Entry] = [:]
    var capacity = MusicMotionAnswerCache.capacity
    var missLifetime = MusicMotionAnswerCache.missLifetime

    var count: Int { entries.count }

    enum Lookup: Equatable { case unknown, hit(MusicMotionClip), miss }

    /// A miss recorded before the album was known is asked again once the album shows up.
    mutating func lookup(_ key: String, now: Date, knowsAlbum: Bool) -> Lookup {
        guard let e = entries[key] else { return .unknown }
        if let clip = e.clip { touch(key); return .hit(clip) }
        if now.timeIntervalSince(e.at) >= missLifetime { remove(key); return .unknown }
        if e.provisional && knowsAlbum { remove(key); return .unknown }
        touch(key)
        return .miss
    }

    mutating func store(_ clip: MusicMotionClip?, key: String, now: Date, knowsAlbum: Bool) {
        entries[key] = Entry(clip: clip, at: now, provisional: clip == nil && !knowsAlbum)
        touch(key)
        while order.count > capacity, let oldest = order.first { remove(oldest) }
    }

    mutating func clear() { order.removeAll(); entries.removeAll() }

    private mutating func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private mutating func remove(_ key: String) { order.removeAll { $0 == key }; entries[key] = nil }
}
