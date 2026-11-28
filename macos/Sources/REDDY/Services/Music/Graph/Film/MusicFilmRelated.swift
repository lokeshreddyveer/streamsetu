import Foundation

// Related films: which other films share cast, a director, a composer, a language or an era with this one, with the reasons. The scoring is pure; the
// reading of the graph is bounded (a handful of people, a few dozen films each) and lives in `MusicFilmRelatedReading`.

/// How a candidate film is connected to the one on the page.
enum MusicFilmLink: Hashable, Sendable {
    case cast(person: MusicEntityID, name: String, order: Int?)
    case director(person: MusicEntityID, name: String)
    case composer(person: MusicEntityID, name: String)
}

struct MusicFilmCandidate: Hashable, Sendable {
    var film: MusicEntityID
    var name: String
    var year: Int?
    var lang: String?
    var imageRef: String?
    var links: [MusicFilmLink]
}

/// What the page's own film offers to compare with.
struct MusicFilmSubject: Hashable, Sendable {
    var film: MusicEntityID
    var name: String
    var year: Int?
    var lang: String?
}

enum MusicFilmRelatedScorer {
    static let directorWeight = 3.0
    static let composerWeight = 2.5
    /// A top-billed cast member counts fully; later billing counts less, and the cast as a whole is capped.
    static let castWeight = 1.0
    static let castCap = 3.0
    static let languageWeight = 0.5
    static let eraWeight = 0.5
    /// Within this many years (or the same decade) two films share an era.
    static let eraSpan = 5
    static let limit = 20

    static func decade(_ year: Int) -> Int { year / 10 * 10 }
    static func sharesEra(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) <= eraSpan || decade(a) == decade(b)
    }

    /// Scored, explained candidates, best first. A film needs at least one shared person to appear at all (a language or an era alone is not a
    /// reason to say two films are related). The film itself and a duplicate of it (same name and year) never appear; two films of one title but
    /// different years are two films, scored on their own links.
    static func rank(subject: MusicFilmSubject, candidates: [MusicFilmCandidate], limit: Int = MusicFilmRelatedScorer.limit) -> [MusicFilmRelatedItem] {
        var out: [MusicFilmRelatedItem] = []
        for c in candidates {
            if c.film == subject.film { continue }
            if MusicGraphText.latin(c.name) == MusicGraphText.latin(subject.name), c.year != nil, c.year == subject.year { continue }
            guard !c.links.isEmpty else { continue }
            var score = 0.0
            var reasons: [MusicFilmRelationReason] = []
            var seenDirectors = Set<MusicEntityID>(), seenComposers = Set<MusicEntityID>(), seenCast = Set<MusicEntityID>()
            var castNames: [String] = []
            var castScore = 0.0
            for l in c.links {
                switch l {
                case .director(let p, let n):
                    if seenDirectors.insert(p).inserted { score += directorWeight; reasons.append(.director(n)) }
                case .composer(let p, let n):
                    if seenComposers.insert(p).inserted { score += composerWeight; reasons.append(.composer(n)) }
                case .cast(let p, let n, let order):
                    if seenCast.insert(p).inserted {
                        castScore += castWeight * (order.map { $0 < 5 ? 1.0 : 0.6 } ?? 0.6)
                        castNames.append(n)
                    }
                }
            }
            score += min(castCap, castScore)
            if !castNames.isEmpty { reasons.append(.cast(Array(castNames.prefix(3)))) }
            if let a = subject.lang, let b = c.lang, !a.isEmpty, a.lowercased() == b.lowercased() { score += languageWeight; reasons.append(.sameLanguage(a)) }
            if sharesEra(subject.year, c.year), let y = c.year { score += eraWeight; reasons.append(.sameEra(decade(y))) }
            out.append(MusicFilmRelatedItem(film: c.film, name: c.name, year: c.year, imageRef: c.imageRef, lang: c.lang, reasons: Self.arranged(reasons), score: score))
        }
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let da = abs((a.year ?? subject.year ?? 0) - (subject.year ?? 0)), db = abs((b.year ?? subject.year ?? 0) - (subject.year ?? 0))
            if da != db { return da < db }
            return a.name < b.name
        }
        return Array(out.prefix(limit))
    }

    /// The reasons in the order a person reads them: director, composer, cast, then language and era.
    static func arranged(_ r: [MusicFilmRelationReason]) -> [MusicFilmRelationReason] {
        func rank(_ x: MusicFilmRelationReason) -> Int {
            switch x { case .director: 0; case .composer: 1; case .cast: 2; case .soundtrack: 3; case .sameLanguage: 4; case .sameEra: 5 }
        }
        return r.enumerated().sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }.map(\.element)
    }
}

