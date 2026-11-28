import Foundation

// The pure rules of the album / soundtrack page: which related soundtrack gets which reason, in which order, which items are the same thing, which
// provider album may be taken for a film's soundtrack, how two people of one name are told apart. No store, no view: values in, values out.

// MARK: - Albums as facts

/// What the ranking needs to know about one album (the opened one or a candidate), gathered by the builders.
struct MusicSoundtrackAlbumFacts: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var year: Int?
    var imageRef: String?
    var subkind: String?
    var film: MusicSoundtrackFilm?
    var musicDirectors: [MusicEntityID: String] = [:]
    var composers: [MusicEntityID: String] = [:]
    var singers: [MusicEntityID: String] = [:]
    var cast: [MusicEntityID: String] = [:]
    var languageName: String?
    var genres: [String] = []
    /// A `relatedAlbum` edge between the seed and this album, when one exists.
    var directStatus: EdgeStatus?
    var directConfidence: Float = 0
    /// How sure the evidence behind this candidate is (the film link or credit edges). Used to word an inferred link as "Possibly related".
    var evidenceStatus: EdgeStatus = .verified
    var evidenceConfidence: Float = 1

    init(id: MusicEntityID, title: String, year: Int? = nil, imageRef: String? = nil, subkind: String? = nil, film: MusicSoundtrackFilm? = nil) {
        self.id = id; self.title = title; self.year = year; self.imageRef = imageRef; self.subkind = subkind; self.film = film
    }

    /// The year of the music for era comparisons: the film's year for a soundtrack, else the album's.
    var eraYear: Int? { film?.year ?? year }
}

// MARK: - Clusters and de-duplication

enum MusicSoundtrackCluster {
    /// Two albums with the same key are one thing. Soundtracks of one film are one cluster (language editions of a soundtrack collapse onto the best
    /// one); other albums cluster by folded title and year, so a re-release of one record does not appear twice.
    static func key(id: MusicEntityID, title: String, year: Int?, film: MusicEntityID?) -> String {
        if let film { return "film:" + film.rawValue }
        return "album:" + MusicGraphText.latin(title) + "|" + (year.map(String.init) ?? "")
    }
    static func key(_ a: MusicSoundtrackAlbum) -> String { a.cluster }
    static func key(_ f: MusicSoundtrackAlbumFacts) -> String { key(id: f.id, title: f.title, year: f.year, film: f.film?.id) }
}

enum MusicSoundtrackDedupe {
    /// The shelves of albums in page order. Each one drops what an earlier one already showed (by cluster) and repeats within itself; the opened album's
    /// own cluster is never shown.
    static func apply(_ lists: [[MusicSoundtrackAlbum]], excluding seed: Set<String>) -> [[MusicSoundtrackAlbum]] {
        var shown = seed
        return lists.map { list in
            var out: [MusicSoundtrackAlbum] = []
            for a in list where shown.insert(a.cluster).inserted { out.append(a) }
            return out
        }
    }

    /// The same for entries that mix albums and songs (songs are kept by id).
    static func apply(_ entries: [MusicSoundtrackEntry], shown: inout Set<String>) -> [MusicSoundtrackEntry] {
        var out: [MusicSoundtrackEntry] = []
        for e in entries {
            switch e {
            case .album(let a): if shown.insert(a.cluster).inserted { out.append(e) }
            case .song(let s): if shown.insert("song:" + s.id.rawValue).inserted { out.append(e) }
            }
        }
        return out
    }
}

// MARK: - Related soundtracks (section I)

enum MusicSoundtrackRelated {
    /// Band bases of the design's ladder (section 5.1): a lower band number always outranks a higher one.
    static func base(_ band: Int) -> Double {
        switch band { case 1: 1000; case 2: 850; case 3: 750; case 4: 650; case 5: 550; case 6: 400; case 7: 300; default: 100 }
    }

    static func decadeLabel(_ year: Int) -> String { "\(year / 10 * 10)s" }

