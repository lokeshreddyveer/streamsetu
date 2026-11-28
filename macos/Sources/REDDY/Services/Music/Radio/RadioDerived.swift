import Foundation

// "Made for you" and "Based on your region": stations worked out from what the person plays and from the lists a source returns for the chosen
// country. Nothing is a fixed list: artists come from the history, genres from what the songs and followed artists say, languages from the scripts
// the person plays, and a chart station is named by the list the source returned. A new person with no history gets only the region stations.

enum RadioDerived {
    struct Input: Sendable {
        var history: [PlayRecord] = []
        var liked: [MusicTrack] = []
        var followed: [MusicArtist] = []
        /// The lists a source returned for the chosen country (names and songs come from the answer).
        var chartSections: [MusicBrowseSection] = []
        var region = ""
    }

    struct Result: Equatable, Sendable {
        /// Thumbprint: a station built from every song the person liked (thumbs up included, since a thumb up likes the song).
        var thumbprint: RadioStation?
        var daily: RadioStation?
        var artists: [RadioStation] = []
        var genres: [RadioStation] = []
        var languages: [RadioStation] = []
        var regional: [RadioStation] = []
        var hasPersonal: Bool { thumbprint != nil || daily != nil || !artists.isEmpty || !genres.isEmpty || !languages.isEmpty }
        var all: [RadioStation] { (thumbprint.map { [$0] } ?? []) + (daily.map { [$0] } ?? []) + artists + genres + languages + regional }
    }

    static let maxArtists = 8
    static let maxGenres = 4
    static let maxLanguages = 3
    static let maxRegional = 6
    /// Plays before a daily mix is offered.
    static let dailyMinPlays = 5
    /// Liked songs before a Thumbprint station is offered, and how many of the most liked artists seed it.
    static let thumbprintMinLikes = 5
    static let thumbprintArtists = 5

    static func build(_ input: Input) -> Result {
        var r = Result()
        let stats = MusicRadioStations.artistStats(history: input.history, liked: input.liked)

        r.artists = stats.prefix(maxArtists).map { st in
            RadioStation(id: "artist:" + st.key, name: Localized.string("%@ Radio", st.name), seeds: [artistSeed(from: st.seed, fallbackName: st.name)],
                         covers: Array(st.thumbs.suffix(1)), derivedID: "artist:" + st.key)
        }

        // Genres: what the providers said about the songs played (their own tags) and about the artists followed. Counted, never listed by the app.
        var genreCounts: [String: (name: String, n: Int)] = [:]
        func bump(_ g: String?) {
            guard let g = g?.trimmingCharacters(in: .whitespaces), g.count > 1 else { return }
            let k = MusicCategory.normalise(g)
            genreCounts[k, default: (g, 0)].n += 1
        }
        for t in input.liked + input.history.map(\.track) { bump(t.hints?.genre) }
        for a in input.followed { for g in a.genres { bump(g); bump(g) } }
        let genres = genreCounts.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }
            .filter { $0.value.n >= 2 }.prefix(maxGenres)
        r.genres = genres.map { g in
            RadioStation(id: "genre:" + g.key, name: Localized.string("%@ Radio", g.value.name), seeds: [.genre(g.value.name)], derivedID: "genre:" + g.key)
        }

        // Languages the person really plays (a script seen at least twice).
        let langs = MusicRadioStations.historyLanguages(liked: input.liked, history: input.history).prefix(maxLanguages)
        r.languages = langs.map { l in
            RadioStation(id: "language:" + l.rawValue, name: Localized.string("%@ Radio", l.displayName), seeds: [.language(key: l.rawValue, name: l.englishName)], derivedID: "language:" + l.rawValue)
        }

        // A daily mix: the person's top artists and top language together, offered once there is something to mix.
        if input.history.count >= dailyMinPlays, !stats.isEmpty {
            var seeds = stats.prefix(3).map { artistSeed(from: $0.seed, fallbackName: $0.name) }
            if let l = langs.first { seeds.append(.language(key: l.rawValue, name: l.englishName)) }
            r.daily = RadioStation(id: "daily", name: Localized.string("Daily mix"), seeds: seeds, mode: .mixed,
                                   covers: stats.prefix(4).compactMap { $0.thumbs.last }, derivedID: "daily")
        }

        r.thumbprint = thumbprint(liked: input.liked)
        r.regional = regional(input.chartSections, region: input.region)
        return r
    }

    /// A station from everything the person liked: seeded with the artists they liked most, in the familiar mode so it stays close to their taste. Nothing until
    /// there are enough likes to say something, and the name is the only fixed text; the artists come from the likes.
    static func thumbprint(liked: [MusicTrack]) -> RadioStation? {
        guard liked.count >= thumbprintMinLikes else { return nil }
        var counts: [String: (track: MusicTrack, name: String, n: Int)] = [:]
        for t in liked {
            guard let ref = t.artists.first(where: { !$0.id.isEmpty && !MusicArtistFiller.isFiller($0.name) }) else { continue }
            let key = t.providerID + ":" + ref.id
            counts[key, default: (t, ref.name, 0)].n += 1
        }
        let top = counts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.prefix(thumbprintArtists)
        guard top.count >= 2 else { return nil }
        let seeds = top.map { artistSeed(from: $0.track, fallbackName: $0.name) }
        return RadioStation(id: "thumbprint", name: Localized.string("Thumbprint Radio"), seeds: Array(seeds), mode: .familiar,
                            covers: top.compactMap { $0.track.thumbnails.last }, derivedID: "thumbprint")
    }

    /// One station for each list a source returned for the country, named by the list and seeded with its first songs.
    static func regional(_ sections: [MusicBrowseSection], region: String) -> [RadioStation] {
        var out: [RadioStation] = []
        var seen = Set<String>()
        for s in sections {
            let songs = s.items.compactMap { item -> MusicTrack? in if case .track(let t) = item { return t } else { return nil } }
            guard songs.count >= 3, !s.title.isEmpty, seen.insert(s.id).inserted else { continue }
            let seeds = songs.prefix(3).map { RadioSeed.song($0) }
            out.append(RadioStation(id: "region:" + region + ":" + s.id, name: s.title, seeds: Array(seeds),
                                    covers: songs.prefix(4).compactMap { $0.thumbnails.last }, derivedID: "region:" + region + ":" + s.id))
            if out.count >= maxRegional { break }
        }
        return out
    }

    /// The artist as a seed when the song names one, else the song itself.
    static func artistSeed(from t: MusicTrack, fallbackName: String) -> RadioSeed {
        if let ref = t.artists.first(where: { !$0.id.isEmpty && !MusicArtistFiller.isFiller($0.name) }) {
            return .artist(MusicArtist(id: ref.id, providerID: t.providerID, name: ref.name, thumbnails: ref.thumbnails.isEmpty ? t.thumbnails : ref.thumbnails))
        }
        return .song(t)
    }

    /// The saved station for a derived one, so starting it twice finds the same station (with its taste and history) instead of a copy.
    static func existing(for draft: RadioStation, in stations: [RadioStation]) -> RadioStation? {
        guard let d = draft.derivedID else { return nil }
        return stations.first { $0.derivedID == d }
    }
}