/// Reads the people of a film and the films each of them is credited on. Bounded: 8 cast, directors and composers, 60 films a person, 80 candidates.
enum MusicFilmRelatedReading {
    static let castPeople = 8
    static let filmsPerPerson = 60
    static let candidateCap = 80

    /// The film's own credits as links, from its outgoing edges.
    static func ownPeople(film: MusicEntityID, store: any MusicGraphStoring) async throws -> (subject: MusicFilmSubject, cast: [(MusicEntityID, String)], directors: [(MusicEntityID, String)], composers: [(MusicEntityID, String)])? {
        var snaps = MusicFilmSnapshots(store: store)
        guard let s = await snaps.get(film) else { return nil }
        let raw = try await store.edges(of: film, predicate: nil, direction: .outgoing, limit: 500)
        let edges = raw.enumerated().sorted { a, b in
            let x = a.element.order ?? a.element.attributes.creditOrder ?? Int.max, y = b.element.order ?? b.element.attributes.creditOrder ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var cast: [(MusicEntityID, String)] = [], dirs: [(MusicEntityID, String)] = [], comps: [(MusicEntityID, String)] = []
        for e in edges {
            switch e.predicate {
            case .hasCast where cast.count < castPeople:
                if let p = await snaps.get(e.object), p.attrs["nameOnly"] != "1" { cast.append((p.id, p.name)) }
            case .directedBy:
                if let p = await snaps.get(e.object), !dirs.contains(where: { $0.0 == p.id }) { dirs.append((p.id, p.name)) }
            case .composedBy, .musicDirectedBy:
                if let p = await snaps.get(e.object), !comps.contains(where: { $0.0 == p.id }) { comps.append((p.id, p.name)) }
            default: break
            }
            try Task.checkCancellation()
        }
        return (MusicFilmSubject(film: s.id, name: s.name, year: s.year, lang: s.lang), cast, Array(dirs.prefix(3)), Array(comps.prefix(3)))
    }

    /// How many edges of one person are read before the kind filter is applied (their credits on songs and albums share the same predicate).
    static let readWindow = 400

    /// Films credited to a person under one predicate (their filmography as the graph holds it), other than `excluding`.
    static func filmsOf(person: MusicEntityID, predicate: MusicPredicate, excluding: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicEdge] {
        // A composer's incoming edges also come from recordings, works and albums (hundreds for a prolific one): read a wide window, keep the films, then cap.
        let films = try await store.edges(of: person, predicate: predicate, direction: .incoming, limit: readWindow)
            .filter { ($0.subject.kind == .film || $0.subject.kind == .series) && $0.subject != excluding }
        return Array(films.prefix(filmsPerPerson))
    }

    static func related(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmRelatedItem] {
        guard let own = try await ownPeople(film: film, store: store) else { return [] }
        var links: [MusicEntityID: [MusicFilmLink]] = [:]
        for (p, n) in own.directors {
            for e in try await filmsOf(person: p, predicate: .directedBy, excluding: film, store: store) { links[e.subject, default: []].append(.director(person: p, name: n)) }
        }
        for (p, n) in own.composers {
            for pred in [MusicPredicate.composedBy, .musicDirectedBy] {
                for e in try await filmsOf(person: p, predicate: pred, excluding: film, store: store) { links[e.subject, default: []].append(.composer(person: p, name: n)) }
            }
        }
        for (p, n) in own.cast {
            for e in try await filmsOf(person: p, predicate: .hasCast, excluding: film, store: store) { links[e.subject, default: []].append(.cast(person: p, name: n, order: e.order ?? e.attributes.creditOrder)) }
        }
        // Pre-rank by raw link count so the snapshot reads stay bounded.
        let ids = links.sorted { a, b in a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key }.prefix(candidateCap).map(\.key)
        var snaps = MusicFilmSnapshots(store: store)
        var candidates: [MusicFilmCandidate] = []
        for id in ids {
            try Task.checkCancellation()
            guard let s = await snaps.get(id) else { continue }
            candidates.append(MusicFilmCandidate(film: s.id, name: s.name, year: s.year, lang: s.lang, imageRef: s.imageRef, links: links[id] ?? []))
        }
        return MusicFilmRelatedScorer.rank(subject: own.subject, candidates: candidates)
    }

    /// More films by the director(s): newest first.
    static func moreByDirector(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmRelatedItem] {
        guard let own = try await ownPeople(film: film, store: store) else { return [] }
        var snaps = MusicFilmSnapshots(store: store)
        var out: [MusicFilmRelatedItem] = []
        var seen = Set<MusicEntityID>()
        for (p, n) in own.directors {
            for e in try await filmsOf(person: p, predicate: .directedBy, excluding: film, store: store) where seen.insert(e.subject).inserted {
                try Task.checkCancellation()
                guard let s = await snaps.get(e.subject) else { continue }
                if MusicGraphText.latin(s.name) == MusicGraphText.latin(own.subject.name), s.year == own.subject.year { continue }
                out.append(MusicFilmRelatedItem(film: s.id, name: s.name, year: s.year, imageRef: s.imageRef, lang: s.lang, reasons: [.director(n)], score: 0))
            }
        }
        out.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.name < $1.name }
        return Array(out.prefix(24))
    }

