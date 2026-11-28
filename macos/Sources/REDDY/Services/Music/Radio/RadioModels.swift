import Foundation

// What a station is: seeds, a mode, the person's thumbs and what it has played. Pure value types, all Codable with tolerant decoding so a file
// written by an older or newer build still loads (every field is optional on read). The service owns them; the screen only shows them.

enum RadioSeedKind: String, Codable, Sendable, CaseIterable { case song, artist, genre, language, mood }

/// One thing a station follows. A song or an artist carries the item itself so the station can start without asking again.
struct RadioSeed: Codable, Hashable, Identifiable, Sendable {
    var kind: RadioSeedKind
    /// Song: the track uid. Artist: the artist uid. Genre, language, mood: the normalised words.
    var key: String
    var name: String
    var track: MusicTrack?
    var artist: MusicArtist?
    /// A language seed's language (`MusicLanguage.rawValue`), so its songs can be told apart by script.
    var languageKey: String?
    /// For a genre or mood seed: the words searched.
    var query: String?
    var thumbs: [MusicThumbnail]

    var id: String { kind.rawValue + ":" + key }

    init(kind: RadioSeedKind, key: String, name: String, track: MusicTrack? = nil, artist: MusicArtist? = nil,
         languageKey: String? = nil, query: String? = nil, thumbs: [MusicThumbnail] = []) {
        self.kind = kind; self.key = key; self.name = name; self.track = track; self.artist = artist
        self.languageKey = languageKey; self.query = query; self.thumbs = thumbs
    }

    static func song(_ t: MusicTrack) -> RadioSeed {
        RadioSeed(kind: .song, key: t.uid, name: t.title, track: t, thumbs: t.thumbnails)
    }
    static func artist(_ a: MusicArtist) -> RadioSeed {
        RadioSeed(kind: .artist, key: a.uid, name: a.name, artist: a, thumbs: a.thumbnails)
    }
    static func genre(_ name: String) -> RadioSeed {
        RadioSeed(kind: .genre, key: MusicCategory.normalise(name), name: name, query: name + " music")
    }
    static func language(key: String, name: String) -> RadioSeed {
        RadioSeed(kind: .language, key: key, name: name, languageKey: key, query: MusicCategoryCatalogue.languageQuery(name))
    }
    static func mood(_ name: String) -> RadioSeed {
        RadioSeed(kind: .mood, key: MusicCategory.normalise(name), name: name, query: name)
    }

    private enum CodingKeys: String, CodingKey { case kind, key, name, track, artist, languageKey, query, thumbs }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(RadioSeedKind.self, forKey: .kind)) ?? .mood
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? MusicCategory.normalise(name)
        track = try? c.decodeIfPresent(MusicTrack.self, forKey: .track)
        artist = try? c.decodeIfPresent(MusicArtist.self, forKey: .artist)
        languageKey = try c.decodeIfPresent(String.self, forKey: .languageKey)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        thumbs = try c.decodeIfPresent([MusicThumbnail].self, forKey: .thumbs) ?? []
    }
}

/// How adventurous a station is. Its share of songs the person already knows.
enum RadioMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case familiar, mixed, discover
    /// Pandora-style modes: the station leans on release date (newly released), on songs few people play (deep cuts), on songs many people play (crowd favourites), or on its own artists only.
    case newlyReleased, deepCuts, crowdFaves, artistOnly
    var id: String { rawValue }
    /// Share of each batch taken from songs and artists the person already plays.
    var familiarShare: Double {
        switch self {
        case .familiar: 0.85
        case .mixed: 0.6
        case .discover: 0.2
        case .newlyReleased: 0.4
        case .deepCuts: 0.6
        case .crowdFaves: 0.6
        case .artistOnly: 0.9
        }
    }
    var title: String {
        switch self {
        case .familiar: Localized.string("Familiar")
        case .mixed: Localized.string("Mixed")
        case .discover: Localized.string("Discover")
        case .newlyReleased: Localized.string("Newly released")
        case .deepCuts: Localized.string("Deep cuts")
        case .crowdFaves: Localized.string("Crowd favourites")
        case .artistOnly: Localized.string("Artist only")
        }
    }
    var blurb: String {
        switch self {
        case .familiar: Localized.string("Mostly songs you know")
        case .mixed: Localized.string("Songs you know and new ones")
        case .discover: Localized.string("Mostly new songs")
        case .newlyReleased: Localized.string("The latest songs from the artists on this station")
        case .deepCuts: Localized.string("Lesser-known songs from the artists on this station")
        case .crowdFaves: Localized.string("The songs most people play on this station")
        case .artistOnly: Localized.string("Only the artists you started this station from")
        }
    }
}