    /// How `candidate` relates to `seed`: the strongest signal, with its reason and strength (0...1). Nil when nothing can be said, so nothing
    /// unexplained is ever shown.
    static func classify(seed: MusicSoundtrackAlbumFacts, candidate: MusicSoundtrackAlbumFacts) -> (band: Int, reason: MusicSoundtrackReason, strength: Double)? {
        func names(_ ids: Set<MusicEntityID>, _ d: [MusicEntityID: String]) -> [String] { ids.compactMap { d[$0] }.sorted() }
        let seedMakers = seed.musicDirectors.merging(seed.composers) { a, _ in a }
        let candMakers = candidate.musicDirectors.merging(candidate.composers) { a, _ in a }
        let sharedMakers = Set(seedMakers.keys).intersection(candMakers.keys)
        let sharedSingers = Set(seed.singers.keys).intersection(candidate.singers.keys)
        let sharedCast = Set(seed.cast.keys).intersection(candidate.cast.keys)

        let wrap: (MusicSoundtrackReason) -> MusicSoundtrackReason = {
            MusicSoundtrackReason.qualified($0, status: candidate.evidenceStatus, confidence: candidate.evidenceConfidence)
        }

        if let status = candidate.directStatus ?? (seed.film != nil && seed.film?.id == candidate.film?.id ? .verified : nil), status != .conflicted {
            let sameFilm = seed.film != nil && seed.film?.id == candidate.film?.id
            let conf = Double(max(candidate.directConfidence, sameFilm ? 0.9 : 0))
            return (1, sameFilm ? .otherEdition : .relatedAlbum, max(0.5, conf))
        }
        if !sharedMakers.isEmpty, let singer = names(sharedSingers, seed.singers).first, let maker = names(sharedMakers, seedMakers).first {
            let union = Set(seedMakers.keys).union(candMakers.keys).count + Set(seed.singers.keys).union(candidate.singers.keys).count
            let strength = Double(sharedMakers.count + sharedSingers.count) / Double(max(1, union))
            return (2, wrap(.sameCreatorsAndSinger(composer: maker, singer: singer)), min(1, max(0.3, strength * 2)))
        }
        if !sharedCast.isEmpty, candidate.film != nil {
            return (3, wrap(.sharedCast(Array(names(sharedCast, seed.cast).prefix(3)))), min(1, Double(sharedCast.count) / 3))
        }
        if let singer = names(sharedSingers, seed.singers).first {
            return (4, wrap(.sungBy(singer)), min(1, Double(sharedSingers.count) / 3))
        }
        if !sharedMakers.isEmpty {
            let directors = Set(seed.musicDirectors.keys).intersection(candidate.musicDirectors.keys)
            if let n = names(directors, seed.musicDirectors).first { return (5, wrap(.sameMusicDirector(n)), 0.8) }
            if let n = names(sharedMakers, seedMakers).first { return (5, wrap(.sameComposer(n)), 0.8) }
        }
        if let sy = seed.eraYear, let cy = candidate.eraYear, abs(sy - cy) <= MusicSoundtrackLimits.eraYears,
           let sl = seed.languageName, let cl = candidate.languageName, MusicGraphText.latin(sl) == MusicGraphText.latin(cl) {
            return (6, wrap(.eraAndLanguage(era: decadeLabel(cy), language: cl)), 1 - Double(abs(sy - cy)) / Double(MusicSoundtrackLimits.eraYears + 1))
        }
        if let g = seed.genres.first(where: { s in candidate.genres.contains { MusicGraphText.latin($0) == MusicGraphText.latin(s) } }) {
            return (7, wrap(.sameGenre(g)), 0.5)
        }
        return nil
    }

