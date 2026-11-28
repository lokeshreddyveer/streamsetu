import SwiftUI

/// The album / soundtrack page of the connected universe (sections A to D and the related shelf of the graph design; the "more by" shelves are `MusicAlbumConnectionShelves`), for an album or release entity route.
///
/// - A header, B songs: from the provider's data, in the first frame it has them; Play never waits for metadata.
/// - C credits, D cast: load at once (they are near the top), cancelled when the page goes away; the related albums draw nothing when they finish empty.
/// - Everything reads the shared entity model (the right panel's Related tab leases the same album), so a load exists once; when enrichment lands the
///   model refreshes the sections that had loaded and the page fills in without moving what is already drawn.
/// - A non-film album shows the header, the songs, its credits (artists, composers if any) and related albums (the more-by shelves come from the connection shelves): no film shelves,
///   no empty headings.
///
/// Open it with `MusicSoundtrackPage(entity: id, hub: hub)`; `MusicEntityPage.album` routes lead here.
struct MusicSoundtrackPage: View {
    let entity: MusicEntityID
    let hub: MusicHub
    @State private var page: MusicSoundtrackPageModel
    @State private var extras: MusicAlbumExtrasModel
    @State private var tab: MusicAlbumPill
    private let memoryKey: String

    /// `memoryKey` is the page's own route key, passed by a page that builds this one late (a provider album that was resolved first): the page on top
    /// of the stack may be another one by then.
    init(entity: MusicEntityID, hub: MusicHub, memoryKey routeKey: String? = nil) {
        self.entity = entity; self.hub = hub
        // Back returns to the pill the person was on (the page is rebuilt for each visit, so the choice is kept in the page memory).
        let key = routeKey ?? hub.nav.top?.scrollKey ?? MusicRoute.albumPage(entity).scrollKey
        self.memoryKey = key
        _tab = State(initialValue: MusicPageMemoryCenter.shared.memory(for: key).selectedTab.flatMap(MusicAlbumPill.init(rawValue:)) ?? .overview)
        _page = State(initialValue: MusicSoundtrackPageModel(entity: entity, hub: hub, memoryKey: routeKey))
        _extras = State(initialValue: MusicAlbumExtrasModel(entity: entity))
    }

    /// The pills of this album: only those with something behind them (a single with one song has none).
    private var pills: [MusicAlbumPill] {
        let credits = page.rawCredits.contains { !$0.isFilmCredit && MusicAlbumCreditGroup.of($0.role) != nil }
        let about = !extras.info.isEmpty   // the counts the header already shows are not a reason for a pill
        let listening = page.tracks.isEmpty ? false : MusicAlbumListeningSection.stats(page).hasAny
        return MusicAlbumPillRules.pills(.init(subkind: page.displayHeader?.subkind, trackCount: page.rows.count, hasFilm: page.displayHeader?.film != nil,
                                               hasVersions: !extras.versions.isEmpty   /* hidden editions keep the pill, so they can be restored */, hasCredits: credits, hasAbout: about, hasListening: listening))
    }

    var body: some View {
        let pills = self.pills
        MusicPageScaffold(hub: hub, thumbs: page.coverThumbs) {
            if page.model?.phase == .failed, page.rows.isEmpty, page.header == nil {
                MusicEmptyState(glyph: .note, title: Localized.string("This album is not available right now."),
                                message: Localized.string("Go back and try again in a moment."))
            } else {
                MusicSoundtrackHeaderSection(page: page, extras: extras, onSelect: { t in if pills.contains(t) { tab = t } }, pills: pills)
                MusicCompletenessLine(id: page.model?.id ?? entity)
                MusicAlbumPillBar(pills: pills, tab: $tab)
                switch pills.contains(tab) ? tab : .overview {
                case .overview:
                    MusicSoundtrackSongsSection(page: page)
                    MusicAlbumFilmCard(page: page)
                    // One credits block (music, singers, lyrics, director and the cast), then the albums that belong with this one. Each fact appears once:
                    // the film is in the header, the cast is in the credits, and the shelves below are only other albums.
                    MusicSoundtrackCreditsSection(page: page)
                    // A plain VStack, not a lazy one: a page is a handful of sections whose heights change as their data lands, and a lazy stack only estimates the
                    // height of what it has not drawn, then corrects it while the person scrolls, which moves the scroll offset (the page jumps back). Long lists
                    // inside a section stay lazy.
                    VStack(alignment: .leading, spacing: MusicSpace.xl) {
                        MusicAlbumConnectionShelves(hub: hub, album: entity, tracks: page.rows.compactMap { page.track(for: $0) })
                            .id(page.rows.count)   // built again when the songs arrive, so the playlist shelf sees them
                        MusicSoundtrackRelatedSection(page: page)
                    }
                case .tracks: MusicAlbumTracksSection(page: page, extras: extras, memoryKey: memoryKey)
                case .film:
                    MusicAlbumFilmCard(page: page)
                    MusicSoundtrackCreditsSection(page: page)
                    MusicSoundtrackRelatedSection(page: page)
                case .versions: MusicAlbumVersionsSection(page: page, extras: extras)
                case .credits: MusicAlbumCreditsSection(page: page)
                case .about: MusicAlbumAboutSection(page: page, extras: extras)
                case .listening: MusicAlbumListeningSection(page: page)
                }
            }
        }
        .onAppear { page.start(); extras.loadVersions() }
        .onDisappear { page.stop(); extras.stop() }
        .task(id: page.providerAlbum?.uid ?? "") { extras.loadInfo(provider: page.providerAlbum, force: true) }
        // The graph changed under the page (enrichment landed): the model refreshes its sections; the singer lines of the rows follow.
        .task(id: MusicEntityRuntime.shared.store.revision) {
            page.refineSingers()
            // Enrichment adds editions, facts and the album concept after the page opened: read them again (quietly, so the choices stay available).
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            page.graphChanged()
            extras.loadVersions(force: true)
            extras.loadInfo(provider: page.providerAlbum, force: true)
        }
        .onChange(of: tab) { _, t in MusicPageMemoryCenter.shared.update(memoryKey) { $0.selectedTab = t.rawValue } }
        .atlasScreen("screen.music.soundtrack")
    }
}
