import Foundation

/// One film of an actor, with the soundtrack album the active music source has for it.
struct MusicActorFilm: Hashable, Sendable, Identifiable {
    var credit: MusicFilmCredit
    var album: MusicAlbum
    var id: Int { credit.tmdbID }
}

/// "More music with an actor": the actor's films from TMDB, each matched to a soundtrack album on the browsing source. A film with no close album
/// is left out; nothing is guessed. Every call is injectable, so tests use fake providers and fixtures.
struct MusicActorMusic: Sendable {
    /// How many of an actor's films are looked up for albums.
    static let filmLimit = 12
    /// Songs taken from each album, and in all.
    static let songsPerAlbum = 3
    static let songLimit = 24

    var tmdb: MusicFilmTMDBGate.Fetch?
    var cache: MusicFilmCache
    var searchAlbums: @Sendable (String) async -> [MusicAlbum]
    var albumTracks: @Sendable (MusicAlbum) async -> [MusicTrack]
    /// Keeps only songs that are verified playable (the identity function for a source that has its own audio).
    var playable: @Sendable ([MusicTrack]) async -> [MusicTrack]

    init(tmdb: MusicFilmTMDBGate.Fetch? = MusicFilmTMDBGate.shared.fetch, cache: MusicFilmCache = .shared,
         searchAlbums: @escaping @Sendable (String) async -> [MusicAlbum], albumTracks: @escaping @Sendable (MusicAlbum) async -> [MusicTrack],
         playable: @escaping @Sendable ([MusicTrack]) async -> [MusicTrack] = { $0 }) {
        self.tmdb = tmdb; self.cache = cache; self.searchAlbums = searchAlbums; self.albumTracks = albumTracks; self.playable = playable
    }

    // MARK: films

    /// The actor's released films, the films in `language` first, then by popularity; at most `filmLimit`.
    func films(of person: MusicFilmPerson, language: String?) async -> [MusicFilmCredit] {
        guard let id = await tmdbID(of: person) else { return [] }
        let key = "actor.\(id)"
        var all: [MusicFilmCredit]
        if let hit = cache.read([MusicFilmCredit].self, key: key) { all = hit ?? [] }
        else if let tmdb, let d = try? await tmdb("/3/person/\(id)/movie_credits", [URLQueryItem(name: "language", value: "en-US")]) {
            all = Array(MusicFilmTMDBParser.filmography(from: d).sorted { $0.popularity > $1.popularity }.prefix(60))
            cache.write(all.isEmpty ? nil : all, key: key)
        } else { all = [] }
        return Self.order(all, language: language)
    }

    static func order(_ all: [MusicFilmCredit], language: String?) -> [MusicFilmCredit] {
        let same = all.filter { language != nil && $0.language == language }.sorted { $0.popularity > $1.popularity }
        let rest = all.filter { !(language != nil && $0.language == language) }.sorted { $0.popularity > $1.popularity }
        return Array((same + rest).prefix(filmLimit))
    }

    func tmdbID(of person: MusicFilmPerson) async -> Int? {
        if let id = person.tmdbID { return id }
        let key = "person." + MusicTransliterationKey.key(person.name).replacingOccurrences(of: " ", with: "-")
        if let hit = cache.read(Int.self, key: key) { return hit }
        guard let tmdb, let d = try? await tmdb("/3/search/person", [URLQueryItem(name: "query", value: person.name), URLQueryItem(name: "include_adult", value: "false")]) else { return nil }
        let id = MusicFilmTMDBParser.personID(from: d, matching: person.name)
        cache.write(id, key: key)
        return id
    }

    // MARK: albums

