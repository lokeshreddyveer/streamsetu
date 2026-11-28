import Foundation

// Pure values and rules for the film page's fuller facts: the language switcher, the extra crew departments TMDB lists, the film's official videos,
// the About facts, the soundtrack summary line and the crew search. A value in, a value out: no store, no player, no network, no clock.

// MARK: language switcher

/// Which language edition of the film's music the Songs and Albums tabs show. A dubbed edition is a soundtrack album that carries a dub language; the film itself is unchanged.
enum MusicFilmLanguageFilter: Hashable, Sendable {
    /// The film's own music and every dubbed edition.
    case all
    /// The film's own music only.
    case original
    /// One dubbed edition, by its language code.
    case dub(String)

    /// What page memory keeps for the choice (nil for the default), so Back lands on the same language.
    var memoryName: String? {
        switch self {
        case .all: nil
        case .original: "original"
        case .dub(let l): "dub:" + l
        }
    }
    init?(memoryName: String) {
        if memoryName == "original" { self = .original }
        else if memoryName.hasPrefix("dub:"), memoryName.count > 4 { self = .dub(String(memoryName.dropFirst(4))) }
        else { return nil }
    }

    func matches(dubLanguage: String?) -> Bool {
        switch self {
        case .all: true
        case .original: dubLanguage == nil
        case .dub(let l): dubLanguage?.lowercased() == l.lowercased()
        }
    }

    /// The chips of the switcher: nothing when the film has no dubbed edition (there is nothing to switch), else All, Original and one chip per dub language
    /// in the order the dubs first appear.
    static func options(dubLanguages: [String?]) -> [MusicFilmLanguageFilter] {
        var seen = Set<String>()
        var dubs: [MusicFilmLanguageFilter] = []
        for case let l? in dubLanguages where !l.isEmpty && seen.insert(l.lowercased()).inserted { dubs.append(.dub(l)) }
        return dubs.isEmpty ? [] : [.all, .original] + dubs
    }
}

// MARK: crew departments from TMDB

/// The film-crew departments the film page lists beyond the roles the graph already names. Each is read from TMDB's `credits.crew` (a job TMDB states, never guessed from a name).
enum MusicFilmDepartment: String, Codable, Sendable, CaseIterable, Hashable {
    case writing, camera, editing, productionDesign, sound, costume, visualEffects, choreography

    /// The nearest role the graph has, used only to place the group in its heading and to avoid listing a person twice; departments the graph has no role for use `.producer`
    /// as a neutral placeholder (a group with a department never opens a person page on that role).
    var placeholderRole: MusicRole {
        switch self {
        case .writing: .screenwriter
        case .camera: .cinematographer
        case .editing: .editor
        default: .producer
        }
    }

    /// The department of a TMDB crew job, or nil for a job the page does not list (director, producer and the music jobs have their own rows).
    static func of(job: String) -> MusicFilmDepartment? {
        let j = job.lowercased().trimmingCharacters(in: .whitespaces)
        // "Soundtrack" and "Songs" are the credits of licensed songs (artists), never the film's sound crew.
        if j.contains("soundtrack") || j == "songs" || j == "song" { return nil }
        if j.contains("sound") || j.contains("foley") { return .sound }
        if j.contains("choreograph") { return .choreography }
        if j.contains("costume") { return .costume }
        if j.contains("visual effects") || j.contains("vfx") { return .visualEffects }
        if j.contains("production design") || j.contains("art direct") || j.contains("set decorat") { return .productionDesign }
        if j == "director of photography" || j.contains("cinematograph") { return .camera }
        if j == "editor" || j == "film editor" { return .editing }
        if ["screenplay", "writer", "story", "novel", "author", "dialogue", "screenstory", "script"].contains(j) { return .writing }
        return nil
    }
}

/// One crew credit of a department, as TMDB states it (its person id keeps two people of one name apart).
struct MusicFilmExtraCredit: Codable, Hashable, Sendable {
    var department: MusicFilmDepartment
    var job: String
    var tmdb: Int
    var name: String
}

enum MusicFilmExtraCrew {
    static let perDepartment = 6

