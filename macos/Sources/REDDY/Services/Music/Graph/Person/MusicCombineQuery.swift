import Foundation

// "Songs composed by A, sung by B, written by C, in this language, in this decade": a query over what the graph already holds. It starts from the smallest list
// (a singer's, then a composer's, then a lyricist's songs), keeps the songs the other people are also credited on (a credit on the film or the album counts, as
// on the person pages), then applies the language and the decade. A song with no language or year recorded is not guessed at: it is counted and reported.

struct MusicCombineFilter: Equatable, Sendable {
    var composer: MusicEntityID?
    var singer: MusicEntityID?
    var lyricist: MusicEntityID?
    /// A two-letter language code as the graph stores it ("te", "hi").
    var language: String?
    /// The first year of the decade (1990).
    var decade: Int?
    /// The kind of music, as the song's documented genre tags say (devotional, folk, film score and so on).
    var kind: MusicSongKind?
    /// A raga, as the Wikipedia list of film songs based on ragas documents it for the song.
    var raga: String?

    var people: [MusicEntityID] { [singer, composer, lyricist].compactMap { $0 } }
    var isEmpty: Bool { people.isEmpty && language == nil && decade == nil && kind == nil && raga == nil }
    /// There must be someone to start from.
    var isRunnable: Bool { !people.isEmpty }
}

struct MusicCombineResult: Sendable, Equatable {
    /// Songs that match on what the graph states about the song itself.
    var songs: [MusicPersonEntry] = []
    /// Songs that match only because their film has the language or year asked for: possible matches, never mixed in with the verified ones.
    var possible: [MusicPersonEntry] = []
    /// Songs of the starting person that were looked at.
    var checked = 0
    var cut = false
    /// Songs left out only because they carry no language or no year.
    var withoutLanguage = 0
    var withoutYear = 0
    /// Songs left out only because no genre tag says what kind of music they are.
    var withoutKind = 0
    /// Songs left out only because the raga list says nothing about them.
    var withoutRaga = 0
    var isEmpty: Bool { songs.isEmpty && possible.isEmpty }
}

enum MusicCombineRules {
    enum RagaDecision: Equatable, Sendable { case match, other, unknown }

    /// Whether the ragas found for a song are the one asked for. No raga found is "unknown": the song is left out and counted, never guessed at.
    static func ragaDecision(found: [String], wanted: String) -> RagaDecision {
        if found.isEmpty { return .unknown }
        let want = MusicText.normalize(wanted)
        return found.contains { MusicText.normalize($0) == want } ? .match : .other
    }

    static func inDecade(_ year: Int?, _ decade: Int) -> Bool { year.map { $0 >= decade && $0 < decade + 10 } ?? false }

    /// One key for "te", "tel", "Telugu" and "telugu": the two-letter code.
    static func languageKey(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.count == 3 { return Locale.LanguageCode(t).identifier(.alpha2) ?? t }
        if t.count < 3 { return t }
        return MusicLanguageNames.code(forEnglishName: t.capitalized).map { String($0.prefix(2)).lowercased() } ?? t
    }

    /// The language of a song as the arbiter decides it: evidence about the song itself (its own language, a provider's hint) can verify it, the film's language
    /// is context only.
    static func languageDecision(song: MusicEntitySnapshot, filmLanguage: String?) -> MusicFieldDecision {
        var ev: [MusicFieldEvidence] = []
        if let l = song.lang, !l.isEmpty { ev.append(MusicFieldEvidence(value: languageKey(l), display: l, source: "graph", specificity: .recording)) }
        if let h = song.attrs["languageHint"], !h.isEmpty { ev.append(MusicFieldEvidence(value: languageKey(h), display: h, source: "provider", specificity: .recording, roleExplicit: false)) }
        if let fl = filmLanguage, !fl.isEmpty { ev.append(MusicFieldEvidence(value: languageKey(fl), display: fl, source: "film", specificity: .film, states: false)) }
        return MusicFieldArbiter.decide(field: .language, evidence: ev)
    }

    /// "te", "tel", "Telugu" and "telugu" all name one language: compared on the first two letters of the code, or the code of the full name.
    static func sameLanguage(_ stored: String?, _ wanted: String) -> Bool {
        guard let s = stored?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return false }
        let w = wanted.lowercased()
        if s == w || s.hasPrefix(w) || w.hasPrefix(s) && s.count >= 2 { return true }
        let named = Locale(identifier: "en").localizedString(forLanguageCode: w)?.lowercased()
        return named.map { s == $0 } ?? false
    }

    /// The film industry a language usually stands for. It is worked out from the language alone, so the screen says "by language": a film in two languages
    /// belongs to both, and Bengali cinema is not "Tollywood" everywhere.
    static func industry(forLanguage code: String) -> String? { MusicFilmIndustry.name(forLanguageCode: code) }

    /// The decades that a list of years covers, newest first.
    static func decades(from years: [Int]) -> [Int] { Array(Set(years.map { $0 / 10 * 10 })).sorted(by: >) }
}

