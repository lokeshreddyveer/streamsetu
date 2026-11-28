import Foundation

// The pure rules of the album page: which pills a release type gets, which edition badge a release earns, how two editions compare, how tracks are grouped
// by disc and viewed (filtered / sorted without ever touching the stored order), which tracks each playback mode plays, the person's own listening
// numbers and the export of a tracklist. Plain Sendable values; no view, no store, no network. Words the person reads are made by the views.

// MARK: - Pills

enum MusicAlbumPill: String, CaseIterable, Hashable, Sendable {
    case overview, tracks, film, versions, credits, about, listening
}

enum MusicAlbumPillRules {
    /// What the page has, as facts (never as promises): a pill is offered only when its section has something to show.
    struct Facts: Sendable, Equatable {
        var subkind: String?
        var trackCount: Int
        var hasFilm = false
        var hasVersions = false
        var hasCredits = false
        var hasAbout = false
        var hasListening = false
        init(subkind: String?, trackCount: Int, hasFilm: Bool = false, hasVersions: Bool = false, hasCredits: Bool = false, hasAbout: Bool = false, hasListening: Bool = false) {
            self.subkind = subkind; self.trackCount = trackCount; self.hasFilm = hasFilm; self.hasVersions = hasVersions
            self.hasCredits = hasCredits; self.hasAbout = hasAbout; self.hasListening = hasListening
        }
    }

    /// A single with one track gets no pills at all (the page is the page). Everything else gets Overview and Tracks, then only the pills with data.
    static func pills(_ f: Facts) -> [MusicAlbumPill] {
        if f.subkind == MusicAlbumSubkind.single.rawValue, f.trackCount <= 1 { return [] }
        var out: [MusicAlbumPill] = [.overview]
        if f.trackCount > 0 { out.append(.tracks) }
        if f.hasFilm { out.append(.film) }
        if f.hasVersions { out.append(.versions) }
        if f.hasCredits { out.append(.credits) }
        if f.hasAbout { out.append(.about) }
        if f.hasListening { out.append(.listening) }
        return out
    }
}

// MARK: - Editions

/// What an edition is called. `language` carries the language name.
enum MusicAlbumEditionBadge: Hashable, Sendable {
    case original, standard, deluxe, extended, remastered, language(String)
}

/// The few facts of one release of an album that editions are told apart by.
struct MusicAlbumEditionFacts: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var year: Int?
    var trackCount: Int
    var durationMs: Int64
    /// The language of a documented dub / translated edition (from the graph's own relationship), nil otherwise.
    var dubLanguage: String?
    /// Words a source stated for the edition itself ("Remastered 2011"): the title, nothing else.
    var trackTitles: [String] = []
    init(id: String, title: String, year: Int? = nil, trackCount: Int = 0, durationMs: Int64 = 0, dubLanguage: String? = nil, trackTitles: [String] = []) {
        self.id = id; self.title = title; self.year = year; self.trackCount = trackCount; self.durationMs = durationMs; self.dubLanguage = dubLanguage; self.trackTitles = trackTitles
    }
}

enum MusicAlbumEditionRules {
    static let deluxeWords = ["deluxe", "expanded", "special edition", "collector s edition", "anniversary edition"]
    static let extendedWords = ["extended"]
    static let remasterWords = MusicFilmEditionRules.remasterWords

    /// The badge of `subject` among `siblings` (the other releases of the same album concept; never an album that merely shares a title).
    /// 1. A documented relationship (a dub / translated edge) names a language edition.
    /// 2. Title words are only a hint: "deluxe" / "extended" needs a second signal (more tracks than a sibling), "remastered" needs a later year than a sibling.
    /// 3. Otherwise: the earliest release of a family with more than one member is the original; a lone release is standard.
    static func badge(_ subject: MusicAlbumEditionFacts, siblings: [MusicAlbumEditionFacts]) -> MusicAlbumEditionBadge {
        if let l = subject.dubLanguage, !l.isEmpty { return .language(l) }
        let others = siblings.filter { $0.id != subject.id }
        let hasMoreTracks = others.contains { $0.trackCount > 0 && subject.trackCount > $0.trackCount }
        let isLater: Bool = {
            guard let y = subject.year else { return false }
            return others.contains { ($0.year ?? Int.max) < y }
        }()
        if MusicFilmEditionRules.hasWord(subject.title, in: remasterWords), isLater { return .remastered }
        if MusicFilmEditionRules.hasWord(subject.title, in: deluxeWords), hasMoreTracks { return .deluxe }
        if MusicFilmEditionRules.hasWord(subject.title, in: extendedWords), hasMoreTracks { return .extended }
        if !others.isEmpty {
            let earliest = others.allSatisfy { o in
                guard let y = subject.year else { return false }
                guard let oy = o.year else { return true }
                return y < oy
            }
            if earliest { return .original }
        }
        return .standard
    }
}

