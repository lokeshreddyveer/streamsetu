import Foundation

/// JioSaavn's public lists for India and its regional languages: the country chart, the newest songs and albums, and the per-language charts.
/// Information only: no audio, no stream and no encrypted field is read. Every song from here is shown on Home only after a verified playable
/// copy is found on another source (the catalogue rule), so this source never puts a row on screen that cannot be played.
struct JioSaavnDiscoveryProvider: MusicMetadataProvider, MusicRegionalDiscovery, MusicLanguageDiscovery {
    static let id = "discover-jiosaavn"
    private let saavn: JioSaavnProvider
    init(http: MusicHTTP = MusicHTTP()) { saavn = JioSaavnProvider(http: http) }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "JioSaavn charts", summary: "Top and new songs in India and in Hindi, Telugu, Tamil and more. Songs appear only when a playable copy is found.", host: "www.jiosaavn.com")
    }
    var capabilities: MusicCapabilities { [.browse, .catalogue] }

    /// With no country there is nothing regional to say.
    func featured() async throws -> [MusicBrowseSection] { throw MusicError.notFound }

    func featured(region: String) async throws -> [MusicBrowseSection] { try await featured(region: region, languages: []) }

    func featured(region: String, languages: [MusicLanguage]) async throws -> [MusicBrowseSection] {
        let langs = MusicRegionalSources.jioSaavnLanguages(region: region, wanted: languages)
        guard !langs.isEmpty else { throw MusicError.notFound }
        let launch = try await saavn.launchData(languages: langs.compactMap(\.jioSaavnCode))
        let single = langs.count == 1 && !languages.isEmpty ? langs.first : nil
        var chartSongs: [MusicTrack] = []
        if let chart = Self.chart(in: launch, language: single), let songs = try? await saavn.listSongs(id: chart.id, limit: 30) { chartSongs = songs }
        let sections = Self.sections(launch: launch, chartSongs: chartSongs, region: region, language: single, languages: langs)
        if sections.isEmpty { throw MusicError.network("JioSaavn returned no lists") }
        return sections
    }

    // MARK: composing (pure, tested against saved replies)

    static func sections(launch: [String: Any], chartSongs: [MusicTrack], region: String, language: MusicLanguage?, languages: [MusicLanguage]) -> [MusicBrowseSection] {
        let inIndia = MusicRegionalSources.jioSaavnRegions.contains(region.lowercased())
        let tag = language?.rawValue ?? "mix"
        var out: [MusicBrowseSection] = []
        // JioSaavn lists Indian music: they are the country's own only for India; elsewhere they follow a language, not a country.
        let scope: MusicSectionScope = inIndia ? .regional(region.lowercased()) : .other
        func add(_ id: String, _ title: String, _ items: [MusicBrowseItem]) { if !items.isEmpty { out.append(MusicBrowseSection(id: id, title: title, items: items, scope: scope)) } }
        // Outside India the lists without a language are still India's: they are named for India, never for the country the person looked at.
        let name = MusicDiscoveryRegion.name(inIndia ? region : (MusicRegionalSources.jioSaavnRegions.sorted().first ?? region))
        let topTitle: String
        if let language { topTitle = inIndia ? MusicRegionalSources.topSongsTitle(region: region, language: language) : Localized.string("Top %@ songs", language.displayName) }
        else { topTitle = Localized.string("Superhits in %@", name) }
        add("jiosaavn-top-\(tag)", topTitle, chartSongs.map { .track($0) })
        let newTitle: String
        if let language { newTitle = Localized.string("New in %@", language.displayName) } else { newTitle = Localized.string("New in %@", name) }
        add("jiosaavn-new-\(tag)", newTitle, newSongs(in: launch, languages: languages).map { .track($0) })
        let albumTitle = language.map { Localized.string("New %@ albums", $0.displayName) } ?? Localized.string("New albums in %@", name)
        add("jiosaavn-albums-\(tag)", albumTitle, newAlbums(in: launch, languages: languages).map { .album($0) })
        return out
    }

    /// The chart list for a language, or the country-wide one when no single language is asked for. Nothing here knows a chart's name: the service
    /// lists its charts as "<Language>: <list name>" for each language, so the country-wide list is the one whose title is the name those share.
    static func chart(in launch: [String: Any], language: MusicLanguage?) -> (id: String, title: String)? {
        let rows = launch.array("charts").filter { $0.str("type") == "playlist" }.compactMap { r -> (id: String, title: String)? in
            guard let id = r.str("id"), let title = r.str("title") else { return nil }
            return (id, JioSaavnProvider.clean(title))
        }
        // Split "Telugu: Name" into its language and list name when the part before the colon is a language the app knows.
        func split(_ title: String) -> (language: MusicLanguage, base: String)? {
            guard let colon = title.firstIndex(of: ":") else { return nil }
            let head = title[..<colon].trimmingCharacters(in: .whitespaces)
            guard let l = MusicLanguage.allCases.first(where: { $0.englishName.caseInsensitiveCompare(head) == .orderedSame }) else { return nil }
            return (l, title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let parts = rows.map { (row: $0, split: split($0.title)) }
        if let language {
            let mine = parts.filter { $0.split?.language == language }
            // Prefer the language list that shares its name with a country-wide list when the service offers several.
            let bases = Set(parts.compactMap { $0.split == nil ? $0.row.title.lowercased() : nil })
            return (mine.first { bases.contains($0.split?.base.lowercased() ?? "") } ?? mine.first)?.row
        }
        let bases = Dictionary(grouping: parts.compactMap { $0.split?.base.lowercased() }, by: { $0 }).mapValues(\.count)
        return parts.filter { $0.split == nil && bases[$0.row.title.lowercased()] != nil }
            .max { (bases[$0.row.title.lowercased()] ?? 0) < (bases[$1.row.title.lowercased()] ?? 0) }?.row
    }

    private static func inLanguages(_ row: [String: Any], _ languages: [MusicLanguage]) -> Bool {
        guard let l = row.str("language")?.lowercased() else { return false }
        return languages.contains { $0.jioSaavnCode == l }
    }

    /// Songs of the "new" module, only in the languages asked for (the service also slips in instrumental and foreign rows).
    static func newSongs(in launch: [String: Any], languages: [MusicLanguage]) -> [MusicTrack] {
        launch.array("new_albums").filter { $0.str("type") == "song" && inLanguages($0, languages) }.compactMap(JioSaavnProvider.mapSong)
    }

    static func newAlbums(in launch: [String: Any], languages: [MusicLanguage]) -> [MusicAlbum] {
        var seen = Set<String>()
        return (launch.array("new_albums") + launch.array("new_trending")).filter { $0.str("type") == "album" && inLanguages($0, languages) }
            .compactMap(JioSaavnProvider.mapAlbum).filter { seen.insert($0.id).inserted }
    }
}
