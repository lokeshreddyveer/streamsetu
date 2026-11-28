import SwiftUI

// Explore: a heading with the chart country, a restrained featured hero, charts and new releases for the country, languages, and every mood and
// genre as a cover tile. Every part loads on its own, keeps what it loaded in memory so coming back is instant, and hides quietly when it fails.

// MARK: - Composition (pure)

enum MusicExploreComposition {
    struct Part {
        var providerID: String; var regional: Bool; var sections: [MusicBrowseSection]
        /// True when the source really publishes lists per country for the chosen country (`MusicRegionalSources.followsRegion`). Only read when `compose` is given a region.
        var followsRegion = true
    }
    struct Result: Equatable {
        var hero: MusicBrowseItem?
        var heroIsNewRelease = false
        /// True when the hero comes from a worldwide list (its eyebrow then says so instead of naming the country).
        var heroIsWorldwide = false
        /// The releases list is not the country's own (no source publishes one per country): under a country its title says "worldwide" instead of reading as the country's.
        var releasesAreWorldwide = false
        /// Only lists that are truly the chosen country's own.
        var charts: MusicBrowseSection?
        /// Worldwide and substituted lists under honest titles ("Top worldwide", "Trending now"), always after the country's.
        var worldwide: [MusicBrowseSection] = []
        var releases: MusicBrowseSection?
        /// True when at least one list is truly the chosen country's own (a chart, new releases or any other list from a source that follows the country).
        var hasCountryLists = false
        var more: [MusicBrowseSection] = []
    }

    static let moreLimit = 3

    /// A list of new music, told by what it is (its id) and by its title, so a source's own wording or language does not decide it.
    static func isRelease(_ s: MusicBrowseSection) -> Bool {
        let id = s.id.lowercased()
        return id.contains("new-") || id.contains("fresh") || id.contains("release") || isReleaseTitle(s.title)
    }

    static func isReleaseTitle(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("new release") || l.contains("new album") || l.contains("new music") || l.contains("latest")
    }

    static func hasArt(_ item: MusicBrowseItem) -> Bool { !thumbs(item).isEmpty }

    static func thumbs(_ item: MusicBrowseItem) -> [MusicThumbnail] {
        switch item {
        case .album(let a): a.thumbnails; case .artist(let a): a.thumbnails; case .playlist(let p): p.thumbnails; case .track(let t): t.thumbnails
        }
    }

    /// Picks what each part of the page shows from what the sources answered. The hero is the first new release with art, else the first chart entry
    /// with art; the same shelf title is never shown twice.
    static func compose(_ parts: [Part], region: String? = nil) -> Result {
        var r = Result()
        var seen = Set<String>()
        var all: [(Bool, MusicBrowseSection)]
        if let region {
            // Region and language are separate: only sources that truly publish per-country lists, and only what they report as the country's, lead under its name.
            let a = MusicChartArrangement.arrange(parts.map { .init(providerID: $0.providerID, sourceFollowsRegion: $0.regional && $0.followsRegion, sections: $0.sections) }, region: region)
            all = a.regional.map { (true, $0) } + a.other.map { (false, $0) }
            let isTracks: (MusicBrowseSection) -> Bool = { w in w.items.contains { if case .track = $0 { true } else { false } } }
            r.worldwide = a.worldwide.filter(isTracks)
            // Worldwide lists of albums, artists or playlists are not dropped: they join the other shelves (and can fill New releases and the feature cards).
            all += a.worldwide.filter { !isTracks($0) }.map { (false, $0) }
            for w in r.worldwide { seen.insert(w.title.lowercased()) }
        } else {
            all = parts.flatMap { p in p.sections.filter { !$0.items.isEmpty }.map { (p.regional, $0) } }
        }
        r.hasCountryLists = all.contains { $0.0 }
        // Charts: the country's own chart first. Without a region (older callers) a track list is the fallback; with one it never is.
        if let s = all.first(where: { $0.0 && !isRelease($0.1) && $0.1.items.contains { if case .track = $0 { true } else { false } } })?.1
            ?? (region == nil ? all.first(where: { $0.0 && !isRelease($0.1) })?.1 : nil)
            ?? (region == nil ? all.first(where: { !isRelease($0.1) && $0.1.items.contains { if case .track = $0 { true } else { false } } })?.1 : nil) {
            r.charts = s; seen.insert(s.title.lowercased())
        }
        var releasesAreCountry = false
        if let pick = all.first(where: { isRelease($0.1) && !seen.contains($0.1.title.lowercased()) })
            ?? all.first(where: { !seen.contains($0.1.title.lowercased()) && $0.1.items.allSatisfy { if case .album = $0 { true } else { false } } }) {
            r.releases = pick.1; releasesAreCountry = pick.0; seen.insert(pick.1.title.lowercased())
            r.releasesAreWorldwide = !(region ?? "").isEmpty && !pick.0
        }
        // A hero from a list of another scope (a worldwide album chart under a country) says so in its eyebrow instead of naming the country.
        if let h = r.releases?.items.first(where: hasArt) {
            r.hero = h; r.heroIsNewRelease = (r.releases.map(isRelease) ?? false)   // a chart of albums is not "new"
            r.heroIsWorldwide = !releasesAreCountry
        }
        else if let h = r.charts?.items.first(where: hasArt) { r.hero = h }
        else if let h = r.worldwide.first?.items.first(where: hasArt) { r.hero = h; r.heroIsWorldwide = true }
        for (_, s) in all where r.more.count < moreLimit && seen.insert(s.title.lowercased()).inserted { r.more.append(s) }
        return r
    }