// MARK: - Comparison

struct MusicAlbumEditionComparison: Hashable, Sendable {
    var left: MusicAlbumEditionFacts
    var right: MusicAlbumEditionFacts
    var trackCountDiffers: Bool
    var durationDiffers: Bool
    var yearDiffers: Bool
    var languageDiffers: Bool
    /// Songs only the left / only the right edition lists (compared by folded title, so spelling and case do not make bonus tracks).
    var onlyLeft: [String]
    var onlyRight: [String]

    /// A title as a comparison key: lower case, letters and digits only. Accents are removed from Latin letters only: for Hindi and Telugu a vowel sign changes the
    /// word, so those characters (and signs on their own) are kept as they are.
    nonisolated static func fold(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            let latin = c.unicodeScalars.allSatisfy { $0.value < 0x250 || (0x300...0x36F).contains($0.value) }
            let piece = latin ? String(c).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) : String(c)
            for ch in piece where ch.isLetter || ch.isNumber || ch.unicodeScalars.contains(where: { [.spacingMark, .nonspacingMark, .enclosingMark].contains($0.properties.generalCategory) }) { out.append(ch) }
        }
        return out
    }

    static func compare(_ a: MusicAlbumEditionFacts, _ b: MusicAlbumEditionFacts) -> MusicAlbumEditionComparison {
        let fa = Set(a.trackTitles.map(fold)), fb = Set(b.trackTitles.map(fold))
        // A side whose songs are not known (an edition never opened) says nothing about the other: no song is "only" on the one that is known.
        let known = !fa.isEmpty && !fb.isEmpty
        let onlyA = known ? a.trackTitles.filter { !fb.contains(fold($0)) && !fold($0).isEmpty } : []
        let onlyB = known ? b.trackTitles.filter { !fa.contains(fold($0)) && !fold($0).isEmpty } : []
        return MusicAlbumEditionComparison(left: a, right: b, trackCountDiffers: a.trackCount != b.trackCount, durationDiffers: a.durationMs != b.durationMs,
                                           yearDiffers: a.year != b.year, languageDiffers: (a.dubLanguage ?? "") != (b.dubLanguage ?? ""), onlyLeft: onlyA, onlyRight: onlyB)
    }
}

// MARK: - Tracks: discs, view

struct MusicAlbumTrackItem: Hashable, Sendable, Identifiable {
    var id: String            // the provider track uid
    var title: String
    var artistLine: String
    var disc: Int?
    var number: Int
    var durationMs: Int64
    var isPlayable: Bool
}

struct MusicAlbumDiscGroup<Item: Hashable & Sendable>: Hashable, Sendable {
    var disc: Int?
    var items: [Item]
}

enum MusicAlbumTrackView {
    enum Sort: String, CaseIterable, Sendable { case releaseOrder, title, duration }
    enum Filter: String, CaseIterable, Sendable { case all, favourites, unplayed }

    /// The disc numbers a list carries. A song with no disc number counts as disc 1 (as the playback modes do), so its disc is always present.
    static func discNumbers(_ raw: [Int?]) -> [Int] {
        var set = Set(raw.compactMap { $0 })
        if raw.contains(where: { $0 == nil }) { set.insert(1) }
        return set.sorted()
    }

    /// Groups by disc number only when the items carry more than one; the items of a disc keep the order they came in, and discs run in number order.
    /// A song with no disc number belongs to disc 1, so it never disappears when the numbered discs start at 2.
    static func discs<Item: Hashable & Sendable>(_ items: [Item], disc: (Item) -> Int?) -> [MusicAlbumDiscGroup<Item>] {
        let numbers = discNumbers(items.map(disc))
        guard numbers.count > 1 else { return [MusicAlbumDiscGroup(disc: nil, items: items)] }
        return numbers.map { d in MusicAlbumDiscGroup(disc: d, items: items.filter { (disc($0) ?? 1) == d }) }
    }

