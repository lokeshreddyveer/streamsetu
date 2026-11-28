import Foundation

// Canonical music models. Every provider (built in or plugin) maps its own data to these; nothing else in the app sees provider shapes.
// The shape follows the metadata / audio / lyrics / scrobble split used by plugin based music players: metadata says WHAT a track is,
// an audio source says WHERE to hear it, so the two can come from different providers.

struct MusicThumbnail: Codable, Hashable, Sendable { var url: String; var width: Int = 0; var height: Int = 0 }

extension Array where Element == MusicThumbnail {
    /// The smallest image at least `minSide` wide, else the largest one.
    func best(minSide: Int) -> String? {
        let sorted = self.sorted { $0.width < $1.width }
        return (sorted.first { $0.width >= minSide } ?? sorted.last)?.url
    }
}

struct MusicArtistRef: Codable, Hashable, Sendable, Identifiable {
    var id: String; var name: String; var thumbnails: [MusicThumbnail] = []; var externalURL: String? = nil
}

extension MusicArtistRef {
    /// True when this "artist" is the channel that uploaded a music video (a video-service channel id), not the person who made the music. One rule for every place that builds artists from plays or likes.
    func isUploaderChannel(of track: MusicTrack) -> Bool { track.isVideo == true && id.hasPrefix("UC") }
}

struct MusicAlbumRef: Codable, Hashable, Sendable, Identifiable {
    /// A source gave this album a real id. A song that only names its album in text arrives with the title as its id (or none): that is not a page to open, and opening it
    /// would ask the source for an album called by its own name.
    var hasPage: Bool { !id.isEmpty && id != title }
    var id: String; var title: String; var artists: [MusicArtistRef] = []; var thumbnails: [MusicThumbnail] = []
    var releaseDate: String? = nil; var totalTracks: Int? = nil; var albumType: String? = nil; var externalURL: String? = nil
}

struct MusicTrack: Codable, Hashable, Sendable, Identifiable {
    /// Provider scoped id. `uid` below is the globally unique key.
    var id: String
    /// Id of the provider that produced it (`MusicProvider.id`), so a track routes back to the right provider.
    var providerID: String
    var title: String
    var durationMs: Int64
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var artists: [MusicArtistRef]
    var album: MusicAlbumRef? = nil
    var thumbnails: [MusicThumbnail] = []
    var explicit: Bool = false
    var popularity: Int? = nil
    var isrc: String? = nil
    /// A short (≈30 s) preview clip, when a metadata source provides one (e.g. Spotify's public embed page). Not full audio — the full recording
    /// is still matched from an audio provider; this is only for an instant preview or as a cross-check signal.
    var previewURL: String? = nil
    var externalURL: String? = nil
    /// Set when the track already carries its own playable stream (Audius, JioSaavn): the matcher is skipped.
    var directStreams: [MusicStream]? = nil
    /// The service's own video id when it differs from `id` (YouTube Music). Optional so libraries saved before this field existed still load.
    var videoID: String? = nil
    /// True for podcast episodes. Optional for the same reason as `videoID`; read it as `isPodcast == true`.
    var isPodcast: Bool? = nil
    /// True when the service says the item is a music video rather than a song. Optional so saved libraries still load; read it as `isVideo == true`. Nil means unknown.
    var isVideo: Bool? = nil
    /// Account playlists: the handle of this row inside its playlist, needed to remove or move it. Optional so older saved libraries still load.
    var setVideoID: String? = nil
    /// The person's own like state on the service, when the row said so.
    var rating: MusicRating? = nil
    /// The audio twin of a music video (or the video twin of a song), when the service names one.
    var counterpartVideoID: String? = nil
    /// Add to or remove from the account library: the two feedback tokens the row carried.
    var libraryToggle: MusicLibraryToggle? = nil
    /// What the provider said about who made the song and what it is (see `MusicCreditBundle`). Optional so saved libraries still load.
    var creditBundle: MusicCreditBundle? = nil

