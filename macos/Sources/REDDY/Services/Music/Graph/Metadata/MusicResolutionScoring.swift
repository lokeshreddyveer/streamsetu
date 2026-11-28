import Foundation

/// The pure scoring of the identity pipeline (section 3.4): titles, performers, durations, years and credits become a score and a list of signals.
/// Unknown signals are left out and the rest renormalised, so a track with no film hint is not punished for it; too few known signals cap the score.
enum MusicResolutionScoring {
    static let matcherVersion = 1

    struct Scored: Sendable, Equatable {
        var score: Float
        var signals: [MusicMergeRule.Signal]
        var evidence: [String]
        var blockers: Set<MusicMergeRule.Blocker>
        var decision: MusicMergeRule.Decision {
            MusicMergeRule.decide(.init(kind: kind, sharedStrongID: false, signals: signals, blockers: blockers))
        }
        var kind: MusicEntityKind
        static func == (a: Scored, b: Scored) -> Bool { a.score == b.score && a.evidence == b.evidence }
    }

    // MARK: text

    private static let versionWords = ["remastered", "remaster", "original motion picture soundtrack", "original soundtrack", "motion picture soundtrack", "soundtrack", "ost", "official video",
                                       "lyric video", "audio", "from", "version", "deluxe edition", "full song", "video song"]