    /// A VIEW of the tracks: a new array, the source is never reordered. `releaseOrder` returns the source order as given.
    static func view(_ items: [MusicAlbumTrackItem], query: String, sort: Sort, filter: Filter, liked: Set<String>, played: Set<String>) -> [MusicAlbumTrackItem] {
        var out = items
        switch filter {
        case .all: break
        case .favourites: out = out.filter { liked.contains($0.id) }
        case .unplayed: out = out.filter { !played.contains($0.id) }
        }
        let q = MusicAlbumEditionComparison.fold(query)
        if !q.isEmpty {
            out = out.filter { MusicAlbumEditionComparison.fold($0.title).contains(q) || MusicAlbumEditionComparison.fold($0.artistLine).contains(q) }
        }
        switch sort {
        case .releaseOrder: break
        case .title: out = out.enumerated().sorted { a, b in
            let c = a.element.title.localizedCaseInsensitiveCompare(b.element.title)
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending }.map(\.element)
        case .duration: out = out.enumerated().sorted { a, b in
            a.element.durationMs != b.element.durationMs ? a.element.durationMs > b.element.durationMs : a.offset < b.offset }.map(\.element)
        }
        return out
    }
}

// MARK: - Playback modes

enum MusicAlbumPlaybackMode: Hashable, Sendable {
    case sequence, shuffle, disc(Int), shuffleDisc(Int), fromTrack(String), favouritesOnly, unplayedOnly, continueAlbum(currentUID: String?)
}

struct MusicAlbumPlaybackPlan: Equatable, Sendable {
    var tracks: [MusicTrack]
    var startIndex: Int
    var shuffled: Bool
}

enum MusicAlbumPlayback {
    /// The songs of `tracks` that are not already coming up in the queue, so Continue album on an album that is already queued adds nothing twice.
    static func notQueued(_ tracks: [MusicTrack], upcoming: Set<String>) -> [MusicTrack] { tracks.filter { !upcoming.contains($0.uid) } }

    /// The songs after the one playing (album order), for Continue album while that song keeps playing. Empty when it is the last or not on the album.
    static func continuation(_ tracks: [MusicTrack], currentUID: String) -> [MusicTrack] {
        guard let i = tracks.firstIndex(where: { $0.uid == currentUID }) else { return [] }
        return Array(tracks[(i + 1)...])
    }

    /// Which tracks a mode plays and from where. The caller hands a plan to `hub.play` / `hub.playShuffled`: this never orders a shuffle itself.
    static func plan(_ mode: MusicAlbumPlaybackMode, tracks: [MusicTrack], liked: Set<String>, played: Set<String>) -> MusicAlbumPlaybackPlan? {
        func make(_ list: [MusicTrack], start: Int = 0, shuffled: Bool = false) -> MusicAlbumPlaybackPlan? {
            list.isEmpty ? nil : MusicAlbumPlaybackPlan(tracks: list, startIndex: start, shuffled: shuffled)
        }
        switch mode {
        case .sequence: return make(tracks)
        case .shuffle: return make(tracks, shuffled: true)
        case .disc(let d): return make(tracks.filter { ($0.discNumber ?? 1) == d })
        case .shuffleDisc(let d): return make(tracks.filter { ($0.discNumber ?? 1) == d }, shuffled: true)
        case .fromTrack(let uid): return tracks.firstIndex { $0.uid == uid }.flatMap { make(tracks, start: $0) }
        case .favouritesOnly: return make(tracks.filter { liked.contains($0.uid) })
        case .unplayedOnly: return make(tracks.filter { !played.contains($0.uid) })
        case .continueAlbum(let uid):
            guard let uid, let i = tracks.firstIndex(where: { $0.uid == uid }) else { return nil }
            return make(tracks, start: i)
        }
    }
}

// MARK: - Your listening

struct MusicAlbumListeningStats: Equatable, Sendable {
    var trackCount: Int
    var explored: Int
    var totalPlays: Int
    var favourites: Int
    var mostPlayed: (uid: String, plays: Int)?
    var firstListened: Date?
    var lastListened: Date?
    var unplayed: [String]
    /// Milliseconds of this album the person actually listened to (the counted plays only).
    var listenedMs: Int64 = 0