enum RadioFeedbackKind: String, Codable, Sendable { case up, down, tired }

/// One thumb. It remembers who made the song so the taste it taught can be rebuilt from the list alone.
struct RadioFeedback: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var trackUID: String
    var trackID: String
    var providerID: String
    var title: String
    var artistKeys: [String]
    /// `MusicLanguage.rawValue` of the song when known.
    var language: String?
    var kind: RadioFeedbackKind
    var at: Date

    init(id: String = UUID().uuidString, track: MusicTrack, kind: RadioFeedbackKind, at: Date = Date()) {
        self.id = id; self.trackUID = track.uid; self.trackID = track.id; self.providerID = track.providerID
        self.title = track.title; self.artistKeys = MusicAutoplaySelector.artistKeys(track)
        self.language = MusicLanguageDetector.language(of: track)?.rawValue
        self.kind = kind; self.at = at
    }

    private enum CodingKeys: String, CodingKey { case id, trackUID, trackID, providerID, title, artistKeys, language, kind, at }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        trackUID = try c.decodeIfPresent(String.self, forKey: .trackUID) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        trackID = try c.decodeIfPresent(String.self, forKey: .trackID) ?? ""
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artistKeys = try c.decodeIfPresent([String].self, forKey: .artistKeys) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language)
        kind = (try? c.decode(RadioFeedbackKind.self, forKey: .kind)) ?? .up
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }
}

struct RadioStation: Codable, Hashable, Identifiable, Sendable {
    static let historyCap = 200
    static let coverCap = 4

    var id: String
    var name: String
    var seeds: [RadioSeed]
    var createdAt: Date
    var lastPlayedAt: Date?
    var mode: RadioMode
    var feedback: [RadioFeedback]
    /// Played song uids, oldest first, at most `historyCap`.
    var history: [String]
    /// Songs this station never plays again (thumbs down).
    var bannedUIDs: [String]
    /// Up to four pictures (one per artist) for the station's cover mosaic.
    var covers: [MusicThumbnail]
    /// Set for a station made from the person's history or a chart, so starting it again finds the same station instead of a copy.
    var derivedID: String?

    /// The songs the station will not repeat now.
    var playedSet: Set<String> { Set(history) }

    init(id: String = UUID().uuidString, name: String, seeds: [RadioSeed], createdAt: Date = Date(), lastPlayedAt: Date? = nil,
         mode: RadioMode = .mixed, feedback: [RadioFeedback] = [], history: [String] = [], bannedUIDs: [String] = [],
         covers: [MusicThumbnail] = [], derivedID: String? = nil) {
        self.id = id; self.name = name; self.seeds = seeds; self.createdAt = createdAt; self.lastPlayedAt = lastPlayedAt
        self.mode = mode; self.feedback = feedback; self.history = Array(history.suffix(Self.historyCap))
        self.bannedUIDs = bannedUIDs; self.covers = covers; self.derivedID = derivedID
    }