    /// A title without its decoration: `(From "X")`, `- Remastered 2011`, `(Original Motion Picture Soundtrack)`, brackets.
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"").replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        if let r = t.range(of: #"\s[-–—]\s.*$"#, options: .regularExpression) { t.removeSubrange(r) }
        for w in versionWords where w.contains(" ") { t = t.replacingOccurrences(of: w, with: " ", options: .caseInsensitive) }
        return t.split(whereSeparator: { $0 == " " }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sim(_ a: String, _ b: String) -> Float {
        let x = cleanTitle(a), y = cleanTitle(b)
        if x.isEmpty || y.isEmpty { return 0 }
        return MusicTransliterationKey.similarity(x, y)
    }

    static func bestSim(_ a: String, among names: [String]) -> Float { names.map { sim(a, $0) }.max() ?? 0 }

    /// Names that match any of the others at 0.9 or better.
    static func nameOverlap(_ a: [String], _ b: [String]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let hits = a.filter { n in b.contains { MusicTransliterationKey.similarity(n, $0) >= 0.9 } }.count
        return Float(hits) / Float(min(a.count, b.count))
    }

    private static func combine(_ parts: [(w: Float, s: Float, fam: MusicMergeRule.Family, tag: String)], kind: MusicEntityKind, blockers: Set<MusicMergeRule.Blocker>) -> Scored {
        let known = parts.reduce(Float(0)) { $0 + $1.w }
        var score = known > 0 ? parts.reduce(Float(0)) { $0 + $1.w * $1.s } / known : 0
        if known < 0.6 { score *= 0.9 }
        let signals = parts.filter { $0.s >= 0.5 }.map { MusicMergeRule.Signal($0.fam, $0.s) }
        let evidence = parts.filter { $0.s >= 0.5 }.map(\.tag)
        return Scored(score: score, signals: signals, evidence: evidence, blockers: blockers, kind: kind)
    }

    // MARK: recording (title 0.35, performer 0.25, duration 0.15, release/film hint 0.10, year 0.10, language 0.05)

    static func recording(title: String, artists: [String], durationMs: Int?, year: Int?, hint: String?, language: String?,
                          candidate c: MusicEntityDraft) -> Scored {
        var parts: [(w: Float, s: Float, fam: MusicMergeRule.Family, tag: String)] = []
        parts.append((0.35, sim(title, c.name), .name, "title"))
        let candArtists = (c.attrs["artists"] ?? "").split(separator: "|").map(String.init)
        if !artists.isEmpty, !candArtists.isEmpty { parts.append((0.25, nameOverlap(artists, candArtists) > 0 ? 1 : 0, .creditOverlap, "performer")) }
        if let a = durationMs, let b = c.durationMs, a > 0, b > 0 {
            let d = abs(a - b)
            parts.append((0.15, d <= 5_000 ? 1 : (d <= 10_000 ? 0.5 : 0), .duration, "duration"))
        }
        if let h = hint, let rel = c.attrs["releases"]?.split(separator: "|").map(String.init), !rel.isEmpty { parts.append((0.10, bestSim(h, among: rel) >= 0.85 ? 1 : 0, .workOverlap, "film-hint")) }
        if let y = year, let cy = c.year { parts.append((0.10, abs(y - cy) <= 1 ? 1 : 0, .date, "year")) }
        var blockers: Set<MusicMergeRule.Blocker> = []
        if let a = durationMs, let b = c.durationMs, a > 0, b > 0, Double(abs(a - b)) / Double(max(a, b)) > 0.25 { blockers.insert(.durationApart) }
        return combine(parts, kind: .recording, blockers: blockers)
    }

    // MARK: album (title 0.35, composer/artist 0.25, year 0.10, tracklist overlap 0.25)

    static func album(title: String, artists: [String], year: Int?, trackTitles: [String], candidate c: MusicEntityDraft, candidateTracks: [String]?) -> Scored {
        var parts: [(w: Float, s: Float, fam: MusicMergeRule.Family, tag: String)] = []
        parts.append((0.35, sim(title, c.name), .name, "title"))
        let candArtists = (c.attrs["artists"] ?? "").split(separator: "|").map(String.init)
        if !artists.isEmpty, !candArtists.isEmpty { parts.append((0.25, nameOverlap(artists, candArtists) > 0 ? 1 : 0, .creditOverlap, "composer")) }
        if let y = year, let cy = c.year { parts.append((0.10, abs(y - cy) <= 1 ? 1 : 0, .date, "year")) }
        if let ct = candidateTracks, !ct.isEmpty, !trackTitles.isEmpty {
            let hit = trackTitles.filter { t in ct.contains { sim(t, $0) >= 0.9 } }.count
            parts.append((0.25, Float(hit) / Float(min(trackTitles.count, ct.count)), .workOverlap, "tracklist"))
        }
        return combine(parts, kind: .album, blockers: [])
    }

    // MARK: film (title 0.5, composer 0.3, language 0.1, year 0.1; cast overlap as a further signal)

    struct FilmFacts: Sendable {
        var names: [String]
        var year: Int?
        var language: String?
        var composers: [String]
        var cast: [String]
        var dubLanguages: [String] = []
    }

    struct FilmHint: Sendable {
        var title: String
        var year: Int?
        /// A year read from a reissue date is not a film year: it never blocks.
        var yearTrusted: Bool
        var language: String?
        var composers: [String]
        var starring: [String]
    }

    static func film(hint h: FilmHint, facts f: FilmFacts) -> Scored {
        var parts: [(w: Float, s: Float, fam: MusicMergeRule.Family, tag: String)] = []
        parts.append((0.5, bestSim(h.title, among: f.names), .name, "title"))
        if !h.composers.isEmpty, !f.composers.isEmpty { parts.append((0.3, nameOverlap(h.composers, f.composers) > 0 ? 1 : 0, .creditOverlap, "composer")) }
        if let hl = h.language, let fl = f.language {
            let dub = f.dubLanguages.contains(hl)
            parts.append((0.1, hl == fl ? 1 : (dub ? 0.5 : 0), .externalIDAdjacency, dub && hl != fl ? "dub-language" : "language"))
        }
        var blockers: Set<MusicMergeRule.Blocker> = []
        if let hy = h.year, let fy = f.year {
            parts.append((0.1, abs(hy - fy) <= 1 ? 1 : 0, .date, "year"))
            if h.yearTrusted, abs(hy - fy) > 1 { blockers.insert(.filmYearsApart) }
        }
        if !h.starring.isEmpty, !f.cast.isEmpty { let o = nameOverlap(h.starring, f.cast); if o > 0 { parts.append((0.1, min(1, o * 2), .workOverlap, "cast")) } }
        return combine(parts, kind: .film, blockers: blockers)
    }

    // MARK: people

    /// Two people with the same name are the same only through credits and works they share; the name only gates the question.
    static func person(nameSimilarity: Float, sharedRecording: Bool, sharedRelease: Bool, yearA: Int?, yearB: Int?) -> MusicMergeRule.Evidence {
        var e = MusicMergeRule.Evidence(kind: .person)
        guard nameSimilarity >= 0.9 else { return e }
        e.signals = [.init(.name, nameSimilarity)]
        if sharedRecording { e.signals.append(.init(.creditOverlap, 0.9)) }
        if sharedRelease { e.signals.append(.init(.workOverlap, 0.9)) }
        e.blockers = MusicMergeRule.blockers(kind: .person, strongIDsA: [], strongIDsB: [], yearA: yearA, yearB: yearB, durationMsA: nil, durationMsB: nil)
        return e
    }
}