    static func == (a: Self, b: Self) -> Bool {
        a.trackCount == b.trackCount && a.explored == b.explored && a.totalPlays == b.totalPlays && a.favourites == b.favourites
            && a.mostPlayed?.uid == b.mostPlayed?.uid && a.mostPlayed?.plays == b.mostPlayed?.plays
            && a.firstListened == b.firstListened && a.lastListened == b.lastListened && a.unplayed == b.unplayed && a.listenedMs == b.listenedMs
    }

    var hasAny: Bool { totalPlays > 0 || favourites > 0 }
}

enum MusicAlbumListening {
    /// `trackUIDs` in album order. A play counts by the app's own rule (`HomeTaste.counts`). The most played track breaks ties by album order.
    static func stats(trackUIDs: [String], history: [PlayRecord], liked: Set<String>) -> MusicAlbumListeningStats {
        let wanted = Set(trackUIDs)
        var plays: [String: Int] = [:]
        var first: Date?, last: Date?
        var listened: Int64 = 0
        for r in history where wanted.contains(r.track.uid) && HomeTaste.counts(r) {
            plays[r.track.uid, default: 0] += 1
            listened += max(0, r.playedMs)
            if first == nil || r.at < first! { first = r.at }
            if last == nil || r.at > last! { last = r.at }
        }
        var best: (uid: String, plays: Int)?
        for uid in trackUIDs { if let n = plays[uid], n > (best?.plays ?? 0) { best = (uid, n) } }
        return MusicAlbumListeningStats(trackCount: trackUIDs.count, explored: trackUIDs.filter { plays[$0] != nil }.count, totalPlays: plays.values.reduce(0, +),
                                        favourites: trackUIDs.filter { liked.contains($0) }.count, mostPlayed: best, firstListened: first, lastListened: last,
                                        unplayed: trackUIDs.filter { plays[$0] == nil }, listenedMs: listened)
    }
}

// MARK: - Availability

enum MusicAlbumAvailability {
    /// "n of m": only when some, but not all, tracks are playable; nil when all are, or when nothing is known.
    static func partial(playable: Int, total: Int) -> (playable: Int, total: Int)? {
        guard total > 0, playable < total else { return nil }
        return (playable, total)
    }
}

// MARK: - Credit groups

enum MusicAlbumCreditGroup: Int, CaseIterable, Hashable, Sendable {
    case primary, featured, vocals, composition, songwriting, production, arrangement, instruments, conducting

    /// The group of a credit role. Roles of a film's crew (actor, director...) have no album group.
    static func of(_ role: MusicRole) -> MusicAlbumCreditGroup? {
        switch role {
        case .performer: .primary
        case .featured: .featured
        case .singer: .vocals
        case .composer, .musicDirector: .composition
        case .lyricist, .writer: .songwriting
        case .producer, .remixer: .production
        case .arranger: .arrangement
        case .instrumentalist: .instruments
        case .conductor: .conducting
        default: nil
        }
    }
}

// MARK: - Export

enum MusicAlbumExport {
    static func plainText(title: String, items: [MusicAlbumTrackItem]) -> String {
        var lines = [title]
        for i in items { lines.append("\(i.disc.map { "\($0)-" } ?? "")\(i.number). \(i.title)\(i.artistLine.isEmpty ? "" : " - \(i.artistLine)")") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csv(items: [MusicAlbumTrackItem]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["disc,number,title,artists,duration_seconds"]
        for i in items { rows.append([String(i.disc ?? 1), String(i.number), q(i.title), q(i.artistLine), String(i.durationMs / 1000)].joined(separator: ",")) }
        return rows.joined(separator: "\n") + "\n"
    }
}

// MARK: - Personal choices (rating, notes, tags)

/// The rules of the person's own album notes. Local only; nothing here comes from a source.
enum MusicAlbumPersonal {
    static let maxRating = 5
    static let maxTags = 12
    static let maxTagLength = 32
    static let maxNoteLength = 4_000

    /// A rating is 1 to 5; anything else (0, negative) means "no rating".
    static func clampRating(_ n: Int) -> Int? { n >= 1 ? min(n, maxRating) : nil }

    /// Tags from one line of text split at commas or semicolons: trimmed, no empties, no repeats (case and accents folded), each cut to a sensible length.
    static func parseTags(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let t = String(part.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTagLength))
            let k = MusicAlbumEditionComparison.fold(t)
            guard !t.isEmpty, !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(t)
            if out.count >= maxTags { break }
        }
        return out
    }

