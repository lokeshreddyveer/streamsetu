import Testing
import Foundation
@testable import REDDY

/// Explore's languages, genres and moods are derived from the device, the person's library and what the sources return; these tests use made-up listeners.
@Suite("Derived languages and genres (no hardcoded lists)") @MainActor struct HardcodeDerivationTests {
    private func song(_ id: String, _ title: String, genre: String? = nil, language: String? = nil) -> MusicTrack {
        var t = MusicTrack(id: id, providerID: "p", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Artist")], thumbnails: [])
        if genre != nil || language != nil { t.hints = MusicProviderHints(language: language, genre: genre) }
        return t
    }
    private func keys(_ l: [MusicDerivedLanguage]) -> [String] { l.map(\.key) }

    // MARK: personas

    @Test("A Telugu and Hindi listener on an English device in a US-like region: their languages first, then the device's, nothing else")
    func teluguHindiListener() {
        let library = (0..<6).map { song("t\($0)", "నువ్వే నువ్వే \($0)") } + (0..<3).map { song("h\($0)", "तेरे बिना \($0)") }
        let facets = MusicLibraryFacets.build(tracks: library)
        let chartTitles = ["Shape of You", "Blinding Lights", "Levitating"].enumerated().map { song("c\($0.offset)", $0.element) }
        let region = MusicBrowseSection(id: "itunes-songs-us", title: "Top songs", items: chartTitles.map { .track($0) }, scope: .regional("us"))
        let derived = MusicDerivedLanguages.derive(.init(preferredLanguages: ["en-US"], library: facets.languages, region: MusicDerivedLanguages.counts(in: [region]), other: [:]))
        #expect(keys(derived) == ["telugu", "hindi", "english"])
        #expect(derived.first?.origin == .library && derived.last?.origin == .device)
        #expect(!keys(derived).contains("korean") && !keys(derived).contains("tamil") && !keys(derived).contains("spanish"))
        #expect(derived.allSatisfy { !$0.name.isEmpty })
    }

    @Test("A French user in France: the device language only, named through Locale")
    func frenchUser() {
        let chart = MusicBrowseSection(id: "itunes-songs-fr", title: "Top", items: [.track(song("1", "Alors on danse")), .track(song("2", "Formidable"))], scope: .regional("fr"))
        let derived = MusicDerivedLanguages.derive(.init(preferredLanguages: ["fr-FR"], library: [], region: MusicDerivedLanguages.counts(in: [chart]), other: [:]))
        #expect(keys(derived) == ["french"])
        #expect(derived.first?.name == MusicLanguageNames.displayName(code: "fr"))
    }

    @Test("A country's chart in another script adds its language after the person's own, and the rest follow by count")
    func regionThenOthers() {
        let chart = MusicBrowseSection(id: "ytm-chart", title: "Top", items: ["안녕 하세요", "사랑해", "こんにちは"].enumerated().map { .track(song("k\($0.offset)", $0.element)) })
        let world = MusicBrowseSection(id: "deezer", title: "Top", items: [.track(song("w", "مرحبا بك"))])
        let counts = MusicDerivedLanguages.counts(in: [chart])
        #expect(counts["korean"] == 2 && counts["japanese"] == 1)
        let derived = MusicDerivedLanguages.derive(.init(preferredLanguages: ["en"], library: [], region: counts, other: MusicDerivedLanguages.counts(in: [world])))
        #expect(keys(derived) == ["english", "korean", "japanese", "arabic"])
        #expect(derived.map(\.origin) == [.device, .region, .region, .other])
    }

    @Test("An empty library, no device language and a source that returns nothing give an empty list, never a fallback")
    func emptyGivesNothing() {
        #expect(MusicDerivedLanguages.derive(.init(preferredLanguages: [], library: [], region: [:], other: [:])).isEmpty)
        #expect(MusicDerivedLanguages.counts(in: []).isEmpty)
        #expect(MusicDerivedLanguages.tiles([]).isEmpty)
        #expect(MusicDerivedGenres.arrange(provider: [], library: []).isEmpty)
    }

    @Test("Plain Latin script and unknown words are never turned into languages")
    func latinIsNotALanguage() {
        let derived = MusicDerivedLanguages.derive(.init(preferredLanguages: ["zz-ZZ", "xx"], library: [MusicLibraryFacet(key: "latin", name: "Latin script", count: 9)], region: ["klingonese": 4], other: [:]))
        #expect(derived.isEmpty)
    }

    // MARK: tiles

    @Test("A long list is capped with a More tile that opens everything, and a Show fewer tile closes it")
    func capAndMore() {
        let many = ["telugu", "hindi", "tamil", "kannada", "malayalam", "bengali", "punjabi", "korean", "japanese", "arabic"]
            .map { MusicDerivedLanguage(key: $0, english: $0.capitalized, name: $0.capitalized, origin: .region, count: 1) }
        let short = MusicDerivedLanguages.tiles(many, cap: 8)
        #expect(short.count == 8 && short.last?.isToggle == true && short.dropLast().allSatisfy { !$0.isToggle })
        let all = MusicDerivedLanguages.tiles(many, cap: 8, expanded: true)
        #expect(all.count == many.count + 1 && all.last?.isToggle == true)
        #expect(MusicDerivedLanguages.tiles(Array(many.prefix(5)), cap: 8).allSatisfy { !$0.isToggle })
    }

    // MARK: genres

    @Test("Genres: the person's own come first, library genres the source lacks follow, the source's order is kept for the rest")
    func genreOrder() {
        let provider = ["Rock", "Jazz", "Dance", "Folk"].map { MusicCategory(name: $0, kind: .genre, target: .search($0 + " music")) }
            + [MusicCategory(name: "Chill", kind: .mood, target: .search("chill"))]
        let library = MusicLibraryFacets.build(tracks: (0..<4).map { song("j\($0)", "x\($0)", genre: "Jazz") } + (0..<3).map { song("b\($0)", "y\($0)", genre: "Bossa Nova") }).genres
        let out = MusicDerivedGenres.arrange(provider: provider, library: library)
        #expect(out.map(\.name) == ["Jazz", "Bossa Nova", "Rock", "Dance", "Folk", "Chill"])
        let none = MusicDerivedGenres.arrange(provider: provider, library: [])
        #expect(none.map(\.name) == provider.map(\.name))
    }

    @Test("With no source tiles the library's own genres are all there is")
    func libraryOnlyGenres() {
        let library = MusicLibraryFacets.build(tracks: (0..<3).map { song("f\($0)", "z\($0)", genre: "Fado") }).genres
        #expect(MusicDerivedGenres.arrange(provider: [], library: library).map(\.name) == ["Fado"])
    }

    // MARK: helpers that used to be literal tables

    @Test("The languages JioSaavn is asked for come from the person or the device, never a built-in trio")
    func jioFromPerson() {
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "in", wanted: [], device: ["en"]).isEmpty)
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "in", wanted: [], device: ["ta-IN"]) == [.tamil])
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "fr", wanted: [], device: ["ta-IN"]).isEmpty)
    }

    @Test("Apple's chart country for a language comes from Locale, and Latin-script languages have none")
    func chartCountryFromLocale() {
        #expect(MusicLanguage.korean.chartCountry == "kr")
        #expect(MusicLanguage.japanese.chartCountry == "jp")
        #expect(MusicLanguage.english.chartCountry == nil && MusicLanguage.spanish.chartCountry == nil)
        #expect(MusicLanguage.telugu.chartCountry == nil, "its own JioSaavn lists are used")
    }

    @Test("Apple charts are not asked for a value that is not a country")
    func notACountry() {
        #expect(ITunesChartsDiscoveryProvider.validRegion("../x") == nil && ITunesChartsDiscoveryProvider.validRegion("") == nil)
        #expect(ITunesChartsDiscoveryProvider.validRegion("FR") == "fr")
    }


    // MARK: source scan

    private static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// The code of a source file with comments removed, optionally only the part between two markers.
    private func code(_ rel: String, from: String? = nil, to: String? = nil) throws -> String {
        var text = try String(contentsOf: Self.root.appendingPathComponent(rel), encoding: .utf8)
        if let from, let a = text.range(of: from) { text = String(text[a.lowerBound...]) }
        if let to, let b = text.range(of: to) { text = String(text[..<b.lowerBound]) }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    @Test("Explore and the derivation files hold no language, genre, artist or country literals")
    func noForbiddenLiterals() throws {
        let forbidden = ["\"Telugu\"", "\"Hindi\"", "\"Tamil\"", "\"Kannada\"", "\"Malayalam\"", "\"Punjabi\"", "\"Bengali\"", "\"Korean\"", "\"Japanese\"", "\"Spanish\"", "\"Arabic\"", "\"Portuguese\"", "\"French\"",
                         "\"Pop\"", "\"Hip-Hop\"", "\"Rock\"", "\"Jazz\"", "\"Classical\"", "\"Reggae\"", "\"K-pop\"", "\"Bollywood\"", "\"bollywood\"", "\"k-pop\"",
                         "builtInGenres", "regionHints", "indiaDefaultLanguages", "(\"english\", \"English\")"]
        let files: [(String, String?, String?)] = [
            ("Sources/REDDY/Features/Music/MusicExploreView.swift", nil, nil),
            ("Sources/REDDY/Features/Music/MusicExploreLazyShelf.swift", nil, nil),
            ("Sources/REDDY/Services/Music/Discovery/MusicDerivedCategories.swift", nil, nil),
            ("Sources/REDDY/Services/Music/Discovery/MusicGenreArtwork.swift", "enum MusicCategoryCatalogue", "enum MusicLanguageDetect"),
            ("Sources/REDDY/Services/Music/Providers/Discovery/MusicRegionalSources.swift", nil, nil)
        ]
        for (rel, from, to) in files {
            let text = try code(rel, from: from, to: to)
            for f in forbidden { #expect(!text.contains(f), "\(rel) must not contain \(f)") }
        }
    }

    @Test("The country list stays derived from the system, not typed in")
    func countriesAreDerived() throws {
        let text = try code("Sources/REDDY/Services/Music/Providers/Discovery/MusicDiscoveryBuiltIns.swift")
        #expect(text.contains("Locale.Region.isoRegions"))
        #expect(!text.contains("\"France\"") && !text.contains("\"India\"") && !text.contains("\"Albania\""))
    }
}
