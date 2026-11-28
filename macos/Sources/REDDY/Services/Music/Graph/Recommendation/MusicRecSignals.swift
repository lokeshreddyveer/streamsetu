import Foundation

/// One real reason a candidate relates to the seed, with the band it belongs to.
struct MusicRecSignal: Sendable {
    var band: MusicRecBand
    /// 0...1 inside the band.
    var strength: Double
    var confidence: Float
    var explanation: MusicRecExplanation
}

struct MusicRecCollaborator: Sendable {
    /// The seed's creator who worked with this person.
    var with: MusicEntityID
    /// A node they both worked on.
    var bridge: MusicEntityID
    var count: Int
}

/// The seed side of every comparison, computed once per request.
struct MusicRecSeed: Sendable {
    let id: MusicEntityID
    let facets: MusicRecFacets
    let snapshot: MusicEntitySnapshot?
    var collaborators: [MusicEntityID: [MusicRecCollaborator]] = [:]
    var name: String { snapshot?.name ?? "" }

    init(id: MusicEntityID, view: MusicRecGraphView, floor: Float) {
        self.id = id
        facets = MusicRecFacetBuilder.build(id, view: view, floor: floor)
        snapshot = view.snapshot(id)
        collaborators = Self.collaborators(of: id, facets: facets, view: view, floor: floor)
    }

    /// People who share a work with one of the seed's creators, without being one of them (two hops: creator, work, collaborator).
    private static func collaborators(of id: MusicEntityID, facets: MusicRecFacets, view: MusicRecGraphView, floor: Float) -> [MusicEntityID: [MusicRecCollaborator]] {
        var out: [MusicEntityID: [MusicRecCollaborator]] = [:]
        let own = Set(facets.credits.keys).union([id])
        for person in facets.credits.keys {
            var bridges: Set<MusicEntityID> = []
            for e in view.inc(person) where MusicRecRoles.credit.contains(e.predicate) && recEdgeIsUsable(e, floor: floor) && e.subject != id { bridges.insert(e.subject) }
            for b in bridges {
                for e in view.out(b, MusicRecRoles.credit) where recEdgeIsUsable(e, floor: floor) && !own.contains(e.object) {
                    if out[e.object]?.contains(where: { $0.with == person && $0.bridge == b }) != true {
                        out[e.object, default: []].append(MusicRecCollaborator(with: person, bridge: b, count: 0))
                    }
                }
            }
        }
        // `count` is the number of distinct works the collaborator shares with the seed's creators.
        for (k, list) in out { let n = Set(list.map(\.bridge)).count; out[k] = list.map { var c = $0; c.count = n; return c } }
        return out
    }
}

struct MusicRecParams: Sendable {
    var floor: Float
    var now: Date
    var affinity: MusicAffinityVector
    var includeBroad: Bool
    var preferredLanguages: Set<String>
}

