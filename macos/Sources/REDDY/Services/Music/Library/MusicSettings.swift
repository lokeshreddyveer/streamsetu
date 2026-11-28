import Foundation

// Music settings and the small value types the library stores. Every decoder uses decodeIfPresent with a default,
// so a file written by an older or newer build never fails to load and never drops a field it does not know.

enum MusicQuality: String, Codable, CaseIterable, Sendable, Comparable {
    case low, medium, high, lossless

    private var rank: Int {
        switch self { case .low: 0; case .medium: 1; case .high: 2; case .lossless: 3 }
    }
    static func < (a: MusicQuality, b: MusicQuality) -> Bool { a.rank < b.rank }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicQuality(rawValue: raw) ?? .high
    }

    var title: String {
        switch self { case .low: "Low"; case .medium: "Medium"; case .high: "High"; case .lossless: "Lossless" }
    }
}

struct MusicSettings: Codable, Equatable, Sendable {
    var consentDone: Bool = false
    var audioQuality: MusicQuality = .high
    var skipNonMusicSegments: Bool = false
    /// On by default: tracks are brought to a common loudness (boost capped at +3 dB with a limiter).
    var normalizeVolume: Bool = true
    var crossfadeSeconds: Double = 0
    var scrobbleEnabled: Bool = false
    var downloadsDirectoryBookmark: Data? = nil
    var preferLyricsSynced: Bool = false
    var countryCode: String = MusicSettings.defaultCountry
    /// When the queue is about to end, quietly add similar tracks so the music keeps going. On by default; the Autoplay switch turns it off.
    var endlessPlayback: Bool = true
    /// Write title, artist, album and artwork into downloaded files.
    var tagDownloads: Bool = true
    /// Keep played audio on disk (least recently used goes first) so repeats start instantly and work offline.
    var cacheEnabled: Bool = false
    var cacheLimitMB: Int = 500
    /// Player preferences: queue behaviour, notifications, mini player, theatre mode, hotkeys.
    var player = MusicPlayerPrefs()
    /// Lyrics sources top to bottom, and which are switched on. All nine are on by default (an owner decision).
    var lyricsSourceOrder: [String] = MusicLyricsSources.defaultOrder
    var lyricsSourceEnabled: [String: Bool] = MusicLyricsSources.defaultEnabled
    /// Wait for a word-timed lyric from a lower source instead of settling for line-timed ones.
    var preferWordByWord: Bool = false
    var showTranslation: Bool = true
    var showRomanisation: Bool = false
    /// One timing shift for every song, in milliseconds, within plus or minus 5 s; positive shows the lyrics later.
    var lyricsOffsetMs: Int64 = 0

    static let minCacheMB = 50
    static let maxCacheMB = 20_000

    static var defaultCountry: String { Locale.current.region?.identifier ?? "US" }

    init(consentDone: Bool = false, audioQuality: MusicQuality = .high, skipNonMusicSegments: Bool = false,
         normalizeVolume: Bool = true, crossfadeSeconds: Double = 0, scrobbleEnabled: Bool = false,
         downloadsDirectoryBookmark: Data? = nil, preferLyricsSynced: Bool = false, countryCode: String = MusicSettings.defaultCountry,
         endlessPlayback: Bool = true, tagDownloads: Bool = true,
         cacheEnabled: Bool = false, cacheLimitMB: Int = 500,
         lyricsSourceOrder: [String] = MusicLyricsSources.defaultOrder, lyricsSourceEnabled: [String: Bool] = MusicLyricsSources.defaultEnabled,
         preferWordByWord: Bool = false, showTranslation: Bool = true, showRomanisation: Bool = false, lyricsOffsetMs: Int64 = 0) {
        self.consentDone = consentDone; self.audioQuality = audioQuality
        self.skipNonMusicSegments = skipNonMusicSegments; self.normalizeVolume = normalizeVolume
        self.crossfadeSeconds = crossfadeSeconds; self.scrobbleEnabled = scrobbleEnabled
        self.downloadsDirectoryBookmark = downloadsDirectoryBookmark
        self.preferLyricsSynced = preferLyricsSynced; self.countryCode = countryCode
        self.endlessPlayback = endlessPlayback; self.tagDownloads = tagDownloads
        self.cacheEnabled = cacheEnabled; self.cacheLimitMB = min(Self.maxCacheMB, max(Self.minCacheMB, cacheLimitMB))
        self.lyricsSourceOrder = lyricsSourceOrder; self.lyricsSourceEnabled = lyricsSourceEnabled
        self.preferWordByWord = preferWordByWord; self.showTranslation = showTranslation; self.showRomanisation = showRomanisation
        self.lyricsOffsetMs = MusicLyricsLookup.clampGlobalOffset(lyricsOffsetMs)
    }

