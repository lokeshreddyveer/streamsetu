import SwiftUI

/// The page of a film or a series (routes `.film(id)` and `.series(id)`): poster, title, year and languages, the cast, the crew, the film's soundtrack
/// albums and songs with their singers, related films and music, and Watch Movie when the film is in the person's library.
///
/// Opening it reads what the graph already holds and shows it at once; the sections fill in as the graph and its sources answer, and an outage only
/// means fewer sections. Audio is never touched here: music keeps playing while the page is open (decision D5), pressing Watch Movie only opens the
/// app's own movie page, and the music queue stays put until the person presses Play on the movie, when the app's audio ownership pauses music.
struct MusicFilmPage: View {
    let entity: MusicEntityID
    let hub: MusicHub
    @State private var tab: Tab
    @State private var languageFilter: MusicFilmLanguageFilter = .all
    @State private var crewQuery: String
    @State private var model = MusicFilmGraphModel(center: MusicEntityRuntime.shared.center, watch: .host(), matcher: MusicFilmCatalogueMatch.run)

    /// The page's memory key is its route key, so history Back and Forward carry the tab and the crew search along with the scroll offset.
    private var memoryKey: String { MusicRoute.node(MusicEntityRoute(entity)).scrollKey }

    init(entity: MusicEntityID, hub: MusicHub) {
        self.entity = entity
        self.hub = hub
        let key = MusicRoute.node(MusicEntityRoute(entity)).scrollKey
        let filters = MusicPageMemoryCenter.shared.memory(for: key).filters
        _tab = State(initialValue: filters["filmTab"].flatMap(Tab.init(memoryName:)) ?? .overview)
        _crewQuery = State(initialValue: filters["filmCrewQuery"] ?? "")
        _languageFilter = State(initialValue: filters["filmLanguage"].flatMap(MusicFilmLanguageFilter.init(memoryName:)) ?? .all)
    }

    var body: some View {
        MusicPageScaffold(hub: hub, thumbs: MusicGraphThumbs.thumbs(model.overview?.imageRef ?? model.entity?.snapshot?.imageRef)) {
            if MusicFranchise.isFranchise(model.entity?.snapshot?.subkind) {
                MusicErrorState(title: Localized.string("This is a franchise, not a film."), message: Localized.string("Open one of its films to see the franchise."))
            } else if model.phase == .failed {
                MusicErrorState(title: Localized.string("This %1$@ is not available right now.", entity.kind == .series ? Localized.string("Series") : Localized.string("Film")),
                                message: Localized.string("Go back and try again in a moment."), retryTitle: Localized.string("Try again")) { model.reload(); model.resolveUnplayable() }
            } else {
                MusicFilmHeader(model: model, hub: hub) { tab = .about }
                MusicCompletenessLine(id: model.entity?.id ?? entity)
                tabBar
                if let key = failedKey, model.section(key).phase == .failed { MusicErrorState(title: Localized.string("This part could not be loaded."), retryTitle: Localized.string("Try again")) { model.retry() } }
                switch tab {
                case .overview:
                    MusicFilmCastSection(model: model, hub: hub, seeAll: { tab = .cast })
                    MusicFilmCrewSection(model: model, hub: hub)
                    music
                    MusicFilmRelatedSection(model: model, hub: hub)
                case .songs:
                    MusicFilmLanguageChips(options: languageOptions, selection: $languageFilter)
                    MusicFilmSongsSection(model: model, hub: hub, filter: languageFilter)
                case .albums:
                    MusicFilmLanguageChips(options: languageOptions, selection: $languageFilter)
                    MusicFilmSoundtracksSection(model: model, hub: hub, part: has(.score) ? .withoutScore : .all, filter: languageFilter)
                case .score: MusicFilmSoundtracksSection(model: model, hub: hub, part: .scoreOnly)
                case .videos: MusicFilmVideosSection(model: model, hub: hub)
                case .gallery: MusicFilmGallerySection(model: model)
                case .cast: MusicFilmCastSection(model: model, hub: hub, limit: 400, grouped: true)
                case .crew:
                    MusicFilmCrewSearchField(text: $crewQuery)
                    MusicFilmCrewSection(model: model, hub: hub, musicOnly: true, query: crewQuery)
                    MusicFilmCrewSection(model: model, hub: hub, musicOnly: false, query: crewQuery)
                case .about: MusicFilmAboutSection(model: model, hub: hub)
                }
            }
        }
        .onAppear { model.canAsk = { MusicCatalogRuntime.shared.isEnabled }; model.open(entity); model.refreshWatch(gated: hub.gated); model.resolveUnplayable() }   // a reopened page has its songs already, so the phase never changes: ask for copies now
        .onDisappear { model.close() }
        .onChange(of: Tab.allCases.filter(has)) { settleTab() }
        .onChange(of: languageOptions) { settleLanguage() }
        .onChange(of: languageFilter) { _, now in MusicPageMemoryCenter.shared.update(memoryKey) { $0.filters["filmLanguage"] = now.memoryName } }
        .onChange(of: tab) { _, now in MusicPageMemoryCenter.shared.update(memoryKey) { $0.filters["filmTab"] = now.memoryName } }
        .onChange(of: crewQuery) { _, now in MusicPageMemoryCenter.shared.update(memoryKey) { $0.filters["filmCrewQuery"] = now.isEmpty ? nil : now } }
        .onChange(of: model.phase) { model.refreshWatch(gated: hub.gated) }
        .onChange(of: hub.gated) { model.refreshWatch(gated: hub.gated) }
        .onChange(of: model.section(MusicFilmSectionKey.songs).phase) { model.resolveUnplayable(); settleTab() }
        .onChange(of: model.section(MusicFilmSectionKey.soundtracks).phase) { settleTab(); settleLanguage() }
        .onChange(of: model.section(MusicFilmSectionKey.overview).phase) { model.refreshWatch(gated: hub.gated); settleTab() }
        .atlasScreen("screen.music.film")
    }