    var uid: String { providerID + ":" + id }
    /// The artists as one line, without the filler a source writes when it does not know them (see `MusicArtistFiller`).
    var artistLine: String { artists.map(\.name).filter { !MusicArtistFiller.isFiller($0) }.joined(separator: ", ") }
    /// The artists as drawn on a screen: each in its own language and script when the graph knows that name. Identity, matching and scrobbling keep using `artistLine`.
    var displayArtistLine: String { MusicNativeNames.shared.artistLine(of: self) }
    var duration: TimeInterval { TimeInterval(durationMs) / 1000 }
}

/// A person's like state on a service that has accounts.
enum MusicRating: String, Codable, Hashable, Sendable { case like, dislike, none }

/// Whether a song is in the account library, with the one-shot tokens that flip it. A token goes stale, so a row is refetched when a write is refused.
struct MusicLibraryToggle: Codable, Hashable, Sendable {
    var inLibrary: Bool
    var addToken: String? = nil
    var removeToken: String? = nil
}

struct MusicArtist: Codable, Hashable, Sendable, Identifiable {
    var id: String; var providerID: String; var name: String; var thumbnails: [MusicThumbnail] = []
    var genres: [String] = []; var followers: Int? = nil; var bio: String? = nil; var externalURL: String? = nil
    var uid: String { providerID + ":" + id }
}

struct MusicAlbum: Codable, Hashable, Sendable, Identifiable {
    var id: String; var providerID: String; var title: String; var artists: [MusicArtistRef] = []; var thumbnails: [MusicThumbnail] = []
    var releaseDate: String? = nil; var totalTracks: Int? = nil; var albumType: String? = nil; var label: String? = nil; var externalURL: String? = nil
    /// What the provider said about who made the album and what it is (see `MusicCreditBundle`). Optional so saved libraries still load.
    var creditBundle: MusicCreditBundle? = nil
    var uid: String { providerID + ":" + id }
}

struct MusicPlaylist: Codable, Hashable, Sendable, Identifiable {
    var id: String; var providerID: String; var name: String; var summary: String? = nil; var owner: String? = nil
    var thumbnails: [MusicThumbnail] = []; var trackCount: Int? = nil; var isPublic: Bool = true; var externalURL: String? = nil
    var uid: String { providerID + ":" + id }
}

struct MusicUser: Codable, Hashable, Sendable, Identifiable {
    var id: String; var providerID: String; var username: String; var displayName: String? = nil; var thumbnails: [MusicThumbnail] = []; var externalURL: String? = nil
}

enum MusicSearchType: String, Codable, CaseIterable, Sendable { case track, artist, album, playlist, user }

enum MusicSearchResult: Hashable, Sendable {
    case track(MusicTrack), artist(MusicArtist), album(MusicAlbum), playlist(MusicPlaylist), user(MusicUser)
}

/// Pagination in the four shapes real services use. A provider returns the strategy for the NEXT page, nil when there is none.
enum MusicPagination: Codable, Hashable, Sendable {
    case offset(offset: Int, limit: Int), cursor(String?, limit: Int), page(Int, size: Int), continuation(String?)
    static let first = MusicPagination.offset(offset: 0, limit: 30)
}

struct MusicPage<T: Sendable>: Sendable {
    var items: [T]; var totalCount: Int?; var next: MusicPagination?
    init(items: [T], totalCount: Int? = nil, next: MusicPagination? = nil) { self.items = items; self.totalCount = totalCount; self.next = next }
    static var empty: MusicPage<T> { MusicPage(items: []) }
}

struct MusicBrowseGenre: Codable, Hashable, Sendable, Identifiable {
    var id: String; var name: String; var thumbnails: [MusicThumbnail] = []
    /// The English name a derived tile (a language, a decade, a mood) is searched and covered by, when its `name` is in the app's language. Older saved copies have none.
    var stableName: String? = nil
}

enum MusicBrowseItem: Hashable, Sendable { case playlist(MusicPlaylist), album(MusicAlbum), track(MusicTrack), artist(MusicArtist) }

struct MusicBrowseSection: Hashable, Sendable, Identifiable {
    var id: String; var title: String; var items: [MusicBrowseItem]
    /// What the list is really about (the chosen country's own chart, a worldwide one, or unstated). Additive: code that does not set it keeps compiling.
    var scope: MusicSectionScope = .other
}

struct MusicArtistOverview: Sendable { var artist: MusicArtist; var topTracks: [MusicTrack]; var albums: [MusicAlbum]; var related: [MusicArtist] }