    private enum CodingKeys: String, CodingKey {
        case consentDone, audioQuality, skipNonMusicSegments, normalizeVolume, crossfadeSeconds
        case scrobbleEnabled, downloadsDirectoryBookmark, preferLyricsSynced, countryCode
        case endlessPlayback, tagDownloads, cacheEnabled, cacheLimitMB, player
        case lyricsSourceOrder, lyricsSourceEnabled, preferWordByWord, showTranslation, showRomanisation, lyricsOffsetMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consentDone = try c.decodeIfPresent(Bool.self, forKey: .consentDone) ?? false
        audioQuality = try c.decodeIfPresent(MusicQuality.self, forKey: .audioQuality) ?? .high
        skipNonMusicSegments = try c.decodeIfPresent(Bool.self, forKey: .skipNonMusicSegments) ?? false
        normalizeVolume = try c.decodeIfPresent(Bool.self, forKey: .normalizeVolume) ?? true
        let fade = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? 0
        crossfadeSeconds = fade.isFinite ? max(0, fade) : 0
        scrobbleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scrobbleEnabled) ?? false
        downloadsDirectoryBookmark = try c.decodeIfPresent(Data.self, forKey: .downloadsDirectoryBookmark)
        preferLyricsSynced = try c.decodeIfPresent(Bool.self, forKey: .preferLyricsSynced) ?? false
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode) ?? MusicSettings.defaultCountry
        endlessPlayback = try c.decodeIfPresent(Bool.self, forKey: .endlessPlayback) ?? true
        tagDownloads = try c.decodeIfPresent(Bool.self, forKey: .tagDownloads) ?? true
        cacheEnabled = try c.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? false
        let limit = try c.decodeIfPresent(Int.self, forKey: .cacheLimitMB) ?? 500
        cacheLimitMB = min(MusicSettings.maxCacheMB, max(MusicSettings.minCacheMB, limit))
        player = try c.decodeIfPresent(MusicPlayerPrefs.self, forKey: .player) ?? MusicPlayerPrefs()
        lyricsSourceOrder = try c.decodeIfPresent([String].self, forKey: .lyricsSourceOrder) ?? MusicLyricsSources.defaultOrder
        lyricsSourceEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .lyricsSourceEnabled) ?? MusicLyricsSources.defaultEnabled
        preferWordByWord = try c.decodeIfPresent(Bool.self, forKey: .preferWordByWord) ?? false
        showTranslation = try c.decodeIfPresent(Bool.self, forKey: .showTranslation) ?? true
        showRomanisation = try c.decodeIfPresent(Bool.self, forKey: .showRomanisation) ?? false
        lyricsOffsetMs = MusicLyricsLookup.clampGlobalOffset(try c.decodeIfPresent(Int64.self, forKey: .lyricsOffsetMs) ?? 0)
    }
}

struct LocalPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The id a queue remembers this playlist by ("Playing from", "Back to"): the same text the playlist's own `MusicPlaylist.uid` carries.
    var sourceID: String { MusicStatsRules.localProviderID + ":" + id.uuidString }
    var name: String
    var tracks: [MusicTrack]
    var created: Date

    init(id: UUID = UUID(), name: String, tracks: [MusicTrack] = [], created: Date = Date()) {
        self.id = id; self.name = name; self.tracks = tracks; self.created = created
    }

    private enum CodingKeys: String, CodingKey { case id, name, tracks, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled playlist"
        tracks = try c.decodeIfPresent([MusicTrack].self, forKey: .tracks) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
    }
}

struct PlayRecord: Codable, Hashable, Sendable {
    var track: MusicTrack
    var at: Date
    var playedMs: Int64

    init(track: MusicTrack, at: Date = Date(), playedMs: Int64) {
        self.track = track; self.at = at; self.playedMs = playedMs
    }

    private enum CodingKeys: String, CodingKey { case track, at, playedMs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decode(MusicTrack.self, forKey: .track)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
        playedMs = try c.decodeIfPresent(Int64.self, forKey: .playedMs) ?? 0
    }
}
