import Foundation

// Radio stations: what a station is, how the Radio page builds them, and the recently played stations kept on this device.
// A station is an endless mix started from a seed (a song, an artist, a genre, a language or a country's charts). Stations built from the
// person's own plays, likes and follows exist only when there is such history; regional, language and genre stations need none. Nothing is invented.

// MARK: - Station

struct MusicStation: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case artist, genre, language, region, track, mood, mix }

    /// What the existing radio start needs. A song and an artist start as they always did; a search or a chart is first turned into a song.
    enum Seed: Hashable, Codable, Sendable {
        case track(MusicTrack)
        case artist(MusicArtist)
        case search(query: String, languageKey: String?)
        case chart(region: String, languageKey: String?)
    }

    /// The name and kind the genre cover service knows a tile by, so a genre or language station shares the cover Explore already fetched.
    struct Art: Hashable, Codable, Sendable { var name: String; var kind: MusicCategoryKind }

    var id: String
    var kind: Kind
    var title: String
    /// One line saying what the station plays.
    var subtitle: String
    /// The label on the artwork: "Artist radio", "Telugu radio", "Song radio".
    var badge: String
    var seed: Seed
    var thumbs: [MusicThumbnail] = []
    var art: Art?

    var category: MusicCategory? { art.map { MusicCategory(name: $0.name, kind: $0.kind, target: .search($0.name)) } }
    /// The words a station is named by when the player says what it is playing from.
    var seedName: String {
        switch seed {
        case .track(let t): t.title
        case .artist(let a): a.name
        case .search(let q, _): q
        case .chart(let r, _): MusicDiscoveryRegion.name(r)
        }
    }
}

// MARK: - Builder

enum MusicRadioStations {
    static let perSection = 12
    static let maxArtists = 8
    static let maxSongs = 6
    static let maxFeaturedLanguages = 3

    struct Input {
        var playing: MusicTrack?
        var liked: [MusicTrack] = []
        var history: [PlayRecord] = []
        var followed: [MusicArtist] = []
        var region: String
        var genres: [MusicCategory] = []
        var recent: [MusicStation] = []
    }

    struct Sections: Equatable {
        var featured: [MusicStation] = []
        var yours: [MusicStation] = []
        var genres: [MusicStation] = []
        var languages: [MusicStation] = []
        var regional: [MusicStation] = []
        var recent: [MusicStation] = []
        /// True when the person's own plays, likes or follows produced at least one station.
        var hasYours: Bool { !yours.isEmpty }
        var all: [MusicStation] { featured + yours + genres + languages + regional + recent }
    }

    struct ArtistStat: Equatable {
        var key: String
        var name: String
        var thumbs: [MusicThumbnail]
        var plays: Int
        var liked: Int
        var seed: MusicTrack
        var score: Int { plays + liked * 3 }
    }

    static func key(_ name: String) -> String { MusicCategory.normalise(name) }

    /// The artists in the person's history and liked songs, best first. The seed is the artist's most recent song.
    static func artistStats(history: [PlayRecord], liked: [MusicTrack]) -> [ArtistStat] {
        var stats: [String: ArtistStat] = [:]
        var order: [String] = []
        func touch(_ t: MusicTrack, played: Bool) {
            guard let a = t.artists.first, !a.name.isEmpty else { return }
            let k = key(a.name)
            if stats[k] == nil { stats[k] = ArtistStat(key: k, name: a.name, thumbs: t.thumbnails, plays: 0, liked: 0, seed: t); order.append(k) }
            if played { stats[k]!.plays += 1 } else { stats[k]!.liked += 1 }
        }
        for r in history.sorted(by: { $0.at > $1.at }) { touch(r.track, played: true) }
        for t in liked { touch(t, played: false) }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return stats.values.sorted { $0.score != $1.score ? $0.score > $1.score : rank[$0.key]! < rank[$1.key]! }
    }

