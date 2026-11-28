import Foundation

// The values every filled screen shares: a tile (one entity with its art and context line), a shelf (tiles plus the honest reason it is shown), and the
// words. Pure Foundation; the views turn a tile into a typed route and a card.

/// Where a shelf's content comes from, said on the shelf so it is never passed off as something else.
enum MusicFillScope: String, Sendable, Hashable, CaseIterable {
    /// From what this person played, liked or saved.
    case personal
    /// From the person's region or languages (India stays India).
    case regional
    /// A worldwide list, labelled as such.
    case global
    /// A starter roster of well-known names so a screen is never empty; art and works arrive from public sources.
    case starter
    /// From the connected graph around one thing.
    case related
}

/// What a tile is, which decides its shape: people are round, films are posters, the rest are squares.
enum MusicFillTileKind: String, Sendable, Hashable {
    case musicDirector, singer, lyricist, actor, person, film, soundtrack, album, song, playlist, language, era, mood, genre, region, station
    var isRound: Bool { switch self { case .musicDirector, .singer, .lyricist, .actor, .person: true; default: false } }
    var isPoster: Bool { self == .film }
}

struct MusicFillTile: Identifiable, Hashable, Sendable {
    /// The entity the tile opens. Provisional ids are fine: the page loads or fetches the entity.
    var entity: MusicEntityID
    var kind: MusicFillTileKind
    var title: String
    /// The context line: "Music director · Hindi · 1950s", "From Awaara (1951)", "Raj Kapoor, Nargis".
    var subtitle: String
    var imageRef: String?
    var role: MusicRole?
    var year: Int?
    /// A playlist of this Mac's library (its UUID text): such a tile has no graph page, it opens the playlist itself.
    var localPlaylistID: String?
    var id: String { entity.rawValue + "|" + (role?.rawValue ?? "") + "|" + kind.rawValue + (localPlaylistID.map { "|" + $0 } ?? "") }
}

struct MusicFillShelf: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// One honest line: why this shelf is on the screen ("Because you played songs by Shankar-Jaikishan").
    var reason: String
    var scope: MusicFillScope
    var tiles: [MusicFillTile]
    /// The entities the shelf was built around.
    var seeds: [MusicEntityID] = []
    /// A shelf shorter than this is shown without "Show all".
    var count: Int { tiles.count }
    var isEmpty: Bool { tiles.isEmpty }
}

/// The wording the builders use. English here; the app passes `Localized.string`. Templates use `%@` and `%1$@`.
struct MusicFillWording: Sendable {
    var string: @Sendable (String) -> String
    var format: @Sendable (String, [String]) -> String
    static let english = MusicFillWording(string: { $0 }, format: { key, args in
        var out = key
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        var next = 0
        while next < args.count, let r = out.range(of: "%@") { out.replaceSubrange(r, with: args[next]); next += 1 }
        return out
    })
    func s(_ key: String) -> String { string(key) }
    func f(_ key: String, _ args: String...) -> String { format(string(key), args) }
}

/// A short "Music director · Hindi · 1950s" style line from parts, skipping empties.
enum MusicFillLine {
    static func join(_ parts: [String?], separator: String = " · ") -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator) }
    static func decade(_ year: Int?) -> String? { year.map { "\(($0 / 10) * 10)s" } }
    static func filmCaption(_ title: String, year: Int?) -> String { year.map { "\(title) (\($0))" } ?? title }
}

/// Language keys and names come from the system's own language data, not from a list of languages in the app: a key is a two-letter language code, and
/// a name is what the system calls that language in the person's own language.
enum MusicFillLanguage {
    /// The language code for a code or a language name ("hi", "hin" and "Hindi" are all `hi`), or nil when the text is not a language.
    static func key(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        let english = Locale(identifier: "en")
        if r.count == 2, english.localizedString(forLanguageCode: r) != nil, Locale.LanguageCode(r).isISOLanguage { return r }
        for code in Locale.LanguageCode.isoLanguageCodes {
            let c = code.identifier
            if english.localizedString(forLanguageCode: c)?.lowercased() == r { return c }
            if let alpha3 = Locale.Language(identifier: c).languageCode?.identifier(.alpha3), alpha3.lowercased() == r { return c }
        }
        return nil
    }
    static func name(_ raw: String?) -> String? {
        guard let k = key(raw) else { return nil }
        return MusicLanguageNames.displayName(code: k)
    }
}
