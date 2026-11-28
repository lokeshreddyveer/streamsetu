import Foundation

// The pure rules behind the country lists Home used to show and Explore still loads: what is cached under which key and in what order the regional shelves go.
// Listen Now's own engine is in Services/Music/Home. No views and no network here, so each rule is tested on its own.

// MARK: - Cache key and policy

/// What a composed Home depends on. Two Homes with the same key are interchangeable, so the cache is looked up by it.
struct MusicHomeKey: Hashable, Sendable {
    var region: String
    var language: MusicLanguage?
    /// The active browsing source (its shelves are not about the country).
    var source: String
    /// The discovery sources that are switched on, sorted.
    var discovery: [String]
    /// The languages the person's own plays point to, used when no language is chosen. Sorted; empty when one is chosen.
    var wanted: [MusicLanguage]

    init(region: String, language: MusicLanguage?, source: String, discovery: [String], wanted: [MusicLanguage]) {
        self.region = region.lowercased(); self.language = language; self.source = source
        self.discovery = discovery.sorted()
        self.wanted = language == nil ? Array(Set(wanted)).sorted { $0.rawValue < $1.rawValue } : []
    }

    /// One readable string; the disk file name is made from it.
    var name: String {
        [region, language?.rawValue ?? "all", source, discovery.joined(separator: "+"), wanted.map(\.rawValue).joined(separator: "+")].joined(separator: "|")
    }

    var fileName: String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return String(safe.prefix(120)) + ".json"
    }
}

enum MusicHomeCachePolicy {
    /// A cached Home younger than this is shown without any request at all.
    static let freshSeconds: TimeInterval = 20 * 60
    /// An older one is still shown at once (and refreshed quietly) up to this age; beyond it the page loads as if new.
    static let usableSeconds: TimeInterval = 7 * 24 * 3600
    static let diskFilesKept = 8

    enum State: Equatable { case fresh, stale, unusable }

    static func state(savedAt: Date, now: Date = Date()) -> State {
        let age = now.timeIntervalSince(savedAt)
        if age < 0 || age > usableSeconds { return .unusable }
        return age <= freshSeconds ? .fresh : .stale
    }
}

// MARK: - Cache records (Codable copies of the shelves)

struct MusicCachedItem: Codable, Sendable {
    var track: MusicTrack?
    var album: MusicAlbum?
    var artist: MusicArtist?
    var playlist: MusicPlaylist?

    init(_ item: MusicBrowseItem) {
        switch item {
        case .track(let t): track = t
        case .album(let a): album = a
        case .artist(let a): artist = a
        case .playlist(let p): playlist = p
        }
    }

    var item: MusicBrowseItem? {
        if let track { return .track(track) }
        if let album { return .album(album) }
        if let artist { return .artist(artist) }
        if let playlist { return .playlist(playlist) }
        return nil
    }
}

struct MusicCachedSection: Codable, Sendable {
    var id: String
    var title: String
    var items: [MusicCachedItem]
    /// Optional so a Home saved before this field existed still loads (it then reads as unstated).
    var scope: MusicSectionScope?
    init(_ s: MusicBrowseSection) { id = s.id; title = s.title; items = s.items.map(MusicCachedItem.init); scope = s.scope }
    var section: MusicBrowseSection { MusicBrowseSection(id: id, title: title, items: items.compactMap(\.item), scope: scope ?? .other) }
}

/// One composed Home as it is kept in memory and on disk.
struct MusicHomeSnapshot: Codable, Sendable {
    var key: String
    var savedAt: Date
    /// False for the copy on disk: the country's public lists and the public discovery sources only. The source's own shelves (which can be
    /// tied to an account) and the language shelf (from the person's history) are kept in memory for the session and never written to a file.
    var personalIncluded = true
    var featured: [MusicCachedSection] = []
    var explore: [MusicCachedSection] = []
    var regional: [MusicCachedSection] = []
    var language: MusicCachedSection?
    /// The searched shelves of a chosen language (public search results, so they are written to the file too). Absent in files from older versions.
    var languageBlock: [MusicCachedSection]?
    var discovery: [String: [MusicCachedSection]] = [:]
}

// MARK: - Regional shelf order

enum MusicHomeRegionalOrder {
    /// Songs of the country first, then what is new there, then the other sources' lists, then albums and the video charts.
    /// With a region, the order that region's sources lead in applies (India: YouTube Music India charts, Apple India, JioSaavn, then the rest).
    static func rank(sectionID id: String, region: String?) -> Int {
        guard let region else { return rank(sectionID: id) }
        return MusicChartArrangement.rank(sectionID: id, region: region)
    }

    static func rank(sectionID id: String) -> Int {
        if id.hasPrefix("itunes-songs-") { return 0 }
        if id.hasPrefix("jiosaavn-new-") { return 1 }
        if id.hasPrefix("jiosaavn-top-") { return 2 }
        if id.hasPrefix("deezer-top-") { return 3 }
        if id.hasPrefix("ytm-chart-artists") { return 4 }
        if id.hasPrefix("ytm-chart-") { return 5 }
        if id.hasPrefix("jiosaavn-albums-") { return 6 }
        if id.hasPrefix("itunes-albums-") { return 7 }
        return 9
    }

    /// A stable sort by rank (equal ranks keep their order).
    static func ordered(_ sections: [MusicBrowseSection], region: String? = nil) -> [MusicBrowseSection] {
        sections.enumerated().sorted { a, b in
            let ra = rank(sectionID: a.element.id, region: region), rb = rank(sectionID: b.element.id, region: region)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Renames a YouTube Music charts shelf so the title names the country, and drops the ones that say nothing about it.
    /// `languageName` is set when the person picked a language: only the weekly chart of that language is kept.
    static func youTubeChartTitle(_ title: String, country: String, languageName: String?) -> (id: String, title: String)? {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "top artists":
            return languageName == nil ? ("ytm-chart-artists", Localized.string("Top artists in %@", country)) : nil
        case "video charts":
            return languageName == nil ? ("ytm-chart-videos", Localized.string("Video charts in %@", country)) : nil
        case "languages":
            if let languageName { return ("ytm-chart-language", Localized.string("Weekly video charts, %@", languageName)) }
            return ("ytm-chart-languages", Localized.string("Weekly video charts by language in %@", country))
        case "top albums":
            return languageName == nil ? ("ytm-chart-albums", Localized.string("Top albums in %@", country)) : nil
        default:
            return nil
        }
    }
}