    /// Languages the person's own songs are in (non-Latin scripts seen at least twice), most played first.
    static func historyLanguages(liked: [MusicTrack], history: [PlayRecord]) -> [MusicLanguage] {
        MusicLanguageProfile.build(from: liked + history.map(\.track)).found(minCount: 2)
    }

    // Single stations

    static func songStation(_ t: MusicTrack, subtitle: String? = nil) -> MusicStation {
        MusicStation(id: "track:" + t.uid, kind: .track, title: Localized.string("Radio from %@", t.title),
                     subtitle: subtitle ?? t.artistLine, badge: Localized.string("Song radio"), seed: .track(t), thumbs: t.thumbnails)
    }

    static func artistStation(name: String, relation: String, thumbs: [MusicThumbnail], seed: MusicStation.Seed) -> MusicStation {
        MusicStation(id: "artist:" + key(name), kind: .artist, title: Localized.string("%@ Radio", name), subtitle: relation,
                     badge: Localized.string("Artist radio"), seed: seed, thumbs: thumbs)
    }

    static func genreStation(_ c: MusicCategory) -> MusicStation {
        MusicStation(id: "genre:" + key(c.name), kind: .genre, title: Localized.string("%@ Radio", c.name),
                     subtitle: Localized.string("Endless %@ mix", c.name), badge: Localized.string("Genre radio"),
                     seed: .search(query: c.name + " music", languageKey: nil), art: .init(name: c.name, kind: .genre))
    }

    /// `key` is the language key of `MusicCategoryCatalogue.languages`; `name` is the translated name.
    static func languageStation(key: String, name: String) -> MusicStation {
        MusicStation(id: "language:" + key, kind: .language, title: Localized.string("%@ Radio", name),
                     subtitle: Localized.string("Songs in %@, then more like them", name), badge: Localized.string("%@ radio", name),
                     seed: .search(query: MusicCategoryCatalogue.languageQuery(englishName(key)), languageKey: key), art: .init(name: name, kind: .language))
    }

    static func regionStation(_ code: String) -> MusicStation {
        let name = MusicDiscoveryRegion.name(code)
        return MusicStation(id: "region:" + code, kind: .region, title: Localized.string("Top %@ Radio", name),
                            subtitle: Localized.string("Today's top songs in %@, then more", name), badge: Localized.string("Regional radio"),
                            seed: .chart(region: code, languageKey: nil), art: .init(name: name, kind: .language))
    }

    /// A language's charts in a country, only offered where a source really lists them (India's per-language lists).
    static func chartStation(region code: String, language: MusicLanguage) -> MusicStation {
        MusicStation(id: "chart:" + code + ":" + language.rawValue, kind: .region, title: Localized.string("Top %@ Radio", language.displayName),
                     subtitle: Localized.string("Chart songs in %@", MusicDiscoveryRegion.name(code)), badge: Localized.string("Regional radio"),
                     seed: .chart(region: code, languageKey: language.rawValue), art: .init(name: language.displayName, kind: .language))
    }

    static func englishName(_ key: String) -> String {
        MusicCategoryCatalogue.languages.first { $0.key == key }?.name ?? key.capitalized
    }

    // Sections