// MARK: Audio

enum MusicStreamProtocol: String, Codable, Sendable { case progressive, hls, dash }

struct MusicStream: Codable, Hashable, Sendable {
    var url: String; var codec: String; var container: String; var proto: MusicStreamProtocol = .progressive
    /// kbps for lossy; nil for lossless.
    var bitrate: Int? = nil
    var sampleRate: Int? = nil
    var isLossless: Bool { bitrate == nil && sampleRate != nil }
    /// Headers the stream needs (Referer, User-Agent); applied by the player.
    var headers: [String: String] = [:]
    /// Streams from signed URLs stop working; the resolver re-resolves after this moment.
    var expiresAt: Date? = nil
    /// Hint that the url carries a picture as well as sound (a video format). Optional and additive; read it as `hasVideo == true`.
    var hasVideo: Bool? = nil
}

/// A candidate recording for a track, as an audio provider sees it. `confidence` is 0...1.
struct MusicAudioSource: Hashable, Sendable, Identifiable {
    var id: String; var providerID: String; var title: String; var artist: String?; var album: String?
    var durationMs: Int64?; var thumbnails: [MusicThumbnail] = []; var externalURL: String?; var confidence: Float
    /// Present when the provider already resolved playable streams.
    var streams: [MusicStream]? = nil
    var uid: String { providerID + ":" + id }
}

// MARK: Lyrics / scrobble

struct MusicLyricLine: Codable, Hashable, Sendable {
    var timeMs: Int64
    var text: String
    var endMs: Int64? = nil
    /// Word timings, lead and background voices in one list (background words carry `background`).
    var words: [MusicLyricWord]? = nil
    /// Singer id: "v1", "v2"... ; "v1000" means everyone together.
    var voice: String? = nil
    var translation: String? = nil
    var romanized: String? = nil
    var romanizedWords: [MusicLyricWord]? = nil
    /// The "( ... )" tail of a line-timed source, shown under the lead text. Word-timed lines mark their background words instead.
    var backgroundText: String? = nil

    init(timeMs: Int64, text: String, endMs: Int64? = nil, words: [MusicLyricWord]? = nil, voice: String? = nil,
         translation: String? = nil, romanized: String? = nil, romanizedWords: [MusicLyricWord]? = nil, backgroundText: String? = nil) {
        self.timeMs = timeMs; self.text = text; self.endMs = endMs; self.words = words; self.voice = voice
        self.translation = translation; self.romanized = romanized; self.romanizedWords = romanizedWords
        self.backgroundText = backgroundText
    }

    private enum CodingKeys: String, CodingKey { case timeMs, text, endMs, words, voice, translation, romanized, romanizedWords, backgroundText }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeMs = try c.decodeIfPresent(Int64.self, forKey: .timeMs) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        endMs = try c.decodeIfPresent(Int64.self, forKey: .endMs)
        words = try c.decodeIfPresent([MusicLyricWord].self, forKey: .words)
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        romanized = try c.decodeIfPresent(String.self, forKey: .romanized)
        romanizedWords = try c.decodeIfPresent([MusicLyricWord].self, forKey: .romanizedWords)
        backgroundText = try c.decodeIfPresent(String.self, forKey: .backgroundText)
    }

    /// Omits empty optionals so a plain line serialises exactly as it did before word timings existed.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timeMs, forKey: .timeMs)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(endMs, forKey: .endMs)
        if let words, !words.isEmpty { try c.encode(words, forKey: .words) }
        try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(translation, forKey: .translation)
        try c.encodeIfPresent(romanized, forKey: .romanized)
        if let romanizedWords, !romanizedWords.isEmpty { try c.encode(romanizedWords, forKey: .romanizedWords) }
        if let backgroundText, !backgroundText.isEmpty { try c.encode(backgroundText, forKey: .backgroundText) }
    }
}

struct MusicLyrics: Codable, Hashable, Sendable {
    var synced: [MusicLyricLine]?
    var plain: String?
    var sourceName: String = ""
    /// Id of the provider that answered.
    var providerID: String = ""
    var instrumental: Bool = false
    /// Picked by hand or nudged: survives settings changes and re-walks.
    var pinned: Bool = false
    /// Per-song timing nudge in milliseconds; positive shows the lyrics later.
    var offsetMs: Int64 = 0
    var revision: Int? = nil
    var authors: [String] = []
    /// The provider a mirrored lyric came from.
    var via: String? = nil
    /// The video id the mirror files this lyric under.
    var communityID: String? = nil
    /// What each singer id stands for ("person", "group", "other") when the source declares it; used by the duet layout.
    var voiceTypes: [String: String] = [:]

