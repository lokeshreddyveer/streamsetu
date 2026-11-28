import Foundation

/// A playable copy of a song on an audio source, as found by the matcher.
struct MusicCanonicalTwin: Codable, Hashable, Sendable {
    var providerID: String
    var sourceID: String
    var title: String
    var artist: String?
    var album: String?
    var durationMs: Int64?
    var externalURL: String?
    var thumbnails: [MusicThumbnail] = []
    /// 0...1, the twin score that got it accepted.
    var score: Float
    /// How far its running time is from the catalogue's, in milliseconds (nil when either is unknown).
    var deltaMs: Int64?
    var hasStreams: Bool = false

    var uid: String { providerID + ":" + sourceID }
}

/// One song as the catalogue knows it, with the places it was seen and the playable copies found for it. Stored on disk for 30 days.
struct MusicCanonicalTrack: Codable, Hashable, Sendable, Identifiable {
    var key: String
    var title: String
    var artists: [String]
    var album: String?
    /// The film, series or album a title was released with ("Pushpa"), when the catalogue said so.
    var film: String?
    var year: Int?
    var durationMs: Int64
    var isrc: String?
    var language: String?
    var coverURL: String?
    /// Sorted version tags of the catalogue title (live, remix...); empty means the studio version.
    var versionTags: [String] = []
    var explicit: Bool = false
    /// Uids (`provider:id`) of the catalogue rows this song was seen on.
    var seenOn: [String] = []
    var twins: [MusicCanonicalTwin] = []
    var checkedAt: Date = Date(timeIntervalSince1970: 0)
    var updatedAt: Date = Date()

    var id: String { key }
    var isMatched: Bool { !twins.isEmpty }
    var primaryArtist: String { artists.first ?? "" }
    var artistLine: String { artists.joined(separator: ", ") }

    init(key: String, title: String, artists: [String], album: String? = nil, film: String? = nil, year: Int? = nil, durationMs: Int64 = 0,
         isrc: String? = nil, language: String? = nil, coverURL: String? = nil, versionTags: [String] = [], explicit: Bool = false,
         seenOn: [String] = [], twins: [MusicCanonicalTwin] = [], checkedAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date()) {
        self.key = key; self.title = title; self.artists = artists; self.album = album; self.film = film; self.year = year
        self.durationMs = durationMs; self.isrc = isrc; self.language = language; self.coverURL = coverURL; self.versionTags = versionTags
        self.explicit = explicit; self.seenOn = seenOn; self.twins = twins; self.checkedAt = checkedAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, artists, album, film, year, durationMs, isrc, language, coverURL, versionTags, explicit, seenOn, twins, checkedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        album = try c.decodeIfPresent(String.self, forKey: .album)
        film = try c.decodeIfPresent(String.self, forKey: .film)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        versionTags = try c.decodeIfPresent([String].self, forKey: .versionTags) ?? []
        explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        seenOn = try c.decodeIfPresent([String].self, forKey: .seenOn) ?? []
        twins = try c.decodeIfPresent([MusicCanonicalTwin].self, forKey: .twins) ?? []
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// The song as a wanted track for the matching rules: canonical words, runtime and version tags.
    func asTrack() -> MusicTrack {
        MusicTrack(id: key, providerID: "catalogue", title: title,
                   durationMs: durationMs, artists: artists.map { MusicArtistRef(id: $0, name: $0) },
                   album: (album ?? film).map { MusicAlbumRef(id: $0, title: $0) }, explicit: explicit, isrc: isrc)
    }
}

/// Turns a catalogue row into a canonical song. Pure.
enum MusicCatalogCanon {
    /// The identity key: phonetic key of the clean title and of the first artist, plus the version tags, so a remix is a different song.
    static func key(title: String, artists: [String], versionTags: [String]) -> String {
        let clean = MusicCandidateRules.cleanTitle(title)
        let t = MusicTransliterationKey.key(clean)
        let a = MusicTransliterationKey.key(artists.first ?? "")
        return ([t, a] + versionTags.sorted()).joined(separator: "|")
    }

    static func make(from track: MusicTrack, now: Date = Date()) -> MusicCanonicalTrack {
        let tags = MusicCandidateRules.versionTags(title: track.title, album: track.album?.title).sorted()
        let display = MusicCandidateRules.cleanTitle(track.title)
        let lyr = MusicLyricsQueryBuilder.cleanTitle(track.title)
        // The catalogue's own title is trusted: only brackets, film notes and credits go. (The lyrics cleaner would also cut a real trailing
        // word such as "Song" in "Love Song"; it is used here only to read the film and featured names.)
        let title = display
        var artists: [String] = []
        // A source may give one credit line for several singers ("A, B & C"); the canonical form lists them one by one.
        for a in track.artists {
            for n in MusicLyricsQueryBuilder.names(a.name) where !artists.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { artists.append(n) }
        }
        var film = lyr.film
        if film == nil, let a = track.album?.title.trimmingCharacters(in: .whitespaces), !a.isEmpty,
           MusicText.normalize(a) != MusicText.normalize(title) { film = MusicCandidateRules.cleanTitle(a) }
        let year = track.album?.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
        let cover = track.thumbnails.max { $0.width < $1.width }?.url ?? track.album?.thumbnails.max { $0.width < $1.width }?.url
        let lang = tags.first { $0.hasPrefix("lang:") }.map { String($0.dropFirst(5)) }
        return MusicCanonicalTrack(
            key: key(title: title, artists: artists, versionTags: tags), title: title, artists: artists, album: track.album?.title, film: film,
            year: year, durationMs: track.durationMs, isrc: MusicISRC.normalize(track.isrc), language: lang, coverURL: cover,
            versionTags: tags.filter { !$0.hasPrefix("lang:") }, explicit: track.explicit, seenOn: [track.uid], updatedAt: now)
    }
}