    /// The listed departments of a `credits.crew` array, in TMDB's order, one entry per person and department, at most `perDepartment` each.
    static func credits(fromCrew crew: [[String: Any]]) -> [MusicFilmExtraCredit] {
        var out: [MusicFilmExtraCredit] = []
        var seen = Set<String>()
        var counts: [MusicFilmDepartment: Int] = [:]
        for c in crew {
            guard let job = (c["job"] as? String), let d = MusicFilmDepartment.of(job: job), let id = c["id"] as? Int,
                  let name = (c["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  (counts[d] ?? 0) < perDepartment, seen.insert(d.rawValue + "|" + String(id)).inserted else { continue }
            counts[d, default: 0] += 1
            out.append(MusicFilmExtraCredit(department: d, job: job, tmdb: id, name: name))
        }
        return out
    }

    static func encode(_ credits: [MusicFilmExtraCredit]) -> String? {
        guard !credits.isEmpty, let d = try? JSONEncoder().encode(credits) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func decode(_ text: String?) -> [MusicFilmExtraCredit] {
        guard let text, let d = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MusicFilmExtraCredit].self, from: d)) ?? []
    }
}

/// The heading a crew group sits under on the Crew tab.
enum MusicFilmCrewHeading: Int, Sendable, CaseIterable, Hashable {
    case directing, writing, production, camera, editing, art, sound, costume, visualEffects, choreography, music, other

    static func of(_ g: MusicFilmCrewItem) -> MusicFilmCrewHeading {
        if let d = g.department {
            switch d {
            case .writing: return .writing
            case .camera: return .camera
            case .editing: return .editing
            case .productionDesign: return .art
            case .sound: return .sound
            case .costume: return .costume
            case .visualEffects: return .visualEffects
            case .choreography: return .choreography
            }
        }
        switch g.role {
        case .director: return .directing
        case .screenwriter, .writer: return .writing
        case .producer: return .production
        case .cinematographer: return .camera
        case .editor: return .editing
        case .musicDirector, .composer, .arranger, .lyricist, .conductor, .singer, .instrumentalist, .performer: return .music
        default: return .other
        }
    }