enum MusicCombine {
    /// Runs the filter against the graph.
    static func run(_ f: MusicCombineFilter, store: any MusicGraphStoring, ragas: MusicRagaIndex? = nil, artistNames: [String] = []) async -> MusicCombineResult {
        guard let anchor = f.singer ?? f.composer ?? f.lyricist else { return MusicCombineResult() }
        let view: MusicPersonView = f.singer != nil ? .singer : (f.composer != nil ? .composer : .lyricist)
        return await MusicPersonReader(store: store, person: anchor).combine(f, anchorView: view, ragas: ragas, artistNames: artistNames)
    }
}

extension MusicPersonReader {
    /// The reader's own person is the one to start from.
    func combine(_ f: MusicCombineFilter, anchorView: MusicPersonView, ragas: MusicRagaIndex? = nil, artistNames: [String] = []) async -> MusicCombineResult {
        let songs = await works(view: anchorView, kinds: Self.songKinds, cap: Self.grid)
        var result = MusicCombineResult(checked: songs.count, cut: truncated)
        var keep = Set(songs.map(\.snap.id))
        let pairs: [(MusicEntityID?, MusicPersonView)] = [(f.composer, MusicPersonView.composer), (f.lyricist, MusicPersonView.lyricist), (f.singer, MusicPersonView.singer)]
        for (maybe, view) in pairs {
            // The person's own view is what `songs` already is. The same person picked in a second slot still has to be credited in that role (a singer who also composed).
            guard let who = maybe, !(who == person && view == anchorView) else { continue }
            if who == person {
                // The reader never lists its own person as an agent on a work, so the second role is read from the person's own credits.
                let own = await works(view: view, kinds: Self.songKinds, cap: Self.grid)
                keep.formIntersection(own.map(\.snap.id))
                continue
            }
            let seen = await observations(of: Array(keep), roles: view.roles, releaseLevel: true, filmLevel: true)
            keep = Set(seen.filter { $0.agent == who }.map(\.work))
        }
        for (snap, edge) in songs where keep.contains(snap.id) {
            var year = snap.year, lang = snap.lang
            var filmTitle: String?, filmLang: String?, filmID: MusicEntityID?
            if let link = await filmLink(of: snap.id), let film = await snapshot(link.film) {
                year = year ?? film.year; lang = lang ?? film.lang; filmTitle = film.name; filmLang = film.lang; filmID = film.id
            }
            // The song's language is decided by the arbiter from evidence about the song itself. The film's language is context: it can make a song a possible match,
            // never a verified one.
            var languageBorrowed = false
            if let want = f.language {
                let d = MusicCombineRules.languageDecision(song: snap, filmLanguage: filmLang)
                MusicFieldDecisionStore.shared.record(snap.id, d)
                let wantKey = MusicCombineRules.languageKey(want)
                if d.winners.contains(wantKey) {
                    // verified by the song's own evidence
                } else if d.status == .contextOnly, d.candidates.contains(where: { $0.value == wantKey }) {
                    languageBorrowed = true
                } else {
                    if d.status == .empty { result.withoutLanguage += 1 }
                    continue
                }
            }
            var yearBorrowed = false
            if let dec = f.decade {
                guard MusicCombineRules.inDecade(year, dec) else { if year == nil { result.withoutYear += 1 }; continue }
                yearBorrowed = snap.year == nil
            }
            if let want = f.kind {
                var tags: [String] = []
                for g in await outgoing(snap.id) where g.predicate == .hasGenre { if let s = await snapshot(g.object) { tags.append(s.name) } }
                if tags.isEmpty { result.withoutKind += 1; continue }
                guard MusicSongKind.kinds(fromTags: tags).contains(want) else { continue }
            }
            if let want = f.raga {
                guard let ragas else { result.withoutRaga += 1; continue }
                let found = ragas.ragas(title: snap.name, film: filmTitle, artists: artistNames)
                switch MusicCombineRules.ragaDecision(found: found, wanted: want) {
                case .unknown: result.withoutRaga += 1; continue
                case .other: continue
                case .match: break
                }
            }
            var e = entry(snap, edge: edge)
            e.year = year; e.lang = lang; e.filmTitle = filmTitle; e.filmID = filmID
            if languageBorrowed || yearBorrowed { result.possible.append(e) } else { result.songs.append(e) }
        }
        let order: (MusicPersonEntry, MusicPersonEntry) -> Bool = { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) < ($1.year ?? 0) : $0.name < $1.name }
        result.songs.sort(by: order); result.possible.sort(by: order)
        result.cut = truncated
        MusicFieldDecisionStore.shared.flush()
        return result
    }
}