    /// The related albums, best first: one per cluster, never the opened album's own, each with its one-line reason.
    static func rank(seed: MusicSoundtrackAlbumFacts, candidates: [MusicSoundtrackAlbumFacts], limit: Int = MusicSoundtrackLimits.relatedShown) -> [MusicSoundtrackAlbum] {
        let seedCluster = MusicSoundtrackCluster.key(seed)
        var best: [String: MusicSoundtrackAlbum] = [:]
        for c in candidates where c.id != seed.id {
            let key = MusicSoundtrackCluster.key(c)
            guard key != seedCluster, let hit = classify(seed: seed, candidate: c) else { continue }
            let closeness = seed.eraYear.flatMap { sy in c.eraYear.map { max(0, 1 - Double(abs(sy - $0)) / 60) } } ?? 0
            let score = base(hit.band) + 100 * hit.strength * Double(max(0.3, c.evidenceConfidence)) + 10 * closeness
            let item = MusicSoundtrackAlbum(id: c.id, title: c.title, year: c.year, imageRef: c.imageRef, subkind: c.subkind, film: c.film, reason: hit.reason,
                                            band: hit.band, score: score, cluster: key)
            if let have = best[key], have.score >= score { continue }
            best[key] = item
        }
        return Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }.prefix(limit))
    }
}

// MARK: - Classic cinema (section J)