    /// The soundtrack album of each film, in the films' order. Four lookups run at a time.
    func albums(for credits: [MusicFilmCredit]) async -> [MusicActorFilm] {
        var found: [Int: MusicActorFilm] = [:]
        var index = 0
        while index < credits.count {
            let chunk = Array(credits[index..<min(index + 4, credits.count)])
            index += chunk.count
            await withTaskGroup(of: (Int, MusicActorFilm?).self) { group in
                for c in chunk { group.addTask { (c.tmdbID, await album(for: c)) } }
                for await (id, f) in group { if let f { found[id] = f } }
            }
            if Task.isCancelled { break }
        }
        return credits.compactMap { found[$0.tmdbID] }
    }

    func album(for credit: MusicFilmCredit) async -> MusicActorFilm? {
        for query in [credit.title, credit.year.map { "\(credit.title) \($0)" }].compactMap({ $0 }) {
            let candidates = await searchAlbums(query)
            if let a = Self.matchAlbum(credit: credit, among: candidates) { return MusicActorFilm(credit: credit, album: a) }
        }
        return nil
    }

    /// The close album for a film: its name (soundtrack wording removed) is the film's, within a year of the film, not a karaoke or remix release.
    static func matchAlbum(credit: MusicFilmCredit, among albums: [MusicAlbum]) -> MusicAlbum? {
        let banned = ["karaoke", "tribute", "instrumental", "remix", "lofi", "lo-fi", "reprise", "jukebox", "cover", "8d", "slowed", "unplugged", "mashup"]
        struct Scored { var album: MusicAlbum; var score: Double }
        let scored: [Scored] = albums.compactMap { a in
            let lower = a.title.lowercased()
            guard !MusicFilmEditionRules.hasWord(lower, in: banned) else { return nil }
            let name = MusicFilmResolver.clean(MusicFilmResolver.soundtrackFilm(inAlbumTitle: a.title) ?? a.title).title
            let sim = Double([credit.title, credit.originalTitle].map { MusicTransliterationKey.similarity(name, $0) }.max() ?? 0)
            guard sim >= 0.9 else { return nil }
            var s = sim
            if let want = credit.year, let have = MusicFilmResolver.year(of: a.releaseDate) {
                let d = abs(want - have)
                guard d <= 1 else { return nil }
                s -= 0.02 * Double(d)
            }
            if let n = a.totalTracks { s += n >= 3 ? 0.03 : -0.05 }
            return Scored(album: a, score: s)
        }
        return scored.max { $0.score < $1.score }?.album
    }

    // MARK: songs

    /// Up to three songs from each film's album (the source's most popular first), only the verified-playable ones, `songLimit` in all.
    func songs(from films: [MusicActorFilm]) async -> [MusicTrack] {
        var perFilm: [[MusicTrack]] = Array(repeating: [], count: films.count)
        var index = 0
        while index < films.count {
            let chunk = Array(films.indices[index..<min(index + 3, films.count)])
            index += chunk.count
            await withTaskGroup(of: (Int, [MusicTrack]).self) { group in
                for i in chunk { group.addTask {
                    let tracks = await albumTracks(films[i].album)
                    let top = tracks.enumerated().sorted { ($0.element.popularity ?? -1) != ($1.element.popularity ?? -1) ? ($0.element.popularity ?? -1) > ($1.element.popularity ?? -1) : $0.offset < $1.offset }
                    return (i, Array(top.prefix(Self.songsPerAlbum + 3).map(\.element)))
                } }
                for await (i, t) in group { perFilm[i] = t }
            }
            if Task.isCancelled { break }
        }
        var out: [MusicTrack] = []
        var seen = Set<String>()
        for tracks in perFilm {
            let ok = await playable(tracks)
            for t in ok.prefix(Self.songsPerAlbum) where seen.insert(t.uid).inserted { out.append(t) }
            if out.count >= Self.songLimit { break }
        }
        return Array(out.prefix(Self.songLimit))
    }
}

/// The page "More with <actor>": who, in which film they were opened from, and which source to look for the albums on.
struct MusicActorRoute: Hashable, Sendable {
    var person: MusicFilmPerson
    var language: String?
    var providerID: String
    var filmTitle: String
}