    /// A remembered pill the film does not have falls back to Overview, but only once the sections that decide that pill have answered: Videos and Gallery appear when the
    /// overview arrives and Score when the songs and soundtracks have, so a list that is still growing must not throw a remembered pill away. The pill list and each of these
    /// sections call it as they change, since the list may never change again after the last answer.
    private func settleTab() {
        guard !has(tab) else { return }
        let deciding = tab.decidingSections
        if deciding.allSatisfy({ [.loaded, .empty, .failed].contains(model.section($0).phase) }) { tab = .overview }
    }

    /// A remembered language that the film has no dub for goes back to All, but only once the soundtracks have answered (the chips come from them).
    private func settleLanguage() {
        guard languageFilter != .all, !languageOptions.contains(languageFilter) else { return }
        if [.loaded, .empty, .failed].contains(model.section(MusicFilmSectionKey.soundtracks).phase) { languageFilter = .all }
    }

    /// The destinations of the film. Overview is the whole page; each other pill is one real section, shown only when the film has it.
    enum Tab: CaseIterable, Hashable {
        case overview, songs, albums, score, videos, gallery, cast, crew, about
        var memoryName: String {
            switch self {
            case .overview: "overview"
            case .songs: "songs"
            case .albums: "albums"
            case .score: "score"
            case .videos: "videos"
            case .gallery: "gallery"
            case .cast: "cast"
            case .crew: "crew"
            case .about: "about"
            }
        }
        /// The sections whose answers decide whether the pill exists: until they have all answered a remembered pill is kept, however the pill list grows meanwhile.
        var decidingSections: [String] {
            switch self {
            case .overview, .about: []
            case .songs: [MusicFilmSectionKey.songs]
            case .albums, .score: [MusicFilmSectionKey.soundtracks, MusicFilmSectionKey.songs]
            case .videos: [MusicFilmSectionKey.overview, MusicFilmSectionKey.songs]   // music videos come from the songs
            case .gallery: [MusicFilmSectionKey.overview]
            case .cast: [MusicFilmSectionKey.cast]
            case .crew: [MusicFilmSectionKey.crew]
            }
        }
        init?(memoryName: String) {
            guard let t = Tab.allCases.first(where: { $0.memoryName == memoryName }) else { return nil }
            self = t
        }
        var title: String {
            switch self {
            case .overview: Localized.string("Overview")
            case .songs: Localized.string("Songs")
            case .albums: Localized.string("Albums")
            case .score: Localized.string("Score")
            case .videos: Localized.string("Videos")
            case .gallery: Localized.string("Gallery")
            case .cast: Localized.string("Cast")
            case .crew: Localized.string("Crew")
            case .about: Localized.string("About")
            }
        }
    }