    /// The artwork addresses of a shelf's items in order, for prefetch.
    static func addresses(_ section: MusicBrowseSection, pixels: Int) -> [String] {
        section.items.compactMap { MusicArtworkService.pickThumbnail(thumbs($0), neededPixels: pixels) }
    }

    static func entity(_ item: MusicBrowseItem) -> MusicEntity {
        switch item {
        case .album(let a): .album(a); case .artist(let a): .artist(a); case .playlist(let p): .playlist(p); case .track(let t): .track(t)
        }
    }

    static func title(_ item: MusicBrowseItem) -> String { entity(item).title }

    static func subtitle(_ item: MusicBrowseItem) -> String {
        switch item {
        case .album(let a): MusicHeroText.cardCredit(a.artists)
        case .artist: Localized.string("Artist")
        case .playlist(let p): MusicPlaylistCaption.line(p)
        case .track(let t): MusicHeroText.cardCredit(t.artists)
        }
    }
}

/// What a page keeps in memory so a return is instant (ten minutes).
@MainActor enum MusicExploreMemory {
    static let lifetime: TimeInterval = 600
    private static var store: [String: (at: Date, sections: [MusicBrowseSection])] = [:]
    private static var categoryStore: (at: Date, key: String, list: [MusicCategory])?
    private static var shelfStore: [String: (at: Date, section: MusicBrowseSection, provenance: MusicChartProvenance?)] = [:]

    /// A lazy shelf's answer, so a row that is built again (a recycled row, a return to the page) shows it at once instead of its placeholder.
    static func shelf(_ id: String) -> (section: MusicBrowseSection, provenance: MusicChartProvenance?)? {
        guard let e = shelfStore[id + "|" + Localized.activeCode], Date().timeIntervalSince(e.at) < lifetime else { return nil }
        return (e.section, e.provenance)
    }
    static func setShelf(_ section: MusicBrowseSection, provenance: MusicChartProvenance?, id: String) { shelfStore[id + "|" + Localized.activeCode] = (Date(), section, provenance) }

    /// How long a lazy shelf that came back empty is left alone: scrolling over it again must not ask again (and move the page), but a bad moment is not held for long.
    static let emptyLifetime: TimeInterval = 120
    private static var emptyShelves: [String: (at: Date, retries: Int)] = [:]
    /// True when this shelf answered "nothing" a moment ago, for the same Try again count (a Try again asks every row once more).
    static func isKnownEmpty(_ id: String, retries: Int, now: Date = Date()) -> Bool {
        guard let e = emptyShelves[id + "|" + Localized.activeCode], e.retries == retries else { return false }
        return now.timeIntervalSince(e.at) < emptyLifetime
    }
    static func setShelfEmpty(id: String, retries: Int, now: Date = Date()) { emptyShelves[id + "|" + Localized.activeCode] = (now, retries) }