enum MusicSoundtrackClassic {
    /// Film soundtracks of the same language within ten years of the opened film (or album year), nearest first, each with its reason. Needs a film
    /// link and a language to say anything: with neither, the section stays hidden.
    static func select(seedYear: Int?, languageName: String?, candidates: [MusicSoundtrackAlbumFacts], excluding: Set<String>,
                       limit: Int = MusicSoundtrackLimits.classicShown) -> [MusicSoundtrackAlbum] {
        guard let seedYear, let languageName, !languageName.isEmpty else { return [] }
        let from = seedYear - MusicSoundtrackLimits.eraYears, to = seedYear + MusicSoundtrackLimits.eraYears
        var seen = excluding
        var out: [MusicSoundtrackAlbum] = []
        let want = MusicGraphText.latin(languageName)
        let ordered = candidates.filter { $0.film != nil }.sorted {
            let a = abs(($0.eraYear ?? 0) - seedYear), b = abs(($1.eraYear ?? 0) - seedYear)
            return a != b ? a < b : $0.title < $1.title
        }
        for c in ordered {
            guard let y = c.eraYear, (from...to).contains(y), c.film?.linkStatus != .conflicted else { continue }
            let language = c.languageName ?? c.film?.language
            guard let language, MusicGraphText.latin(language) == want || MusicGraphText.latin(language) == MusicGraphText.latin(languageName) else { continue }
            let key = MusicSoundtrackCluster.key(c)
            guard seen.insert(key).inserted else { continue }
            let reason = MusicSoundtrackReason.qualified(.classicCinema(language: languageName, from: from, to: to), status: c.evidenceStatus, confidence: c.evidenceConfidence)
            out.append(MusicSoundtrackAlbum(id: c.id, title: c.title, year: c.year, imageRef: c.imageRef, subkind: c.subkind, film: c.film, reason: reason, band: 6,
                                            score: 400 - Double(abs(y - seedYear)), cluster: key))
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Films by cast (section E)

enum MusicSoundtrackFilmFilter {
    /// All items, or only the films a chosen actor is in.
    static func apply(_ items: [MusicSoundtrackFilmItem], actor: MusicEntityID?) -> [MusicSoundtrackFilmItem] {
        guard let actor else { return items }
        return items.filter { $0.actors.contains { $0.id == actor } }
    }

    /// Relevance: films that share more of this page's cast first, lead roles count more, nearer in time breaks ties.
    static func score(shared: Int, leadBillings: [Int], year: Int?, seedYear: Int?) -> Double {
        let lead = leadBillings.reduce(0.0) { $0 + Double(max(0, 20 - $1 * 2)) }
        let near = (year != nil && seedYear != nil) ? -min(50, Double(abs(year! - seedYear!))) * 0.5 : 0
        return Double(shared) * 100 + lead + near
    }
}

// MARK: - People of one name

enum MusicSoundtrackDisambiguator {
    /// For a list of people: the detail to show for each one whose name another listed person shares (by folded spelling). A person with a unique
    /// name gets no entry. Two people with the same detail get a short id suffix so the lines still differ. Never merges anyone.
    static func details(for people: [MusicSoundtrackPerson]) -> [MusicEntityID: String] {
        var byName: [String: [MusicSoundtrackPerson]] = [:]
        var seen = Set<MusicEntityID>()
        for p in people where seen.insert(p.id).inserted { byName[MusicGraphText.latin(p.name), default: []].append(p) }
        var out: [MusicEntityID: String] = [:]
        for group in byName.values where group.count > 1 {
            var used: [String: Int] = [:]
            for p in group { used[p.detail ?? "", default: 0] += 1 }
            for p in group {
                let suffix = "#" + String(p.id.token.suffix(4))
                if let d = p.detail, !d.isEmpty { out[p.id] = used[d, default: 0] > 1 ? d + " " + suffix : d } else { out[p.id] = suffix }
            }
        }
        return out
    }

    /// One person, one chip. The same name under another role (or under a second entity of the same name) is, on one album's credits, the same person unless
    /// something says otherwise: two credits merge only when their descriptions are both empty or identical. A birth year or a description that differs ("1924"
    /// against "playback singer") means two people, who stay two credits and keep their labels. Merged credits show once: the most specific role keeps the chip,
    /// the other roles are returned in `also` for its second line, and its song count is the largest of the merged ones. The graph still holds every role and
    /// entity separately; only this display is merged (Apple Music also lists each person once with every role named).
    static func mergedByName(_ credits: [MusicSoundtrackCredit], kind: (MusicRole) -> MusicSoundtrackCreditKind, roleName: (MusicRole) -> String,
                             also: ([String]) -> String) -> (credits: [MusicSoundtrackCredit], also: [MusicEntityID: String]) {
        var order: [String] = []
        var byName: [String: [MusicSoundtrackCredit]] = [:]
        for c in credits {
            // The same name with a different description is a different person: the description is part of the key.
            // Roles of the "other" kind (Director, Producer...) are shown one row each, so one person in two of them is not a repeat: only the same role merges there.
            let k = MusicGraphText.latin(c.person.name) + "|" + (c.person.detail ?? "") + (kind(c.role) == .other ? "|" + c.role.rawValue : "")
            if byName[k] == nil { order.append(k) }
            byName[k, default: []].append(c)
        }
        var out: [MusicSoundtrackCredit] = []
        var alsoLines: [MusicEntityID: String] = [:]
        for k in order {
            let group = byName[k] ?? []
            guard group.count > 1 else { out += group; continue }
            let sorted = group.sorted { (kind($0.role).rawValue, $0.order) < (kind($1.role).rawValue, $1.order) }
            var keep = sorted[0]
            var seen = Set<String>([roleName(keep.role)])
            let extras = sorted.dropFirst().filter { kind($0.role) != kind(keep.role) }.map { roleName($0.role) }.filter { seen.insert($0).inserted }
            if !extras.isEmpty { alsoLines[keep.person.id] = also(extras) }
            keep.songCount = group.map(\.songCount).max() ?? keep.songCount
            out.append(keep)
        }
        return (out, alsoLines)
    }

    /// The people with the details of `details(for:)` applied and every other detail cleared.
    static func apply(_ person: MusicSoundtrackPerson, _ details: [MusicEntityID: String]) -> MusicSoundtrackPerson {
        var p = person
        p.detail = details[person.id]
        return p
    }
}

// MARK: - Provider albums taken for a film's soundtrack (section F)

/// An album a provider search returned for a film, before it is accepted.
struct MusicSoundtrackProviderAlbum: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var year: Int?
    var imageRef: String?
    var artistLine: String
    /// The provider's own `providerID:id` of the album, so an accepted match can be written back under it.
    var providerUID: String = ""
}

enum MusicSoundtrackMatch {
    private static let markers = ["soundtrack", "ost", "original motion picture", "original score", "from the film", "from the movie", "music from", "film"]

    /// A provider album is taken for the soundtrack of a film only when its title carries the film's whole title, says it is a soundtrack (or is exactly
    /// the film's title, the usual way a film's record is named), and any year in it or on it agrees with the film's year within two. Anything weaker is
    /// rejected: an actor's film is never shown as an album without a matched release.
    static func accepts(film: MusicSoundtrackFilm, album: MusicSoundtrackProviderAlbum) -> Bool {
        let wanted = tokens(film.title)
        guard !wanted.isEmpty else { return false }
        let title = MusicGraphText.latin(album.title)
        let have = Set(tokens(album.title))
        guard wanted.allSatisfy({ have.contains($0) }) else { return false }
        let exact = tokens(album.title.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)) == wanted
        // A marker counts only as whole words: "ost" is in "lost", "most" and "ghost", "film" in "filmfare".
        let spaced = " " + tokens(title).joined(separator: " ") + " "
        let marked = markers.contains { spaced.contains(" " + $0 + " ") }
        guard exact || marked else { return false }
        if let fy = film.year {
            if let ay = album.year, abs(ay - fy) > 2 { return false }
            if let ty = yearInTitle(album.title), abs(ty - fy) > 2 { return false }
        }
        return true
    }

    static func tokens(_ s: String) -> [String] {
        MusicGraphText.latin(s).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }

    static func yearInTitle(_ s: String) -> Int? {
        guard let r = s.range(of: #"(?<!\d)(19|20)\d{2}(?!\d)"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }
}

// MARK: - Attribution

enum MusicSoundtrackAttribution {
    /// The line a section shows when a source's licence or terms ask for credit. Nil when none of the sources needs one.
    static func line(sources: [MusicSourceID], format: (String) -> String = { $0 }) -> String? {
        var parts: [String] = []
        let ids = Set(sources.map(\.rawValue))
        if ids.contains(MusicSourceID.tmdb.rawValue) { parts.append(format("Film data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")) }
        var named: [String] = []
        if ids.contains(MusicSourceID.wikipedia.rawValue) { named.append("Wikipedia") }
        if ids.contains(MusicSourceID.wikidata.rawValue) { named.append("Wikidata") }
        if ids.contains(MusicSourceID.imdb.rawValue) { named.append("IMDb") }
        if ids.contains(MusicSourceID.musicbrainz.rawValue) { named.append("MusicBrainz") }
        if !named.isEmpty { parts.append(format("Source: %@").replacingOccurrences(of: "%@", with: named.joined(separator: ", "))) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Shelf visibility

enum MusicSoundtrackShelfRule {
    enum Presentation: Equatable, Sendable { case skeleton, cards, hidden }
    /// Items win; with none, a section still working shows a skeleton and a finished one (empty or failed) is hidden without a trace.
    static func presentation(phase: MusicSectionPhase, itemCount: Int) -> Presentation {
        if itemCount > 0 { return .cards }
        switch phase {
        case .idle, .loading, .partial: return .skeleton
        case .loaded, .empty, .failed: return .hidden
        }
    }
}

/// Whether a credited name can be a person's: wiki template words and markup that a page parser took for a name ("Infobox", "{{Plainlist", "a=b") are not.
enum MusicSoundtrackNameGuard {
    static func isPersonName(_ name: String) -> Bool { MusicPersonNameGuard.isPersonName(name) }

    /// The credits worth listing once each: real names only, and one entry per name AND description. The same name with a different description (a birth year, "playback singer")
    /// is another person and stays (a name alone is not an identity); the same name with the same or no description is one person filed under several entities.
    static func listable(_ credits: [MusicSoundtrackCredit]) -> [MusicSoundtrackCredit] {
        var seen = Set<String>()
        return credits.filter { c in
            isPersonName(c.person.name) && seen.insert(MusicGraphText.latin(c.person.name) + "|" + (c.person.detail ?? "")).inserted
        }
    }
}