    /// A pill stays while its section is still loading or has failed (so it does not appear late and move the others); it goes only when the section finished with nothing.
    private func has(_ t: Tab) -> Bool {
        func live(_ key: String) -> Bool { model.section(key).phase != .empty }
        switch t {
        case .overview, .about: return true
        case .songs:
            guard live(MusicFilmSectionKey.songs) else { return false }
            // Finished with songs, but every one is a background-score cue: the Songs page would be empty (the cues are on Score).
            if model.section(MusicFilmSectionKey.songs).phase == .loaded, !model.songs.isEmpty, !model.hasSongsOutsideScore, !model.scoreAlbums.isEmpty { return false }
            return true
        case .albums:
            // With a Score pill, the Albums pill needs an album that is not the background score (or a dubbed one), else its page would be empty.
            guard live(MusicFilmSectionKey.soundtracks) else { return false }
            if model.scoreAlbums.isEmpty { return true }
            return model.originalAlbums.contains { model.edition(of: $0) != .score } || !model.dubbedAlbums.isEmpty
        case .score: return !model.scoreAlbums.isEmpty
        case .videos: return !(model.overview?.videos.isEmpty ?? true) || !model.musicVideos.isEmpty
        case .gallery: return !(model.overview?.gallery.isEmpty ?? true)
        case .cast: return live(MusicFilmSectionKey.cast)
        case .crew: return live(MusicFilmSectionKey.crew)
        }
    }

    /// The section a tab shows, so a failed one says so (with a retry) instead of leaving the tab blank.
    private var failedKey: String? {
        switch tab {
        case .songs: MusicFilmSectionKey.songs
        case .albums, .score: MusicFilmSectionKey.soundtracks
        case .videos, .gallery: MusicFilmSectionKey.overview
        case .cast: MusicFilmSectionKey.cast
        case .crew: MusicFilmSectionKey.crew
        case .overview: [MusicFilmSectionKey.cast, MusicFilmSectionKey.crew, MusicFilmSectionKey.soundtracks, MusicFilmSectionKey.songs].first { model.section($0).phase == .failed }
        case .about: MusicFilmSectionKey.overview
        }
    }

    /// The chips of the language switcher: only when the film has a dubbed soundtrack edition.
    private var languageOptions: [MusicFilmLanguageFilter] { MusicFilmLanguageFilter.options(dubLanguages: model.albums.map(\.dubLanguage)) }

    @ViewBuilder private var tabBar: some View {
        let tabs = Tab.allCases.filter(has)
        if tabs.count > 1 {
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(tabs, id: \.self) { t in MusicChip(title: t.title, selected: tab == t) { tab = t } }
            }
        }
    }

    /// The film's music, or one quiet line when none is found. Never an empty heading.
    @ViewBuilder private var music: some View {
        switch model.musicPlan {
        case .showSections:
            MusicFilmSoundtracksSection(model: model, hub: hub)
            MusicFilmSongsSection(model: model, hub: hub)
        case .loading:
            MusicShelfSkeleton().accessibilityHidden(true)
        case .failed:
            MusicErrorState(title: Localized.string("The music of this film could not be loaded."), retryTitle: Localized.string("Try again")) { model.retry() }
        case .noSoundtrack:
            Label { Text(verbatim: Localized.string("No soundtrack found")).musicText(.caption) } icon: { Image(systemName: "music.note").font(.system(size: MusicIconSize.tiny)) }
                .foregroundStyle(ColorTokens.textTertiary)
                .accessibilityElement(children: .combine)
        }
    }
}

/// Finds playable copies of catalogue rows through the app's matcher (nothing when the catalogue setting is off). Runs off the main actor.
enum MusicFilmCatalogueMatch {
    static let run: MusicFilmGraphModel.Matcher = { rows in
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, let m = rt.matcher else { return rows.map { _ in nil } }
        var out = await m.playable(rows, budget: 10)
        // A row with no answer may only have run out of the budget: its lookup goes on in the background, so asking those rows again joins it (or, for a row that really
        // has no copy, is answered at once from the saved "no match"). The page marks every row it sent as asked, so this is the one retry.
        let slow = out.indices.filter { out[$0] == nil && (rows[$0].directStreams ?? []).isEmpty }
        if !slow.isEmpty, !Task.isCancelled {
            let again = await m.playable(slow.map { rows[$0] }, budget: 10)
            for (k, i) in slow.enumerated() where k < again.count { out[i] = again[k] }
        }
        return out
    }
}