    static func sections(_ key: String) -> [MusicBrowseSection]? {
        guard let e = store[key], Date().timeIntervalSince(e.at) < lifetime else { return nil }
        return e.sections
    }
    static func setSections(_ s: [MusicBrowseSection], key: String) { store[key] = (Date(), s) }
    static func categories(_ key: String) -> [MusicCategory]? {
        guard let c = categoryStore, c.key == key, Date().timeIntervalSince(c.at) < lifetime else { return nil }
        return c.list
    }
    static func setCategories(_ list: [MusicCategory], key: String) { categoryStore = (Date(), key, list) }
    static func forget() { store = [:]; categoryStore = nil; shelfStore = [:]; emptyShelves = [:] }
}

// MARK: - View

struct MusicExploreView: View {
    @Bindable var hub: MusicHub
    @State private var choice = MusicRegionChoice.shared
    private var region: String { choice.region }
    @State private var discovery: [String: MusicLoad<[MusicBrowseSection]>] = [:]
    /// The country `discovery` was loaded for: what was loaded for another country is never shown under this one's name.
    @State private var discoveryRegion = ""
    /// True while the language tiles show every derived language instead of the first few.
    @State private var languagesExpanded = false
    @State private var retries = 0
    /// Moods and genres retry on their own: asking them again must not reshuffle the shelves above.
    @State private var categoryRetries = 0
    @State private var showRagas = false
    @State private var categories: MusicLoad<[MusicCategory]>?
    @State private var chartExpanded = false
    @Environment(\.musicLayoutClass) private var cls
    @Environment(\.displayScale) private var displayScale

    private var ragaButton: some View {
        Button { showRagas = true } label: { Label(Localized.string("Ragas"), systemImage: "music.quarternote.3") }
            .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Browse film songs by raga")).atlas("control.music.exploreRagas")
            .sheet(isPresented: $showRagas) { MusicRagaSheet(hub: hub) { showRagas = false } }
    }


    /// JioSaavn answers by the device's languages, so Explore does not ask it here (that would make Explore differ by device); its per-language lists are the Language spotlight shelves.
    private var providers: [any MusicMetadataProvider] { hub.registry.discovery.filter { $0.id != JioSaavnDiscoveryProvider.id } }
    private var hasRegional: Bool { providers.contains { $0 is any MusicRegionalDiscovery } }
    /// One draw for the shelves of this visit, taken when loading starts and changed only by an explicit retry, so nothing reshuffles while the page redraws.
    @State private var seeAll = MusicExploreSeeAll.shared
    @State private var shelfSeed: UInt64 = MusicShelfVariety.last("explore")
    /// The Try again count already turned into a new draw: only a press made since then reshuffles, not every later reload.
    @State private var drawnRetries = 0
    private struct DiscoveryKey: Hashable { var ids: [String]; var region: String; var retries: Int; var gated: Bool; var language: String }
    private struct CategoryKey: Hashable { var source: String?; var gated: Bool; var retries: Int; var language: String }

    var body: some View {
        // The shelves stay in the tree under the full page (their scroll position and loaded answers are kept); the page covers them, and Back uncovers them. Opening a card from
        // the page leaves Explore for the item; coming back (Back) finds the page where it was left. Choosing another part of Music ends it.
        ZStack {
            exploreScreen.opacity(seeAll.section == nil ? 1 : 0).allowsHitTesting(seeAll.section == nil).accessibilityHidden(seeAll.section != nil)
            if let all = seeAll.section { MusicExploreSeeAllPage(section: all, hub: hub) { seeAll.section = nil }.background(ColorTokens.background) }
        }
        .onChange(of: hub.nav.section) { _, s in if s != .explore { seeAll.section = nil } }
        .onChange(of: region) { _, _ in seeAll.section = nil }
    }

    private var exploreScreen: some View {
        MusicScreen(title: Localized.string("Explore"), trailing: { HStack(spacing: MusicSpace.xs) { ragaButton; regionMenu } }, content: {
            if hub.gated {
                MusicEmptyState(glyph: .emptySearch, title: Localized.string("Music is not online right now."), message: Localized.string("Explore comes back when Music is online again."))
            } else if hub.registry.activeMetadata == nil && providers.isEmpty {
                MusicEmptyState(glyph: .emptySearch, title: Localized.string("No music source is switched on"),
                                message: Localized.string("Switch a source on in Settings to browse genres here."),
                                actionTitle: Localized.string("Open Settings")) { hub.nav.select(.settings) }
            } else {
                parts
            }
        })
        .task(id: DiscoveryKey(ids: providers.map(\.id), region: region, retries: retries, gated: hub.gated, language: Localized.activeCode)) { await loadDiscovery() }
        .task(id: CategoryKey(source: hub.registry.activeMetadata?.id, gated: hub.gated, retries: categoryRetries, language: Localized.activeCode)) { await loadCategories() }
        .onChange(of: region) { _, _ in chartExpanded = false; languagesExpanded = false }
    }