    init(synced: [MusicLyricLine]? = nil, plain: String? = nil, sourceName: String = "", providerID: String = "", instrumental: Bool = false,
         pinned: Bool = false, offsetMs: Int64 = 0, revision: Int? = nil, authors: [String] = [], via: String? = nil, communityID: String? = nil,
         voiceTypes: [String: String] = [:]) {
        self.synced = synced; self.plain = plain; self.sourceName = sourceName; self.providerID = providerID
        self.instrumental = instrumental; self.pinned = pinned; self.offsetMs = offsetMs; self.revision = revision
        self.authors = authors; self.via = via; self.communityID = communityID; self.voiceTypes = voiceTypes
    }

    private enum CodingKeys: String, CodingKey {
        case synced, plain, sourceName, providerID, instrumental, pinned, offsetMs, revision, authors, via, communityID, voiceTypes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        synced = try c.decodeIfPresent([MusicLyricLine].self, forKey: .synced)
        plain = try c.decodeIfPresent(String.self, forKey: .plain)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? ""
        instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        offsetMs = try c.decodeIfPresent(Int64.self, forKey: .offsetMs) ?? 0
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        via = try c.decodeIfPresent(String.self, forKey: .via)
        communityID = try c.decodeIfPresent(String.self, forKey: .communityID)
        voiceTypes = try c.decodeIfPresent([String: String].self, forKey: .voiceTypes) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(synced, forKey: .synced)
        try c.encodeIfPresent(plain, forKey: .plain)
        try c.encode(sourceName, forKey: .sourceName)
        if !providerID.isEmpty { try c.encode(providerID, forKey: .providerID) }
        if instrumental { try c.encode(true, forKey: .instrumental) }
        if pinned { try c.encode(true, forKey: .pinned) }
        if offsetMs != 0 { try c.encode(offsetMs, forKey: .offsetMs) }
        try c.encodeIfPresent(revision, forKey: .revision)
        if !authors.isEmpty { try c.encode(authors, forKey: .authors) }
        try c.encodeIfPresent(via, forKey: .via)
        try c.encodeIfPresent(communityID, forKey: .communityID)
        if !voiceTypes.isEmpty { try c.encode(voiceTypes, forKey: .voiceTypes) }
    }

    /// An instrumental verdict counts as an answer; it has nothing to show but it is not "no lyrics".
    var isEmpty: Bool { !instrumental && (synced?.isEmpty ?? true) && (plain?.isEmpty ?? true) }
}

struct MusicScrobble: Codable, Hashable, Sendable {
    var timestamp: Date; var track: MusicTrack; var playedMs: Int64
}

// MARK: Errors

enum MusicError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String)          // the provider does not offer this capability
    case notSignedIn(String)          // provider id
    case notFound
    case network(String)
    case noPlayableSource(String)     // track title
    case rateLimited(retryAfter: TimeInterval?)
    case plugin(String)
    case cancelled
    /// A host answered 401 or 403 to a request that carried no account. Not a sign-in problem: the caller moves on to the next source.
    case refused(String)              // host
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): "Not supported: \(s)"
        case .notSignedIn(let p): "Sign in to \(p) first."
        case .notFound: "Nothing found."
        case .network(let s): "Network problem: \(s)"
        case .noPlayableSource(let t): "No playable source found for \(t)."
        case .rateLimited: "The service is busy. Try again in a moment."
        case .plugin(let s): "Plugin error: \(s)"
        case .cancelled: "Cancelled."
        case .refused: "That source is not available right now."
        }
    }
}


/// The names a source writes when it does not know the artist. They are not artists: nothing shows them as one.
/// "Various Artists" is not in this list because it is a real credit.
enum MusicArtistFiller {
    static func isFiller(_ name: String) -> Bool { ["unknown artist", "unknown", "n/a", ""].contains(MusicText.normalize(name)) }
}