    /// Records a played song; the list never grows past `historyCap`. A song heard again moves to the end.
    mutating func recordPlayed(_ uid: String, at: Date = Date()) {
        history.removeAll { $0 == uid }
        history.append(uid)
        if history.count > Self.historyCap { history.removeFirst(history.count - Self.historyCap) }
        lastPlayedAt = at
    }

    mutating func ban(_ uid: String) { if !bannedUIDs.contains(uid) { bannedUIDs.append(uid) } }

    /// Remembers a cover for each of the first artists heard, up to `coverCap`.
    mutating func noteCover(_ t: MusicTrack) {
        guard covers.count < Self.coverCap, let thumb = t.thumbnails.last ?? t.thumbnails.first, !covers.contains(thumb) else { return }
        covers.append(thumb)
    }

    /// What the cover mosaic shows: the covers heard, else the seeds' own pictures.
    var mosaic: [[MusicThumbnail]] {
        let own = covers.map { [$0] }
        if own.count >= 2 { return own }
        let seedArt = seeds.compactMap { s in s.thumbs.isEmpty ? nil : s.thumbs }
        return own + seedArt.filter { !own.contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case id, name, seeds, createdAt, lastPlayedAt, mode, feedback, history, bannedUIDs, covers, derivedID }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        seeds = try c.decodeIfPresent([RadioSeed].self, forKey: .seeds) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? seeds.first?.name ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        mode = (try? c.decode(RadioMode.self, forKey: .mode)) ?? .mixed
        feedback = try c.decodeIfPresent([RadioFeedback].self, forKey: .feedback) ?? []
        history = Array((try c.decodeIfPresent([String].self, forKey: .history) ?? []).suffix(Self.historyCap))
        bannedUIDs = try c.decodeIfPresent([String].self, forKey: .bannedUIDs) ?? []
        covers = try c.decodeIfPresent([MusicThumbnail].self, forKey: .covers) ?? []
        derivedID = try c.decodeIfPresent(String.self, forKey: .derivedID)
    }
}

/// The whole saved file: the stations and the songs the person is tired of (song uid to the day they said so). Versioned; a newer or older file is
/// read field by field and tidied by `tidied`, never rejected.
struct RadioStoreFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let stationCap = 50

    var version = RadioStoreFile.currentVersion
    var stations: [RadioStation] = []
    var tired: [String: Date] = [:]

    init(stations: [RadioStation] = [], tired: [String: Date] = [:]) { self.stations = stations; self.tired = tired }

    private enum CodingKeys: String, CodingKey { case version, stations, tired }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        stations = try c.decodeIfPresent([RadioStation].self, forKey: .stations) ?? []
        tired = try c.decodeIfPresent([String: Date].self, forKey: .tired) ?? [:]
    }

    /// Duplicate ids removed, histories cut, expired tired bans dropped, the oldest-used stations dropped past `stationCap`, the version raised.
    func tidied(now: Date = Date()) -> RadioStoreFile {
        var seen = Set<String>()
        var list = stations.filter { seen.insert($0.id).inserted }.map { s -> RadioStation in
            var s = s
            if s.history.count > RadioStation.historyCap { s.history = Array(s.history.suffix(RadioStation.historyCap)) }
            if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.seeds.first?.name ?? Localized.string("Radio") }
            return s
        }
        if list.count > Self.stationCap {
            list.sort { ($0.lastPlayedAt ?? $0.createdAt) > ($1.lastPlayedAt ?? $1.createdAt) }
            list = Array(list.prefix(Self.stationCap))
        }
        var out = RadioStoreFile(stations: list, tired: RadioBans.pruned(tired, now: now))
        out.version = Self.currentVersion
        return out
    }

    static func decode(_ data: Data) -> RadioStoreFile? {
        guard let f = try? MusicJSONCoding.makeDecoder().decode(RadioStoreFile.self, from: data) else { return nil }
        return f.tidied()
    }
    func encoded() -> Data? { try? MusicJSONCoding.makeEncoder().encode(self) }
}