    @ViewBuilder private var regionMenu: some View {
        if hasRegional { MusicCountryPicker(region: region) { choice.set($0) } }
    }

    // MARK: parts

    @ViewBuilder private var parts: some View {
        let composed = MusicExploreComposition.compose(providers.map { p in
            let sections: [MusicBrowseSection]
            // A country's lists loaded for another country are not this one's: they wait until the right ones arrive.
            let fresh = discoveryRegion == region || !(p is any MusicRegionalDiscovery)
            if fresh, case .loaded(let s)? = discovery[p.id] { sections = s } else { sections = [] }
            return MusicExploreComposition.Part(providerID: p.id, regional: p is any MusicRegionalDiscovery, sections: sections,
                                                followsRegion: MusicRegionalSources.followsRegion(providerID: p.id, region: region))
        }, region: region)
        let loadingAny = providers.contains { isLoading(discovery[$0.id]) } || discoveryRegion != region
        let allFailed = !providers.isEmpty && discoveryRegion == region && providers.allSatisfy { if case .failed? = discovery[$0.id] { true } else { false } }
        // Right after a country is chosen, its lists are on the way: the previous country's (or the world's) shelves are not left under the new name. The page shows its final
        // shapes as skeletons until the country answers, then fills in.
        let switching = discoveryRegion != region && hasRegional
        VStack(alignment: .leading, spacing: MusicSpace.xl) {
            let features = switching ? [] : Self.featureItems(composed)
            if switching {
                MusicSkeletonBlock(width: nil, height: MusicExploreHero.height(for: cls), corner: MusicCorner.panel)
                skeletonShelf(MusicRegionalSources.chartsTitle(region: region))
                skeletonShelf(Localized.string("New releases"))
            } else if features.count >= 2 {
                // Three wide cards, the words above the picture, like Apple Music's New page.
                MusicFeatureCards(items: features, hub: hub)
            } else if let hero = composed.hero {
                MusicExploreHero(hub: hub, item: hero, isNewRelease: composed.heroIsNewRelease, regionName: MusicDiscoveryRegion.name(region), isWorldwide: composed.heroIsWorldwide)
            } else if loadingAny && !providers.isEmpty {
                MusicSkeletonBlock(width: nil, height: MusicExploreHero.height(for: cls), corner: MusicCorner.panel)
            }
            if !switching, !loadingAny, !allFailed, region != MusicDiscoveryRegion.worldwide, !composed.hasCountryLists {
                // A country with no lists of its own: said plainly, with a way out, instead of the world's lists under its name.
                MusicEmptyState(glyph: .emptySearch, title: Localized.string("No charts for %@ yet", MusicDiscoveryRegion.name(region)),
                                message: Localized.string("Lists for this country are not available from the sources that are on."),
                                actionTitle: Localized.string("Show worldwide")) { choice.set(MusicDiscoveryRegion.worldwide) }
            }
            if !switching, allFailed {
                MusicErrorState(title: Localized.string("Could not load the lists for %@", MusicDiscoveryRegion.name(region)), retryTitle: Localized.string("Try again")) { retries += 1 }
            }
            if switching {
                // nothing else until the country's lists arrive
            } else if let charts = composed.charts {
                let songs = charts.items.compactMap { item -> MusicTrack? in if case .track(let t) = item { t } else { nil } }
                if songs.count >= 6 {
                    // The chart as rows of songs in columns, not a shelf of covers.
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        HStack {
                            MusicLinkHeading(title: MusicRegionalSources.chartsTitle(region: region))
                            Spacer(minLength: MusicSpace.sm)
                            // Shuffle here means the trend: the whole chart of this country, in a new order each time.
                            Button { hub.playShuffled(songs, sourceName: MusicRegionalSources.chartsTitle(region: region)) } label: { Label(Localized.string("Shuffle"), systemImage: "shuffle") }
                                .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Shuffle %@", MusicRegionalSources.chartsTitle(region: region)))
                                .atlas("control.music.exploreShuffleChart")
                        }
                        MusicSongGrid(tracks: chartExpanded ? songs : Array(songs.prefix(12)), hub: hub, ranked: true, queue: songs)
                        if songs.count > 12 {
                            Button(chartExpanded ? Localized.string("Show fewer") : Localized.string("Show all %@", String(songs.count))) { chartExpanded.toggle() }
                                .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.exploreChartShowAll")
                        }
                    }
                } else { shelf(MusicRegionalSources.chartsTitle(region: region), charts) }
            } else if loadingAny && !providers.isEmpty && composed.worldwide.isEmpty { skeletonShelf(MusicRegionalSources.chartsTitle(region: region)) }
            if !switching { ForEach(composed.worldwide) { shelf($0.title, $0) } }
            if !switching, let releases = composed.releases { shelf(MusicExploreComposition.isRelease(releases) ? Localized.string(composed.releasesAreWorldwide ? "New releases worldwide" : "New releases") : releases.title, releases) }
            // Every tile below opens a page that asks the active metadata source; with none switched on (a chart source alone) they would lead to an error page.
            let canBrowse = hub.registry.activeMetadata != nil
            if !switching, canBrowse { languageSection(composed) }
            if !switching, canBrowse { decadesAndActivities }
            if !switching, canBrowse { MusicGenreFamilies { open($0) } }
            if canBrowse { moodAndGenre }
            // The chart's own shelves (most played, popular playlists, top albums) come before the ~70 lazy country, language and genre shelves, which are last so nothing is buried under them.
            ForEach(MusicShelfVariety.shelfOrder(composed.more, seed: shelfSeed)) { shelf($0.title, $0) }
            if !switching { worldShelves }
        }
    }

    /// Up to three things worth featuring, in the order of the trend (the country's chart order, never shuffled): playlists lead (up to two), then albums and artists, each once and
    /// each with a picture. The hero item and the country's chart come before the other shelves, so what is climbing is what is featured.
    static func featureItems(_ r: MusicExploreComposition.Result) -> [MusicBrowseItem] {
        var pool: [MusicBrowseItem] = []
        var seen = Set<String>()
        func add(_ item: MusicBrowseItem) {
            if case .track = item { return }
            guard !item.editorialThumbs.isEmpty, seen.insert(item.editorialEntity.key).inserted else { return }
            pool.append(item)
        }
        if let h = r.hero { add(h) }
        for section in [r.charts, r.releases].compactMap({ $0 }) + r.more + r.worldwide { section.items.forEach(add) }
        func isPlaylist(_ i: MusicBrowseItem) -> Bool { if case .playlist = i { true } else { false } }
        var out = Array(pool.filter(isPlaylist).prefix(2))
        for item in pool where out.count < 3 && !isPlaylist(item) { out.append(item) }
        for item in pool where out.count < 3 && isPlaylist(item) && !out.contains(item) { out.append(item) }
        return out
    }

    private func isLoading(_ load: MusicLoad<[MusicBrowseSection]>?) -> Bool {
        switch load { case nil, .loading?: true; default: false }
    }

    private func skeletonShelf(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) { MusicSectionTitle(title: title); MusicShelfSkeleton() }
    }

    @ViewBuilder private func shelf(_ title: String, _ s: MusicBrowseSection) -> some View {
        // A shelf with fewer than three things is left out: a row of one or two cards says the page is empty.
        if s.items.count >= 3 { shelfBody(title, s) }
    }

    @ViewBuilder private func shelfBody(_ title: String, _ s: MusicBrowseSection) -> some View {
        let px = MusicArtworkClass.tile.pixels(scale: displayScale)
        // A pick is drawn again on each visit; a chart (its scope says so) keeps its order.
        let items = s.scope == .other ? MusicShelfVariety.varied(s.items, seed: shelfSeed, name: s.id, keep: 2) : s.items
        // The queue is the songs in the order the cards are drawn: tapping a card plays on to the one after it on screen, not the one after it in the source's list.
        let songs = items.compactMap { item -> MusicTrack? in if case .track(let t) = item { t } else { nil } }
        MusicShelf(title: title) {
            ForEach(items.prefix(16), id: \.self) { MusicCard(result: $0, queue: songs, hub: hub) }
        }
        .onSeeAll { MusicExploreSeeAll.shared.section = MusicBrowseSection(id: s.id, title: title, items: items, scope: s.scope) }
        .prefetching(MusicExploreComposition.addresses(s, pixels: px))
    }

    // MARK: shelves from the person's own artists and languages, decades and activities

    /// Every shelf the registry lists, one lazy row each: country charts and language spotlights today, more as sources offer them. A row loads when scrolled to.
    @ViewBuilder private var worldShelves: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // The chosen country's chart is already shown above, so it is not listed a second time.
            ForEach(MusicExploreRegistry.all(excluding: region)) { MusicExploreLazyShelf(definition: $0, hub: hub, retries: retries) }
        }
    }

    /// Browse by era and by what you are doing (Apple Music's "Essential decades" and Tidal's moods and activities): each opens songs for that era or activity.
    @ViewBuilder private var decadesAndActivities: some View {
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Essential decades"))
                MusicCategoryGrid(categories: Self.decades, owner: "explore.decades") { open($0) }
            }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Activities"))
                MusicCategoryGrid(categories: Self.activities, owner: "explore.activities") { open($0) }
            }
        }
    }

    private static let decades: [MusicCategory] = ["1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"].map {
        MusicCategory(name: $0, kind: .genre, target: .search($0 + " hits"))
    }
    private static let activities: [MusicCategory] = ["Workout", "Running", "Commute", "Study", "Sleep", "Party", "Cooking", "Road trip", "Focus", "Romance"].map {
        MusicCategory(name: $0, kind: .mood, target: .search($0.lowercased() + " music"))
    }

    // MARK: languages and categories

    /// Languages of the chosen country's charts, then of everything else on the page (never the person's plays, choices or device language: Explore is the same for everyone); nothing is listed by the app.
    @ViewBuilder private func languageSection(_ composed: MusicExploreComposition.Result) -> some View {
        let regional = [composed.charts, composed.releases].compactMap { $0 }
        let derived = MusicDerivedLanguages.derive(.init(preferredLanguages: [], library: [],
                                                         region: region.isEmpty ? [:] : MusicDerivedLanguages.counts(in: regional),
                                                         other: MusicDerivedLanguages.counts(in: (region.isEmpty ? regional : []) + composed.worldwide + composed.more)))
        let list = MusicDerivedLanguages.tiles(MusicDerivedLanguages.withBaseline(derived), expanded: languagesExpanded)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Languages"))
                MusicCategoryGrid(categories: list, owner: "explore.languages") { c in open(c) }
            }
        }
    }

    @ViewBuilder private var moodAndGenre: some View {
        switch categories {
        case nil, .loading?:
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Mood & genre"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicCategoryTileLayout.spacing),
                                         count: MusicCategoryTileLayout.columns(width: 0, cls: cls)), spacing: MusicCategoryTileLayout.spacing) {
                    ForEach(0..<8, id: \.self) { _ in
                        Color.clear.aspectRatio(MusicCategoryTileLayout.aspect, contentMode: .fit)
                            .overlay { MusicSkeletonBlock(width: nil, height: MusicCardGeometry.coverSide(width: MusicCategoryTileLayout.minTileWidth) / MusicCategoryTileLayout.aspect, corner: MusicCorner.card) }
                    }
                }
            }
            .accessibilityHidden(true)
        case .failed?:
            MusicErrorState(title: Localized.string("Moods and genres could not be loaded."), retryTitle: Localized.string("Try again")) { categoryRetries += 1 }
        case .loaded(let list)?:
            let arranged = MusicDerivedGenres.arrange(provider: list, library: [])
            if !arranged.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.lg) {
                    ForEach(MusicCategoryKind.allCases.filter { $0 != .language }, id: \.self) { kind in
                        let group = arranged.filter { $0.kind == kind }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                                MusicSectionTitle(title: kind == .mood ? Localized.string("Moods & moments") : Localized.string("Genres"))
                                MusicCategoryGrid(categories: group, owner: "explore.\(kind.rawValue)") { open($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func open(_ c: MusicCategory) {
        if c.isToggle { languagesExpanded.toggle(); let now = languagesExpanded; MusicDebugLog.log("explore", "language tiles expanded=\(now)"); return }
        switch c.target {
        case .genre(var g):
            if g.thumbnails.isEmpty { g.thumbnails = c.thumbnails }   // the page's cover is the tile's cover (a cached tile keeps its picture; the rebuilt genre has none)
            hub.open(.genre(g))
        // Stays inside Explore: a page of its own, with a Back pill to Explore (a language is not a trip to Listen Now or to Search).
        case .search(let q): hub.open(.genre(MusicBrowseGenre(id: "search:" + q, name: c.name, thumbnails: c.thumbnails, stableName: c.stableName)))
        }
    }

    // MARK: loading

    /// Each source loads on its own; a slow or failing one never holds back the others, and a failure leaves its part out.
    private func loadDiscovery() async {
        guard !hub.gated else { return }
        let asked = retries != drawnRetries
        drawnRetries = retries
        shelfSeed = MusicShelfVariety.seed("explore", refresh: asked)
        let list = providers, region = self.region
        MusicDebugLog.log("explore", "loadDiscovery region \(region.isEmpty ? "worldwide" : region), sources \(list.map(\.id).joined(separator: ","))")
        let wanted = Set(list.map(\.id))
        if discoveryRegion != region { discovery = [:]; discoveryRegion = region }
        discovery = discovery.filter { wanted.contains($0.key) }
        for p in list {
            let key = p.id + "|" + (p is any MusicRegionalDiscovery ? region : "") + "|" + Localized.activeCode
            if let hit = MusicExploreMemory.sections(key) { discovery[p.id] = .loaded(hit) } else { discovery[p.id] = .loading }
        }
        await withTaskGroup(of: (String, [MusicBrowseSection]?).self) { group in
            for p in list {
                let key = p.id + "|" + (p is any MusicRegionalDiscovery ? region : "") + "|" + Localized.activeCode
                if MusicExploreMemory.sections(key) != nil { continue }
                group.addTask {
                    // A slow first answer gets one more try that joins the request still running (see `MusicHomeLoaders.secondChance`); a source that
                    // misses both leaves its part out.
                    for limit in [MusicHomeLoaders.sourceDeadline, MusicHomeLoaders.secondChance] {
                        if Task.isCancelled { return (p.id, nil) }
                        let fetched: [MusicBrowseSection]?
                        do {
                            fetched = try await MusicStreamResolver.withDeadline(limit, {
                                if let regional = p as? any MusicRegionalDiscovery { return try await MusicDiscoveryFetch.regional(regional, providerID: p.id, region: region) }
                                return try await MusicDiscoveryFetch.featured(p)
                            })
                        } catch {
                            // Only a slow answer earns a second try; a source that fails at once (a country it has no lists for) is left out.
                            if case MusicError.network(let m) = error, m == "timed out" { continue }
                            break
                        }
                        if let raw = fetched {
                            // Matching to playable copies has its own time; when it runs out the fetched lists are kept as they are instead of dropping the source.
                            let resolved = try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.secondChance) { await Self.catalogueResolved(raw, from: p) }
                            return (p.id, resolved ?? raw)
                        }
                    }
                    return (p.id, nil)
                }
            }
            for await (id, result) in group where !Task.isCancelled {
                if let result, !result.isEmpty, let p = list.first(where: { $0.id == id }) {
                    MusicDebugLog.log("explore", "\(id) answered for \(region.isEmpty ? "worldwide" : region): \(result.count) shelves \(result.map { "\($0.id)=\($0.items.count)" }.joined(separator: " "))")
                    MusicExploreMemory.setSections(result, key: id + "|" + (p is any MusicRegionalDiscovery ? region : "") + "|" + Localized.activeCode)
                    discovery[id] = .loaded(result)
                } else { discovery[id] = .failed("") }
            }
        }
    }

    /// A catalogue-only source's song shelves show only songs with a verified playable copy (the one implementation Home uses; shelves are checked at the same time).
    private static func catalogueResolved(_ sections: [MusicBrowseSection], from provider: any MusicMetadataProvider) async -> [MusicBrowseSection] {
        await MusicHomeLoaders.resolve(sections, from: provider, strict: false)
    }

    private func loadCategories() async {
        let key = (hub.registry.activeMetadata?.id ?? "none") + "|" + Localized.activeCode
        if let hit = MusicExploreMemory.categories(key) { categories = .loaded(hit); await installCoverSource(); return }
        categories = .loading
        let source = hub.registry.activeMetadata, gated = hub.gated
        var found = await MusicDiscoveryFetch.categories(sourceID: key) {
            var found: [MusicCategory] = []
            if let source, !gated {
                if let yt = source as? YouTubeMusicFullProvider, let moods = try? await yt.moodSections() {
                    for sec in moods {
                        let kind = MusicCategoryCatalogue.kind(forSection: sec.title)
                        for t in sec.tiles { found.append(MusicCategory(name: t.title, kind: kind, target: .genre(MusicBrowseGenre(id: t.params, name: t.title)))) }
                    }
                } else if let genres = try? await source.genres() {
                    found = genres.map { MusicCategory(name: $0.name, kind: .genre, target: .genre($0), thumbnails: $0.thumbnails) }
                }
            }
            return found
        }
        if Task.isCancelled { return }
        found = MusicCategory.unique(found)
        let tileCount = found.count
        MusicDebugLog.log("explore", "categories from \(key): \(tileCount) tiles (no built-in list)")
        // An empty answer (a failed or gated fetch) is shown as empty but never remembered, so the next visit asks again.
        if !found.isEmpty { MusicExploreMemory.setCategories(found, key: key) }
        categories = found.isEmpty && !gated ? .failed("") : .loaded(found)   // an empty answer says so and offers a retry
        await installCoverSource()
    }

    private func installCoverSource() async { MusicGenreArtwork.shared.useSource(hub.registry.activeMetadata) }
}

// MARK: - Hero

/// A restrained featured item: its cover on a blurred backdrop of itself, a readable scrim, the name, Play and Open. It does not rotate.
struct MusicExploreHero: View {
    let hub: MusicHub
    let item: MusicBrowseItem
    let isNewRelease: Bool
    let regionName: String
    var isWorldwide = false
    @Environment(\.musicLayoutClass) private var cls
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func height(for cls: MusicLayoutClass) -> CGFloat {
        switch cls { case .compact: 200; case .medium: 220; case .expanded: 250; case .wide: 270 }
    }
    private var coverSide: CGFloat { MusicExploreHero.height(for: cls) - MusicSpace.xxl * 2 }
    private var entity: MusicEntity { MusicExploreComposition.entity(item) }
    private var thumbs: [MusicThumbnail] { MusicExploreComposition.thumbs(item) }
    private var isArtist: Bool { if case .artist = item { true } else { false } }
    private var eyebrow: String { isNewRelease ? Localized.string("New release") : (isWorldwide ? Localized.string("Top worldwide") : Localized.string("Top chart in %@", regionName)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous)
        HStack(alignment: .center, spacing: MusicSpace.xl) {
            if cls >= .medium {
                MusicCoverImage(thumbs: thumbs, artworkClass: .hero, size: coverSide, corner: isArtist ? coverSide / 2 : MusicCorner.card).artwork(of: .derive(entity))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: eyebrow).musicText(.caption).foregroundStyle(MusicInk.onArtworkSecondary)
                Text(verbatim: MusicExploreComposition.title(item)).musicText(.page).foregroundStyle(MusicInk.onArtwork).lineLimit(2)
                let sub = MusicExploreComposition.subtitle(item)
                if !sub.isEmpty { Text(verbatim: sub).musicText(.body).foregroundStyle(MusicInk.onArtworkSecondary).lineLimit(1) }
                HStack(spacing: MusicSpace.xs) {
                    Button { Task { await MusicEntityActions.play(entity, hub: hub) } } label: { Label(Localized.string("Play"), systemImage: "play.fill") }
                        .musicButton(.hero, size: .large)
                        .accessibilityLabel(Localized.string("Play %@", MusicExploreComposition.title(item))).atlas("control.music.exploreHeroPlay")
                    Button { MusicEntityActions.open(entity, hub: hub) } label: { Label(Localized.string("Open"), systemImage: "arrow.up.right") }
                        .musicButton(.secondary, size: .large)
                        .accessibilityLabel(Localized.string("Open %@", MusicExploreComposition.title(item))).atlas("control.music.exploreHeroOpen")
                }
                .padding(.top, MusicSpace.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(MusicSpace.xl)
        .frame(maxWidth: .infinity, minHeight: MusicExploreHero.height(for: cls), alignment: .leading)
        .background { MusicHeroBackdrop(thumbs: thumbs) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
        .accessibilityElement(children: .contain)
    }
}