    /// The groups in heading order (the sort is stable, so the order inside a heading is kept).
    static func ordered(_ groups: [MusicFilmCrewItem]) -> [MusicFilmCrewItem] {
        groups.enumerated().sorted { a, b in
            let x = of(a.element).rawValue, y = of(b.element).rawValue
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
}

/// The search field of the Crew tab: a group stays when its label matches (with all its people), else only the people whose names match stay.
enum MusicFilmCrewSearch {
    static func filter(_ groups: [MusicFilmCrewItem], query: String, label: (MusicFilmCrewItem) -> String) -> [MusicFilmCrewItem] {
        let q = MusicGraphText.latin(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            if MusicGraphText.latin(label(g)).contains(q) { return g }
            let people = g.people.filter { MusicGraphText.latin($0.name).contains(q) || MusicGraphText.latin($0.job ?? "").contains(q) }
            if people.isEmpty { return nil }
            var kept = g; kept.people = people
            return kept
        }
    }
}

// MARK: official videos

/// The kinds of TMDB video the page lists. The order is the order they are shown in.
enum MusicFilmVideoKind: String, Codable, Sendable, CaseIterable, Hashable {
    case trailer, teaser, clip, featurette, behindTheScenes

    /// TMDB's `type` words ("Trailer", "Teaser", "Clip", "Featurette", "Behind the Scenes"); other types (bloopers, opening credits) are not listed.
    static func of(tmdbType t: String) -> MusicFilmVideoKind? {
        switch t.lowercased() {
        case "trailer": .trailer
        case "teaser": .teaser
        case "clip": .clip
        case "featurette": .featurette
        case "behind the scenes": .behindTheScenes
        default: nil
        }
    }
}

/// One official video of the film. It is only ever a link that opens outside the app, never something the music player plays.
struct MusicFilmVideo: Codable, Hashable, Sendable, Identifiable {
    var key: String
    var name: String
    var kind: MusicFilmVideoKind
    var official: Bool
    var id: String { key }
    var url: URL? { URL(string: "https://www.youtube.com/watch?v=" + key) }
}

enum MusicFilmVideos {
    static let cap = 24

    /// The listed videos of a TMDB `videos.results` array: YouTube ones with a key, by kind, then official ones, then the film's own language, then TMDB's order.
    static func parse(results: [[String: Any]], originalLanguage: String?) -> [MusicFilmVideo] {
        var seen = Set<String>()
        var rows: [(video: MusicFilmVideo, own: Bool, index: Int)] = []
        for (i, v) in results.enumerated() {
            guard (v["site"] as? String) == "YouTube", let key = v["key"] as? String, !key.isEmpty, let t = v["type"] as? String,
                  let kind = MusicFilmVideoKind.of(tmdbType: t), seen.insert(key).inserted else { continue }
            let name = (v["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            rows.append((MusicFilmVideo(key: key, name: name, kind: kind, official: (v["official"] as? Bool) == true), (v["iso_639_1"] as? String) == originalLanguage, i))
        }
        let kinds = MusicFilmVideoKind.allCases
        rows.sort { a, b in
            let x = kinds.firstIndex(of: a.video.kind) ?? 0, y = kinds.firstIndex(of: b.video.kind) ?? 0
            if x != y { return x < y }
            if a.video.official != b.video.official { return a.video.official }
            if a.own != b.own { return a.own }
            return a.index < b.index
        }
        return Array(rows.prefix(cap).map(\.video))
    }

    static func encode(_ videos: [MusicFilmVideo]) -> String? {
        guard !videos.isEmpty, let d = try? JSONEncoder().encode(videos) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func decode(_ text: String?) -> [MusicFilmVideo] {
        guard let text, let d = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MusicFilmVideo].self, from: d)) ?? []
    }

    /// The videos of one kind, in order.
    static func of(_ kind: MusicFilmVideoKind, in videos: [MusicFilmVideo]) -> [MusicFilmVideo] { videos.filter { $0.kind == kind } }
}

// MARK: About facts

enum MusicFilmAboutFacts {
    /// TMDB reports 0 for a budget or revenue it does not know: only a figure above zero is a fact.
    static func money(_ text: String?) -> Int? {
        guard let text, let n = Int(text), n > 0 else { return nil }
        return n
    }

    /// A `|`-joined list from the film's stored facts, without blanks or repeats.
    static func list(_ text: String?) -> [String] {
        var seen = Set<String>()
        return (text ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The names of TMDB's array of objects, by key, joined with `|` (a name that holds the separator is dropped, so the list always splits back the same).
    static func names(_ array: Any?, key: String) -> String? {
        let n = ((array as? [[String: Any]]) ?? []).compactMap { ($0[key] as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("|") }
        return n.isEmpty ? nil : n.joined(separator: "|")
    }

    /// The country that places the film in an industry: India when it is among the production countries, else the first one listed (so a Hindi film made in the UK and
    /// France is not called Bollywood), else unknown when TMDB lists none.
    static func industryCountry(_ countries: [String]) -> String? { countries.contains("IN") ? "IN" : countries.first }
}

// MARK: soundtrack summary

/// "12 songs, 3 albums, 1 h 4 min": what the film's own music holds, counted from the songs and albums the page has already read.
struct MusicFilmSoundtrackSummary: Equatable, Sendable {
    var songs: Int
    var albums: Int
    var durationMs: Int

    /// Only the film's own (original-language) songs and albums count; a dub is the same music again. Nil when there are no songs.
    static func make(songs: [MusicFilmSongItem], albums: [MusicFilmAlbumItem]) -> MusicFilmSoundtrackSummary? {
        let own = MusicFilmSongRules.uniqueRecordings(songs.filter { $0.dubLanguage == nil })
        guard !own.isEmpty else { return nil }
        return MusicFilmSoundtrackSummary(songs: own.count, albums: albums.filter { $0.dubLanguage == nil }.count, durationMs: own.compactMap(\.durationMs).reduce(0, +))
    }

    var minutes: Int { durationMs / 60_000 }
}
