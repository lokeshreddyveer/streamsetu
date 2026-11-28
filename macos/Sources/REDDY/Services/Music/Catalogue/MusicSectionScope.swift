import Foundation

/// What a discovery list is really about. A source reports it per list: Apple's per-country feed is `.regional("in")`, Deezer's worldwide
/// chart is `.global` even when it was offered for a country that Deezer has no chart for, and a list that says nothing is `.other` (never
/// shown as a country's chart). Region and language are separate: a country only changes the sources that truly publish per-country lists.
enum MusicSectionScope: Hashable, Sendable, Codable {
    case regional(String)
    case global
    case other

    var regionCode: String? { if case .regional(let c) = self { c.lowercased() } else { nil } }

    /// True when the list is the chosen country's own.
    func isRegional(for region: String) -> Bool { regionCode == region.lowercased() }

    /// Unknown scope counts as the country's own only when the source itself follows the country (`MusicRegionalSources.followsRegion`),
    /// which is how lists from before this field existed (the saved Home) keep working.
    func countsAsRegional(for region: String, sourceFollowsRegion: Bool) -> Bool {
        switch self {
        case .regional(let c): c.lowercased() == region.lowercased()
        case .global: false
        case .other: sourceFollowsRegion
        }
    }
}

/// Which lists lead under a country's name, and how the rest is titled. Pure, so Explore, Home and Radio agree.
enum MusicChartArrangement {
    struct Part: Sendable {
        var providerID: String
        var sourceFollowsRegion: Bool
        var sections: [MusicBrowseSection]
        init(providerID: String, sourceFollowsRegion: Bool, sections: [MusicBrowseSection]) {
            self.providerID = providerID; self.sourceFollowsRegion = sourceFollowsRegion; self.sections = sections
        }
    }

    struct Result: Equatable, Sendable {
        /// Lists that are truly the country's, best source first. These may be titled "Top charts in <Country>".
        var regional: [MusicBrowseSection] = []
        /// Global and substituted lists, with honest titles ("Top worldwide", "Trending on Audius"), always after the regional ones.
        var worldwide: [MusicBrowseSection] = []
        /// Everything else (new releases, playlists, unknown scope from a source that does not follow the country).
        var other: [MusicBrowseSection] = []
    }

    /// Section-id prefixes in the order a country's lists lead. India: YouTube Music India charts, Apple India, JioSaavn, then the rest.
    static func priority(region: String) -> [String] {
        switch region.lowercased() {
        case "in": ["ytm-chart-videos", "ytm-chart-language", "ytm-chart-languages", "itunes-songs-", "itunes-played-", "jiosaavn-new-", "jiosaavn-top-", "ytm-chart-artists", "ytm-chart-", "deezer-top-", "jiosaavn-albums-", "itunes-albums-"]
        default: ["itunes-songs-", "ytm-chart-videos", "itunes-played-", "deezer-top-", "ytm-chart-language", "ytm-chart-languages", "ytm-chart-artists", "ytm-chart-", "jiosaavn-new-", "jiosaavn-top-", "jiosaavn-albums-", "itunes-albums-"]
        }
    }

    static func rank(sectionID id: String, region: String) -> Int {
        let p = priority(region: region)
        return p.firstIndex { id.hasPrefix($0) } ?? p.count
    }

    /// Honest title of a list that is not the country's: a worldwide chart says so; others keep their own title.
    static func honestTitle(_ s: MusicBrowseSection) -> String {
        if s.id == "deezer-tracks" { return Localized.string("Top worldwide") }
        if s.id == "deezer-albums" { return Localized.string("Top albums worldwide") }
        if s.id == "deezer-artists" { return Localized.string("Top artists worldwide") }
        if s.id == "deezer-playlists" { return Localized.string("Popular playlists worldwide") }
        if s.id.hasPrefix("audius-trending") { return Localized.string("Trending now") }
        // A genre chart is named by the genre alone, in lower case ("electronic"): it says what it is and that it is not the country's.
        if s.id.hasPrefix("soundcloud-"), !s.id.hasPrefix("soundcloud-sel-"), !s.title.isEmpty {
            return Localized.string("%@ worldwide", Localized.string(s.title.prefix(1).uppercased() + s.title.dropFirst()))
        }
        return s.title
    }

    static func arrange(_ parts: [Part], region: String) -> Result {
        var r = Result()
        var regional: [(Int, Int, MusicBrowseSection)] = []
        var n = 0
        for part in parts {
            for s in part.sections where !s.items.isEmpty {
                n += 1
                if s.scope.countsAsRegional(for: region, sourceFollowsRegion: part.sourceFollowsRegion) {
                    regional.append((rank(sectionID: s.id, region: region), n, s))
                } else if s.scope == .global {
                    var g = s; g.title = honestTitle(s); r.worldwide.append(g)
                } else {
                    r.other.append(s)
                }
            }
        }
        r.regional = regional.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
        // A global list that is the same shelf title as another is shown once.
        var seen = Set<String>()
        r.worldwide = r.worldwide.filter { seen.insert($0.title.lowercased()).inserted }
        return r
    }
}