    /// The matched soundtrack albums of a film (outgoing view of `soundtrackOf` from the film's side), with the person who connects them.
    static func soundtracks(of filmID: MusicEntityID, via: String?, store: any MusicGraphStoring, snaps: inout MusicFilmSnapshots, limit: Int) async throws -> [MusicFilmAlbumItem] {
        let edges = try await store.edges(of: filmID, predicate: .soundtrackOf, direction: .incoming, limit: 40).filter(MusicFilmSoundtrackRules.accepts)
        var out: [MusicFilmAlbumItem] = []
        let film = await snaps.get(filmID)
        let subjects = Set(edges.map(\.subject))
        for e in edges where e.attributes.dubLanguage == nil {
            guard let a = await snaps.get(e.subject), a.kind == .album || a.kind == .release else { continue }
            // A release whose album group is also linked is the same music: the group shows once.
            if a.kind == .release, let g = try? await store.edges(of: e.subject, predicate: .editionOf, direction: .outgoing, limit: 4).first?.object, subjects.contains(g) { continue }
            out.append(MusicFilmAlbumItem(album: a.id, name: a.name, year: a.year, imageRef: a.imageRef, lang: a.lang, dubLanguage: nil, status: e.status, confidence: e.confidence,
                                          matchEvidence: [], via: via, film: filmID, filmName: film?.name))
            if out.count >= limit { break }
        }
        return out
    }

    /// Soundtracks of the films the top-billed cast also appear in.
    static func castMusic(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmAlbumItem] {
        guard let own = try await ownPeople(film: film, store: store) else { return [] }
        var snaps = MusicFilmSnapshots(store: store)
        var out: [MusicFilmAlbumItem] = []
        var seenAlbums = Set<MusicEntityID>(), seenFilms = Set<MusicEntityID>()
        for (p, n) in own.cast.prefix(4) {
            var taken = 0
            for e in try await filmsOf(person: p, predicate: .hasCast, excluding: film, store: store).prefix(8) where taken < 3 && seenFilms.insert(e.subject).inserted {
                taken += 1
                for a in try await soundtracks(of: e.subject, via: n, store: store, snaps: &snaps, limit: 3) where seenAlbums.insert(a.album).inserted { out.append(a) }
            }
        }
        return Array(out.prefix(20))
    }

    /// More music from the film's composers: albums credited to them (not this film's), and the soundtracks of their other films.
    static func composerMusic(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmAlbumItem] {
        guard let own = try await ownPeople(film: film, store: store) else { return [] }
        var snaps = MusicFilmSnapshots(store: store)
        let mine = Set(try await store.edges(of: film, predicate: .soundtrackOf, direction: .incoming, limit: 100).map(\.subject))
        var out: [MusicFilmAlbumItem] = []
        var seen = mine
        for (p, n) in own.composers {
            for pred in [MusicPredicate.composedBy, .musicDirectedBy] {
                for e in try await store.edges(of: p, predicate: pred, direction: .incoming, limit: readWindow).filter({ $0.subject.kind == .album || $0.subject.kind == .release }).prefix(60) {
                    try Task.checkCancellation()
                    guard !seen.contains(e.subject), let a = await snaps.get(e.subject) else { continue }
                    if e.subject.kind == .release,
                       let g = try? await store.edges(of: e.subject, predicate: .editionOf, direction: .outgoing, limit: 2).first?.object, seen.contains(g) || out.contains(where: { $0.album == g }) { continue }
                    seen.insert(e.subject)
                    out.append(MusicFilmAlbumItem(album: a.id, name: a.name, year: a.year, imageRef: a.imageRef, lang: a.lang, dubLanguage: nil, status: e.status, confidence: e.confidence,
                                                  matchEvidence: [], via: n, film: nil, filmName: nil))
                }
            }
            for predicate in [MusicPredicate.composedBy, .musicDirectedBy] {
                for e in try await filmsOf(person: p, predicate: predicate, excluding: film, store: store).prefix(8) {
                    for a in try await soundtracks(of: e.subject, via: n, store: store, snaps: &snaps, limit: 2) where seen.insert(a.album).inserted { out.append(a) }
                }
            }
        }
        out.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.name < $1.name }
        return Array(out.prefix(20))
    }
}
