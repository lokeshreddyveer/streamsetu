import Foundation

// The values Listen Now's engine works with. Everything here is plain data (Codable, Sendable) so the feed can be composed off the main thread,
// saved to disk and tested without a screen.

/// One thing Listen Now can show: a song, album, artist, playlist, a mix made from the person's plays, or a graph entity (a film).
/// Keys: `id` is stable for the view; `keys` is every spelling of the same thing (canonical provider id, ISRC, title+artist), so the same recording
/// from two providers is one item.
struct HomeItem: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case track, album, artist, playlist, mix, entity }

    var kind: Kind
    var id: String
    var title: String
    var subtitle: String = ""
    var thumbnails: [MusicThumbnail] = []
    /// The first artist, folded (empty when the item has none). Used for spacing only.
    var artistKey: String = ""
    /// Every key the same thing may be known by.
    var keys: [String] = []
    /// A taste bucket (the writing system of the title). Used for spread inside the engine; it is never shown.
    var bucket: String = ""
    var track: MusicTrack?
    var album: MusicAlbum?
    var artist: MusicArtist?
    var playlist: MusicPlaylist?
    var localPlaylistID: UUID?
    var mixTracks: [MusicTrack] = []
    var entityRaw: String?
    /// The artist an unfamiliar item sits next to ("Because you play X").
    var becauseOf: String?
    /// The artist a card was found for (a playlist that features them): every id the person's songs give that name. Hiding or blocking the artist takes the card with it.
    var seedArtists: [MusicArtistRef]?

    /// True when the song, the artist, the album's artist or the artist the card was found for is one the person never wants played.
    func isBlocked(track trackBlocked: (MusicTrack) -> Bool, artist artistBlocked: (MusicArtistRef) -> Bool) -> Bool {
        if let t = track { return trackBlocked(t) }
        if let a = artist { return artistBlocked(MusicArtistRef(id: a.id, name: a.name)) }
        if let al = album { return al.artists.contains(where: artistBlocked) }
        return seedArtists?.contains(where: artistBlocked) ?? false
    }
}

enum HomeKeys {
    static func fold(_ s: String) -> String { MusicText.normalize(s).trimmingCharacters(in: .whitespaces) }

    static func provider(_ uid: String) -> String { ExternalID.canonical(.provider, uid) }

    static func recording(_ t: MusicTrack) -> String {
        if let i = t.isrc?.trimmingCharacters(in: .whitespaces).uppercased(), !i.isEmpty { return "isrc:" + i }
        return "rec:" + fold(t.title) + "|" + fold(t.artists.first?.name ?? "")
    }

    static func album(_ a: MusicAlbum) -> String { "alb:" + fold(a.title) + "|" + fold(a.artists.first?.name ?? "") }

    static func firstArtist(_ t: MusicTrack) -> String { fold(t.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) })?.name ?? "") }

    static func bucket(_ t: MusicTrack) -> String { MusicLanguageDetector.language(of: t)?.rawValue ?? "" }
}

extension HomeItem {
    static func make(_ t: MusicTrack) -> HomeItem {
        HomeItem(kind: .track, id: "track:" + HomeKeys.provider(t.uid), title: t.title, subtitle: t.artistLine, thumbnails: t.thumbnails.isEmpty ? (t.album?.thumbnails ?? []) : t.thumbnails,
                 artistKey: HomeKeys.firstArtist(t), keys: [HomeKeys.provider(t.uid), HomeKeys.recording(t)], bucket: HomeKeys.bucket(t), track: t)
    }

    static func make(_ a: MusicAlbum) -> HomeItem {
        let text = ([a.title] + a.artists.map(\.name)).joined(separator: " ")
        return HomeItem(kind: .album, id: "album:" + HomeKeys.provider(a.uid), title: a.title, subtitle: a.artists.map(\.name).joined(separator: ", "), thumbnails: a.thumbnails,
                        artistKey: HomeKeys.fold(a.artists.first?.name ?? ""), keys: [HomeKeys.provider(a.uid), HomeKeys.album(a)],
                        bucket: MusicLanguageDetector.language(of: text)?.rawValue ?? "", album: a)
    }

    static func make(_ a: MusicArtist) -> HomeItem {
        HomeItem(kind: .artist, id: "artist:" + HomeKeys.provider(a.uid), title: a.name, thumbnails: a.thumbnails, artistKey: HomeKeys.fold(a.name),
                 keys: [HomeKeys.provider(a.uid), "art:" + HomeKeys.fold(a.name)], bucket: MusicLanguageDetector.language(of: a.name)?.rawValue ?? "", artist: a)
    }

    /// A source's playlist summary often reads "<channel> • 7.1M views": a channel and a view count are not a caption.
    static func playlistCaption(_ summary: String?) -> String {
        guard let s = summary?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        let n = s.lowercased()
        return n.contains("view") || s.contains("•") ? "" : s
    }