enum MusicRecSignals {
    /// Every signal a candidate has, strongest band first. Pure: reads only the seed, the candidate's facets and the walk's view.
    static func evaluate(seed: MusicRecSeed, candidate id: MusicEntityID, facets c: MusicRecFacets, view: MusicRecGraphView, params p: MusicRecParams) -> [MusicRecSignal] {
        var out: [MusicRecSignal] = []
        let s = seed.facets
        func subject(_ i: MusicEntityID) -> MusicRecSubject { MusicRecSubject(id: i, name: view.name(i)) }
        func tentative(_ link: Bool, _ conf: Float) -> Bool { !link && conf < 0.75 }

        // Band 1: verified direct relationships.
        for e in view.between(seed.id, id) where e.status == .verified {
            switch e.predicate {
            case .trackOn:
                let album = e.object
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: e.confidence, explanation: .init(.onAlbum, [subject(album)])))
            case .soundtrackOf:
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: e.confidence, explanation: .init(.soundtrackOfFilm, [subject(e.object)])))
            case .featuredIn:
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: e.confidence, explanation: .init(.featuredInFilm, [subject(e.object)])))
            case .alternateOf:
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: e.confidence, explanation: .init(.versionOf, [MusicRecSubject(id: seed.id, name: seed.name)])))
            case .memberOf:
                let group = e.object
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: e.confidence, explanation: .init(.groupMember, [subject(group)])))
            default:
                // A person credited on the seed (or the seed's own people when the candidate is one) is a direct, verified relation too.
                if id.kind.isAgent, MusicRecRoles.credit.contains(e.predicate) || e.predicate == .hasCast || e.predicate == .directedBy {
                    out.append(.init(band: .verifiedDirect, strength: 0.9, confidence: e.confidence,
                                     explanation: .init(e.predicate == .hasCast ? .inCastOf : .creditedOn, [MusicRecSubject(id: seed.id, name: seed.name)])))
                }
            }
        }
        for (album, a) in s.albums where a.verified {
            if let b = c.albums[album], b.verified, id.kind != .album, id.kind != .release, id != album {
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: min(a.confidence, b.confidence), explanation: .init(.sameAlbum, [subject(album)])))
            }
        }
        let albumish: Set<MusicEntityKind> = [.album, .release]
        if albumish.contains(seed.id.kind), albumish.contains(id.kind) {
            for (film, a) in s.films where a.verified { if let b = c.films[film], b.verified {
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: min(a.confidence, b.confidence), explanation: .init(.soundtrackOfFilm, [subject(film)])))
            } }
        }
        if !id.kind.isAgent {
            for (work, a) in s.works where a.verified { if let b = c.works[work], b.verified {
                out.append(.init(band: .verifiedDirect, strength: 1, confidence: min(a.confidence, b.confidence), explanation: .init(.versionOf, [MusicRecSubject(id: seed.id, name: seed.name)])))
            } }
        }

        // Band 2: shared creators (a music lead plus a different person who sang or wrote it; at least two people).
        let musicalRoles = MusicRecRoles.lead.union(MusicRecRoles.vocal).union(MusicRecRoles.words)
        let shared = Set(s.credits.keys).intersection(c.credits.keys).filter { !s.credits[$0]!.roles.union(c.credits[$0]!.roles).isDisjoint(with: musicalRoles) }
        func rolesOf(_ person: MusicEntityID) -> Set<MusicRole> { s.credits[person]!.roles.union(c.credits[person]!.roles) }
        let leadSet = shared.filter { !rolesOf($0).isDisjoint(with: MusicRecRoles.lead) }
        let otherSet = shared.filter { !rolesOf($0).isDisjoint(with: MusicRecRoles.vocal.union(MusicRecRoles.words)) }
        if shared.count >= 2, leadSet.contains(where: { a in otherSet.contains { $0 != a } }) {
            func weight(_ f: MusicRecFacets, _ person: MusicEntityID) -> Double { f.credits[person]?.roles.map(MusicRecRoles.weight).max() ?? 0 }
            let allPeople = Set(s.credits.keys).union(c.credits.keys)
            let num = shared.reduce(0.0) { $0 + min(weight(s, $1), weight(c, $1)) }
            let den = allPeople.reduce(0.0) { $0 + max(weight(s, $1), weight(c, $1)) }
            let conf = shared.map { min(s.credits[$0]!.confidence, c.credits[$0]!.confidence) }.min() ?? 0
            let names = shared.sorted { weight(s, $0) != weight(s, $1) ? weight(s, $0) > weight(s, $1) : $0 < $1 }.prefix(3).map(subject)
            out.append(.init(band: .sharedCreators, strength: den > 0 ? min(1, num / den) : 0, confidence: conf, explanation: .init(.sharedCreators, Array(names))))
        }

        // Band 3: the same film or soundtrack, and cast overlap between films.
        let sharedFilms = Set(s.films.keys).intersection(c.films.keys)
        if let f = sharedFilms.sorted(by: { let av = s.films[$0]!.verified, bv = s.films[$1]!.verified; return av != bv ? av : $0 < $1 }).first {
            let a = s.films[f]!, b = c.films[f]!
            let conf = min(a.confidence, b.confidence)
            let seedIsAgent = seed.id.kind.isAgent
            let reason: MusicRecReason = id == f ? .featuredInFilm : (seedIsAgent && id.kind == .film ? .starring : .sameFilm)
            let subj: [MusicRecSubject] = reason == .starring ? [MusicRecSubject(id: seed.id, name: seed.name)] : [subject(f)]
            out.append(.init(band: .sharedFilm, strength: Double(conf), confidence: conf, explanation: .init(reason, subj, tentative: tentative(a.verified && b.verified, conf))))
        }
        if id.kind == .film || id.kind == .series || id.kind == .album || id.kind == .release, !s.cast.isEmpty, !c.cast.isEmpty {
            let overlap = Set(s.cast.keys).intersection(c.cast.keys).subtracting([seed.id])
            if !overlap.isEmpty {
                let top = overlap.sorted { (s.cast[$0] ?? 999, $0) < (s.cast[$1] ?? 999, $1) }.prefix(2).map(subject)
                out.append(.init(band: .sharedFilm, strength: min(1, Double(overlap.count) / 3), confidence: 0.9,
                                 explanation: .init(top.count == 1 ? .alsoStars : .sharedCast, Array(top))))
            }
        }

        // Band 4: collaborations (log-scaled by how many works they share).
        var collab: MusicRecCollaborator?
        func pick(_ person: MusicEntityID) -> MusicRecCollaborator? { seed.collaborators[person]?.first { $0.bridge != id && $0.bridge != seed.id } }
        if id.kind.isAgent { collab = pick(id) }
        else if let hit = c.credits.keys.sorted().compactMap({ pick($0) }).first { collab = hit }
        if let col = collab {
            let strength = min(1, log(1 + Double(col.count)) / log(7))
            out.append(.init(band: .collaboration, strength: strength, confidence: 0.85, explanation: .init(.collaboration, [subject(col.with), subject(col.bridge)])))
        }

        // Band 5: the same artist, composer, lyricist or director (the film's director only between films and soundtracks).
        if !id.kind.isAgent {
            let workScope = (seed.id.kind == .film || seed.id.kind == .album || seed.id.kind == .release || seed.id.kind == .series)
                && (id.kind == .film || id.kind == .album || id.kind == .release || id.kind == .series)
            let sharedOne = Set(s.credits.keys).intersection(c.credits.keys).filter { person in
                let roles = s.credits[person]!.roles.union(c.credits[person]!.roles)
                if roles.contains(.director) { return workScope }
                return roles.contains(where: { MusicRecRoles.lead.contains($0) || MusicRecRoles.vocal.contains($0) || MusicRecRoles.words.contains($0) })
            }
            if let best = sharedOne.max(by: { a, b in
                let wa = s.credits[a]!.roles.map(MusicRecRoles.weight).max()!, wb = s.credits[b]!.roles.map(MusicRecRoles.weight).max()!
                return wa != wb ? wa < wb : a > b
            }) {
                let roles = s.credits[best]!.roles
                let reason: MusicRecReason
                if seed.id.kind.isAgent { reason = .sameArtist }
                else if !roles.isDisjoint(with: [.musicDirector]) { reason = .sameMusicDirector }
                else if !roles.isDisjoint(with: [.composer, .arranger, .conductor]) { reason = .sameComposer }
                else if roles.contains(.singer) { reason = .sameSinger }
                else if !roles.isDisjoint(with: MusicRecRoles.words) { reason = .sameLyricist }
                else if roles.contains(.director) { reason = .sameDirector }
                else { reason = .sameArtist }
                let inherited = s.credits[best]!.inherited || c.credits[best]!.inherited
                let conf = min(s.credits[best]!.confidence, c.credits[best]!.confidence)
                out.append(.init(band: .sameArtist, strength: sameArtistStrength(year: c.year, popularity: view.snapshot(id), now: p.now) * (inherited ? 0.85 : 1), confidence: conf,
                                 explanation: .init(reason, [subject(best)], tentative: tentative(!inherited, conf))))
            }
        }

        // Band 6: same language and era.
        let langs = s.languages.intersection(c.languages)
        if !langs.isEmpty, let sy = s.year, let cy = c.year, abs(sy - cy) <= 20 {
            let key = langs.sorted().first { !$0.hasPrefix("id:") }
            let label = key.map { s.languageNames[$0] ?? c.languageNames[$0] ?? MusicRecLanguage.display($0) } ?? ""
            let decade = "\((sy / 10) * 10)s"
            out.append(.init(band: .languageEra, strength: max(0.05, 1 - Double(abs(sy - cy)) / 25), confidence: 0.8,
                             explanation: .init(.sameLanguageEra, [MusicRecSubject(name: label.isEmpty ? decade : decade + " " + label)])))
        }

        // Band 7: genre.
        let sharedGenres = Set(s.genres.keys).intersection(c.genres.keys)
        if !sharedGenres.isEmpty {
            let union = Set(s.genres.keys).union(c.genres.keys)
            let name = sharedGenres.compactMap { s.genres[$0] ?? c.genres[$0] }.filter { !$0.isEmpty }.sorted().first ?? ""
            out.append(.init(band: .genre, strength: Double(sharedGenres.count) / Double(max(1, union.count)), confidence: 0.7,
                             explanation: .init(.sameGenre, name.isEmpty ? [] : [MusicRecSubject(name: name)])))
        }

        // Band 8: the person's own listening (only with history, only when nothing stronger applies; the caller keeps the best band).
        if !p.affinity.isEmpty {
            let a = affinityParts(c, id: id, params: p)
            if a.total >= 0.15, let top = a.top {
                let film = !c.films.isEmpty && id.kind != .film
                let reason: MusicRecReason, subj: [MusicRecSubject]
                switch top.kind {
                case .composer: reason = .affinityComposer; subj = [subject(top.id!)]
                case .singer: reason = .affinitySinger; subj = [subject(top.id!)]
                case .film: reason = .affinityFilm; subj = [subject(top.id!)]
                case .language: reason = film ? .affinityLanguageFilm : .affinityLanguage; subj = [MusicRecSubject(name: MusicRecLanguage.display(top.key))]
                case .era: reason = .affinityEra; subj = [MusicRecSubject(name: "\(top.decade)s")]
                }
                out.append(.init(band: .affinity, strength: a.total, confidence: 0.8, explanation: .init(reason, subj)))
            }
        }

        // Band 9: broader, a language the candidate and the seed (or the person's history) share.
        if p.includeBroad || !p.affinity.isEmpty {
            let shareLang = s.languages.intersection(c.languages).filter { !$0.hasPrefix("id:") }
            let preferred = c.languages.intersection(p.preferredLanguages)
            if let k = (shareLang.sorted().first ?? preferred.sorted().first) {
                let pop = view.snapshot(id).flatMap { Double($0.attrs["popularity"] ?? $0.attrs["rank"] ?? "") }.map { min(1, max(0, $0 / 100)) } ?? 0.3
                out.append(.init(band: .broad, strength: pop, confidence: 0.6, explanation: .init(.broadLanguage, [MusicRecSubject(name: s.languageNames[k] ?? c.languageNames[k] ?? MusicRecLanguage.display(k))])))
            }
        }
        return out.sorted { $0.band != $1.band ? $0.band < $1.band : ($0.strength * Double($0.confidence)) > ($1.strength * Double($1.confidence)) }
    }

    /// Recency and popularity of a candidate for the same-artist band: 0...1.
    static func sameArtistStrength(year: Int?, popularity snap: MusicEntitySnapshot?, now: Date) -> Double {
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let recency = year.map { max(0, min(1, 1 - Double(thisYear - $0) / 80)) } ?? 0.4
        let pop = snap.flatMap { Double($0.attrs["popularity"] ?? "") }.map { min(1, max(0, $0 / 100)) } ?? 0.5
        return 0.5 * recency + 0.5 * pop
    }

    struct AffinityPart { enum Kind { case composer, singer, film, language, era }; var kind: Kind; var id: MusicEntityID?; var key: String; var decade: Int; var weight: Double }
    struct AffinityParts { var total: Double; var top: AffinityPart? }

    /// How much the device-local history favours a candidate, and the part that favours it most (for the explanation).
    static func affinityParts(_ c: MusicRecFacets, id: MusicEntityID, params p: MusicRecParams) -> AffinityParts {
        let v = p.affinity
        var parts: [AffinityPart] = []
        for x in c.composers { if let w = v.composer[x] { parts.append(.init(kind: .composer, id: x, key: "", decade: 0, weight: w)) } }
        for x in c.singers { if let w = v.singer[x] { parts.append(.init(kind: .singer, id: x, key: "", decade: 0, weight: w)) } }
        for x in c.films.keys { if let w = v.film[x] { parts.append(.init(kind: .film, id: x, key: "", decade: 0, weight: w)) } }
        for l in c.languages where !l.hasPrefix("id:") { if let w = v.language[l] { parts.append(.init(kind: .language, id: nil, key: l, decade: 0, weight: w)) } }
        if let y = c.year, let w = v.decade[(y / 10) * 10] { parts.append(.init(kind: .era, id: nil, key: "", decade: (y / 10) * 10, weight: w)) }
        let total = v.boost(recording: id, composers: c.composers, singers: c.singers, film: Array(c.films.keys), languages: c.languages, year: c.year)
        let top = parts.max { a, b in a.weight != b.weight ? a.weight < b.weight : (a.id?.rawValue ?? a.key) > (b.id?.rawValue ?? b.key) }
        return AffinityParts(total: total, top: top)
    }

    /// The boost (0...1) used to reorder items inside a band.
    static func affinityBoost(_ c: MusicRecFacets, id: MusicEntityID, params p: MusicRecParams) -> Double {
        p.affinity.isEmpty ? 0 : p.affinity.boost(recording: id, composers: c.composers, singers: c.singers, film: Array(c.films.keys), languages: c.languages, year: c.year)
    }
}