    static func clampNote(_ text: String) -> String { String(text.prefix(maxNoteLength)) }
}

// MARK: - Disc totals

extension MusicAlbumTrackView {
    /// The total length of a disc's songs in milliseconds (songs with no length count as 0).
    static func totalDurationMs(_ durations: [Int64]) -> Int64 { durations.reduce(0) { $0 + max(0, $1) } }
}

// MARK: - Artwork gallery (Cover Art Archive release index)

/// What a picture of the release shows.
enum MusicAlbumArtKind: Int, Hashable, Sendable, CaseIterable { case front = 0, back, booklet, medium, other }

struct MusicAlbumArtImage: Hashable, Sendable, Identifiable {
    var id: String
    var kind: MusicAlbumArtKind
    /// The large version (1200 px when the archive has it, else the original), loaded only when the picture is open in the viewer.
    var full: String
    /// A small version for the strip.
    var thumb: String
}

enum MusicAlbumArtIndex {
    /// Reads the JSON index of a release (`images` with `types`, `image`, `thumbnails`, `approved`). Unapproved pictures are skipped; the order is
    /// front, back, booklet, medium, then the rest, each group in the archive's own order. Addresses are made https.
    static func parse(_ data: Data) -> [MusicAlbumArtImage] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let images = root["images"] as? [[String: Any]] else { return [] }
        var out: [MusicAlbumArtImage] = []
        var seen = Set<String>()
        for (i, img) in images.enumerated() {
            if let ok = img["approved"] as? Bool, !ok { continue }
            guard let original = img["image"] as? String, !original.isEmpty else { continue }
            let thumbs = img["thumbnails"] as? [String: Any] ?? [:]
            func t(_ k: String) -> String? { (thumbs[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let full = https(t("1200") ?? original)
            let small = https(t("500") ?? t("large") ?? t("250") ?? t("small") ?? original)
            let id: String = {
                if let s = img["id"] as? String, !s.isEmpty { return s }
                if let n = img["id"] as? Int { return String(n) }
                return "art-\(i)"
            }()
            guard seen.insert(id).inserted else { continue }
            let types = (img["types"] as? [String] ?? []).map { $0.lowercased() }
            out.append(MusicAlbumArtImage(id: id, kind: kind(types: types, front: img["front"] as? Bool ?? false, back: img["back"] as? Bool ?? false), full: full, thumb: small))
        }
        return out.enumerated().sorted { a, b in
            a.element.kind != b.element.kind ? a.element.kind.rawValue < b.element.kind.rawValue : a.offset < b.offset
        }.map(\.element)
    }

    static func kind(types: [String], front: Bool, back: Bool) -> MusicAlbumArtKind {
        if front || types.contains("front") { return .front }
        if back || types.contains("back") { return .back }
        if types.contains("booklet") { return .booklet }
        if types.contains("medium") { return .medium }
        return .other
    }

    static func https(_ url: String) -> String { url.hasPrefix("http://") ? "https://" + url.dropFirst(7) : url }

    /// The index addresses to try, release first (its own pictures), then the release group.
    static func indexAddresses(release: String?, releaseGroup: String?) -> [String] {
        var out: [String] = []
        if let r = release, !r.isEmpty { out.append("https://coverartarchive.org/release/\(r)") }
        if let g = releaseGroup, !g.isEmpty { out.append("https://coverartarchive.org/release-group/\(g)") }
        return out
    }
}


// MARK: - Songs load

enum MusicAlbumPageLogic {
    /// "No source holds this album" (as opposed to an empty answer from a source): nothing loaded, no error, and no switched-on source could be asked.
    nonisolated static func isNoEdition(loadedCount: Int, failed: Bool, hadEdition: Bool) -> Bool {
        loadedCount == 0 && !failed && !hadEdition
    }

    /// A load that failed with nothing read must not replace a songs list that is already on screen (Refresh while offline keeps the album as it was).
    nonisolated static func keepsCurrentSongs(failed: Bool, loadedCount: Int, currentCount: Int) -> Bool {
        failed && loadedCount == 0 && currentCount > 0
    }
}
