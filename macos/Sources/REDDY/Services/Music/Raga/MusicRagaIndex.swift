import Foundation

/// Which ragas a song, a composer or a singer is documented with, looked up in the Wikipedia list of film songs based on ragas. Pure: it is handed the rows. A song
/// matches only on its title together with something else that agrees (its film, or one of its artists), never on a title alone, so a common title cannot borrow another
/// film's raga.
struct MusicRagaIndex: Sendable {
    private let byTitle: [String: [MusicRagaSong]]
    private let all: [MusicRagaSong]

    init(_ songs: [MusicRagaSong]) {
        all = songs
        var map: [String: [MusicRagaSong]] = [:]
        for s in songs { map[Self.key(s.title), default: []].append(s) }
        byTitle = map
    }

    static func key(_ s: String) -> String { MusicText.normalize(s) }

    /// A name without the parenthetical the table adds ("Roshan (music director)").
    static func cleanName(_ s: String) -> String {
        let cut = s.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
        return key(cut)
    }

    /// The ragas documented for this song, in the order the table gives them, or none.
    func ragas(title: String, film: String?, artists: [String]) -> [String] {
        guard let candidates = byTitle[Self.key(title)], !candidates.isEmpty else { return [] }
        let wantFilm = film.map(Self.key) ?? ""
        let who = Set(artists.map(Self.cleanName).filter { !$0.isEmpty })
        struct Scored { var song: MusicRagaSong; var score: Int }
        var scored: [Scored] = []
        for c in candidates {
            var score = 0
            let f = Self.key(c.film)
            if !wantFilm.isEmpty, !f.isEmpty { if f == wantFilm { score += 2 } else if f.contains(wantFilm) || wantFilm.contains(f) { score += 1 } }
            let people = Set(([c.composer] + c.singers).map(Self.cleanName).filter { !$0.isEmpty })
            if !who.isDisjoint(with: people) { score += 1 }
            if score > 0 { scored.append(Scored(song: c, score: score)) }
        }
        guard let best = scored.map(\.score).max() else { return [] }
        let top = scored.filter { $0.score == best }
        // Two different songs tie with different ragas: nothing is claimed.
        let sets = Set(top.map { $0.song.ragas.joined(separator: "|") })
        return sets.count == 1 ? top[0].song.ragas : []
    }

    /// The ragas of a composer's or singer's documented songs, the most used first.
    func ragas(ofPerson name: String, limit: Int = 12) -> [(raga: String, count: Int)] {
        let want = Self.cleanName(name)
        guard !want.isEmpty else { return [] }
        var counts: [String: (name: String, n: Int)] = [:]
        for s in all {
            let people = ([s.composer] + s.singers).map(Self.cleanName)
            guard people.contains(want) else { continue }
            for r in s.ragas { let k = Self.key(r); counts[k, default: (r, 0)].n += 1 }
        }
        var rows: [(raga: String, count: Int)] = []
        for v in counts.values { rows.append((v.name, v.n)) }
        rows.sort { (a: (raga: String, count: Int), b: (raga: String, count: Int)) -> Bool in a.count != b.count ? a.count > b.count : a.raga < b.raga }
        return Array(rows.prefix(limit))
    }

    /// Every raga with how many documented songs it has, for a picker.
    func allRagas(limit: Int = 80) -> [(raga: String, count: Int)] {
        var counts: [String: (name: String, n: Int)] = [:]
        for s in all { for r in s.ragas { counts[Self.key(r), default: (r, 0)].n += 1 } }
        var rows: [(raga: String, count: Int)] = []
        for v in counts.values { rows.append((v.name, v.n)) }
        rows.sort { (a: (raga: String, count: Int), b: (raga: String, count: Int)) -> Bool in a.count != b.count ? a.count > b.count : a.raga < b.raga }
        return Array(rows.prefix(limit))
    }

    func isRaga(_ ragas: [String], _ wanted: String) -> Bool { ragas.contains { Self.key($0) == Self.key(wanted) } }
}

/// A request to open the Ragas window on one raga.
struct MusicRagaRequest: Identifiable, Equatable, Sendable { var raga: String; var id: String { raga } }