    static func build(_ input: Input, limit: Int = perSection) -> Sections {
        var s = Sections()
        let stats = artistStats(history: input.history, liked: input.liked)
        let historyLangs = historyLanguages(liked: input.liked, history: input.history)

        // Yours: the song playing, the artists played, liked or followed, and a few songs. All from the person's own data.
        var yours: [MusicStation] = []
        if let p = input.playing { yours.append(songStation(p, subtitle: Localized.string("From the song playing now"))) }
        var usedArtists = Set<String>()
        for st in stats.prefix(maxArtists) {
            usedArtists.insert(st.key)
            let relation = st.liked > 0 ? Localized.string("An artist you like") : Localized.string("An artist you play")
            yours.append(artistStation(name: st.name, relation: relation, thumbs: st.thumbs, seed: .track(st.seed)))
        }
        for a in input.followed where usedArtists.count < maxArtists && usedArtists.insert(key(a.name)).inserted {
            yours.append(artistStation(name: a.name, relation: Localized.string("An artist you follow"), thumbs: a.thumbnails, seed: .artist(a)))
        }
        let exclude = Set([input.playing?.uid].compactMap { $0 })
        let likedSeeds = MusicRadioSeeds.unique(input.liked, excluding: exclude, limit: maxSongs / 2)
        let recentSeeds = MusicRadioSeeds.unique(input.history.sorted { $0.at > $1.at }.map(\.track), excluding: exclude.union(likedSeeds.map(\.uid)), limit: maxSongs / 2)
        yours += (likedSeeds + recentSeeds).map { songStation($0) }
        s.yours = yours

        // Featured: the chosen country, then the languages the person listens to. Needs no history for the country.
        var featured = input.region.isEmpty ? [] : [regionStation(input.region)]          // worldwide has no "Top <country> Radio"
        featured += historyLangs.prefix(maxFeaturedLanguages).map { languageStation(key: $0.rawValue, name: $0.displayName) }
        s.featured = featured

        // Regional: a language's charts in the country, where a source lists them (India).
        if MusicRegionalSources.jioSaavnRegions.contains(input.region.lowercased()) {
            let wanted = MusicRegionalSources.jioSaavnLanguages(region: input.region, wanted: historyLangs)
            s.regional = wanted.map { chartStation(region: input.region.lowercased(), language: $0) }
        }

        // Genres: those the person's followed artists name come first when the catalogue lists them.
        let followedGenres = Set(input.followed.flatMap(\.genres).map(key))
        let ordered = input.genres.filter { followedGenres.contains(key($0.name)) } + input.genres.filter { !followedGenres.contains(key($0.name)) }
        s.genres = MusicCategory.unique(ordered).prefix(limit).map(genreStation)

        // Languages: those in the person's history first, then the rest of the catalogue; the featured ones are not repeated.
        let featuredIDs = Set(s.featured.map(\.id))
        let keys = MusicLanguageDetect.ordered(keys: MusicCategoryCatalogue.languages.map(\.key), preferring: historyLangs.map(\.rawValue))
        s.languages = keys.compactMap { k in
            MusicCategoryCatalogue.languages.first { $0.key == k }.map { languageStation(key: $0.key, name: Localized.string($0.name)) }
        }.filter { !featuredIDs.contains($0.id) }.prefix(limit).map { $0 }

        s.recent = input.recent
        return s
    }
}

// MARK: - Recently played stations

/// The stations the person started lately, newest first, kept on this device. Cleared by "Wipe all".
enum MusicRadioRecents {
    static let cap = 20
    static let defaultsKey = "music.radio.recentStations"

    /// `station` moved to the front (one entry per station), the list cut to `cap`.
    static func recording(_ station: MusicStation, into list: [MusicStation], cap: Int = cap) -> [MusicStation] {
        Array(([station] + list.filter { $0.id != station.id }).prefix(cap))
    }

    static func load(_ d: UserDefaults = .standard) -> [MusicStation] {
        guard let data = d.data(forKey: defaultsKey), let list = try? JSONDecoder().decode([MusicStation].self, from: data) else { return [] }
        return Array(list.prefix(cap))
    }

    static func save(_ list: [MusicStation], to d: UserDefaults = .standard) {
        if list.isEmpty { d.removeObject(forKey: defaultsKey); return }
        if let data = try? JSONEncoder().encode(Array(list.prefix(cap))) { d.set(data, forKey: defaultsKey) }
    }

    @discardableResult
    static func record(_ station: MusicStation, in d: UserDefaults = .standard) -> [MusicStation] {
        let list = recording(station, into: load(d))
        save(list, to: d)
        return list
    }

    static func wipe(_ d: UserDefaults = .standard) { d.removeObject(forKey: defaultsKey) }
}