    static func make(_ p: MusicPlaylist) -> HomeItem {
        HomeItem(kind: .playlist, id: "playlist:" + HomeKeys.provider(p.uid), title: p.name, subtitle: Self.playlistCaption(p.summary), thumbnails: p.thumbnails, keys: [HomeKeys.provider(p.uid)], playlist: p)
    }

    /// A playlist of the person's own: it opens as a local playlist and plays its songs.
    static func make(_ l: LocalPlaylist, count: String) -> HomeItem {
        let art = l.tracks.first(where: { !$0.thumbnails.isEmpty })?.thumbnails ?? []
        return HomeItem(kind: .playlist, id: "local:" + l.id.uuidString, title: l.name, subtitle: count, thumbnails: art, keys: ["local:" + l.id.uuidString], localPlaylistID: l.id)
    }

    /// A mix: songs picked for this person. Tapping plays it.
    static func mix(id: String, title: String, subtitle: String, tracks: [MusicTrack]) -> HomeItem {
        let art = tracks.first(where: { !$0.thumbnails.isEmpty })?.thumbnails ?? tracks.compactMap { $0.album?.thumbnails }.first(where: { !$0.isEmpty }) ?? []
        return HomeItem(kind: .mix, id: "mix:" + id, title: title, subtitle: subtitle, thumbnails: art, keys: ["mix:" + id], mixTracks: tracks)
    }

    static func entity(raw: String, title: String, subtitle: String, imageURL: String?) -> HomeItem {
        let art = imageURL.flatMap { $0.hasPrefix("http") ? [MusicThumbnail(url: $0)] : nil } ?? []
        return HomeItem(kind: .entity, id: "entity:" + raw, title: title, subtitle: subtitle, thumbnails: art, keys: ["entity:" + raw], entityRaw: raw)
    }

    /// The same item, marked as unfamiliar and tied to the artist it sits next to.
    func adjacent(to seed: String) -> HomeItem { var c = self; c.becauseOf = seed; return c }
}

// MARK: - the feed

enum HomeSectionKind: String, Codable, Sendable {
    case madeForYou, newForYou, onRepeat, rediscover, artistsYouLove, because, graph, quickPicks, timeOfDay, albumsMostPlayed, yourDecade, yourPlaylists, languageMix, localMusic, genrePicks
}

struct HomeSection: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: HomeSectionKind
    var title: String
    /// One line that says why the shelf is there (derived from the person's own data), or nil.
    var reason: String?
    var items: [HomeItem]
}

struct HomeHero: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case randomFavourite, latestFromArtist, newRelease, rediscover, filmSoundtrack, playlist, radioIdea }
    var kind: Kind
    var item: HomeItem
    /// The recommendation reason, derived from the person's data ("Because you play X"). It is not a source caption.
    var reason: String
    var id: String { item.id }
}

struct HomeFeed: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case newUser, light, full, offline, gated }
    var seed: UInt64
    var composedAt: Date
    var mode: Mode
    var continueItems: [HomeItem] = []
    var hero: HomeHero?
    var sections: [HomeSection] = []
    var topTracks: [MusicTrack] = []
    /// Sections that were left out and why (for the debug log and the tests).
    var hidden: [String] = []
    /// The last few heroes, newest first (so the next feed never repeats the previous one, even after a relaunch).
    var heroHistory: [String] = []
    /// The app language the shelf titles were written in, and the sources that were on: a feed made under others is composed again.
    var language: String?
    var sources: [String]?

    static let empty = HomeFeed(seed: 0, composedAt: .distantPast, mode: .newUser)
}

// MARK: - what the engine reads

struct HomeFilmPick: Codable, Hashable, Sendable { var entityRaw: String; var title: String; var subtitle: String; var imageURL: String? }

struct HomeSignals: Sendable {
    var history: [PlayRecord] = []
    /// Every play, the recommendations reset not applied: read only to know what the person has already heard, never to weigh their taste.
    var allHistory: [PlayRecord] = []
    var liked: [MusicTrack] = []
    var followed: [MusicArtist] = []
    var playlists: [LocalPlaylist] = []
    var downloaded: Set<String> = []
    /// The newest album of artists the person follows or plays, of any age.
    var releases: [MusicAlbum] = []
    /// Unfamiliar items next to what the person plays (related artists and their songs).
    var adjacent: [HomeItem] = []
    var films: [HomeFilmPick] = []
    /// Songs for the genres the person listens to most ("More Pop"), found by searching the active source.
    var genreShelves: [HomeSection] = []
    /// Playlists that feature the artists the person plays most (found by searching the active source).
    var playlistsForYou: [HomeItem] = []
    /// A sample of songs from the music folders the person added.
    var localTracks: [MusicTrack] = []
    var current: MusicTrack?
}

struct HomeContext: Sendable {
    var now: Date = Date()
    var seed: UInt64 = 1
    var gated = false
    var offline = false
    /// The ids of the last heroes, newest first.
    var heroHistory: [String] = []
    var wording: MusicFillWording = .english
    var calendar: Calendar = .current
}
