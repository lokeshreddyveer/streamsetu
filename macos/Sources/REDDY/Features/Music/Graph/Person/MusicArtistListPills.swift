import SwiftUI

/// The Songs pill: every recording of the active role view, with search, filters, sort and Play / Shuffle on exactly what is filtered. The list is lazy and shows
/// `MusicArtistPlayCap.pageSize` rows at a time, so a large catalog never builds all its rows.
struct MusicArtistSongsView: View {
    let hub: MusicHub
    let catalog: MusicArtistCatalog
    let playback: MusicPersonPlayback
    @Bindable var state: MusicArtistPageState
    @State private var shown = MusicArtistPlayCap.pageSize

    var body: some View {
        let list = state.songs.apply(to: catalog.songs, year: state.year, personal: state.personal)
        let languages = MusicArtistFacets.languages(in: catalog.songs), decades = MusicArtistFacets.decades(in: catalog.songs), films = MusicArtistFacets.films(in: catalog.songs)
        let performances = MusicSongPerformance.facets(in: catalog.songs)
        let years = Array(Set(catalog.songs.compactMap(\.year).filter { (1850...2100).contains($0) })).sorted(by: >)
        let likedHere = state.personal.hasLikes && catalog.songs.contains { state.personal.isLiked($0) }
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSectionTitle(title: MusicArtistWording.songsTitle(catalog.view))
            MusicSheetField(placeholder: Localized.string("Search these songs"), text: $state.songs.query, atlas: "control.music.artistSongSearch")
            MusicChipFlow(spacing: MusicSpace.xs) {
                if MusicArtistChipRules.offered(languages.count, above: 1, selected: state.songs.language != nil) {
                    MusicMenuChip(label: Localized.string("Language"), anyTitle: Localized.string("Any language"),
                                  options: languages.map { (value: $0.code, title: MusicPersonReader.languageName($0.code) + " · \($0.count)") }, selection: $state.songs.language, atlas: "control.music.artistSongLanguage")
                }
                if MusicArtistChipRules.offered(decades.count, above: 1, selected: state.songs.decade != nil) {
                    MusicMenuChip(label: Localized.string("Decade"), anyTitle: Localized.string("Any decade"),
                                  options: decades.map { (value: $0.decade, title: MusicPersonWording.filterDecade($0.decade) + " · \($0.count)") }, selection: $state.songs.decade, atlas: "control.music.artistSongDecade")
                }
                if MusicArtistChipRules.offered(films.count, above: 1, selected: state.songs.film != nil) {
                    MusicMenuChip(label: Localized.string("Film"), anyTitle: Localized.string("Any film"),
                                  options: films.map { (value: $0.key, title: $0.title + " · \($0.count)") }, selection: $state.songs.film, atlas: "control.music.artistSongFilm")
                }
                if MusicArtistChipRules.offered(performances.count, above: 0, selected: state.songs.performance != nil) {
                    MusicMenuChip(label: Localized.string("Type"), anyTitle: Localized.string("Any type"),
                                  options: performances.map { (value: $0.kind, title: MusicArtistWording.performanceTitle($0.kind) + " · \($0.count)") }, selection: $state.songs.performance, atlas: "control.music.artistSongType")
                }
                if MusicArtistChipRules.offered(years.count, above: 1, selected: state.songs.yearFrom != nil || state.songs.yearTo != nil) {
                    MusicMenuChip(label: Localized.string("From year"), anyTitle: Localized.string("Any year"),
                                  options: years.reversed().map { (value: $0, title: String($0)) }, selection: $state.songs.yearFrom, atlas: "control.music.artistSongYearFrom")
                    MusicMenuChip(label: Localized.string("To year"), anyTitle: Localized.string("Any year"),
                                  options: years.map { (value: $0, title: String($0)) }, selection: $state.songs.yearTo, atlas: "control.music.artistSongYearTo")
                }
                if likedHere || state.songs.likedOnly {
                    MusicChip(title: Localized.string("Liked"), selected: state.songs.likedOnly, systemImage: "heart") { state.songs.likedOnly.toggle() }.atlas("control.music.artistSongLiked")
                }
                MusicMenuChip(label: Localized.string("Sort"), anyTitle: Localized.string("Default order"),
                              options: MusicArtistSongSort.allCases.filter { $0 != .mostPlayed || state.personal.hasPlays }.map { (value: $0, title: MusicArtistWording.sortTitle($0)) }, selection: $state.songs.sort, atlas: "control.music.artistSongSort")
                MusicArtistYearChip(state: state)
            }
            actions(list)
            if list.isEmpty {
                MusicEmptyState(symbol: "magnifyingglass", title: Localized.string("No songs match."), message: Localized.string("Try removing a filter or changing the words you searched."), actionTitle: Localized.string("Clear filters")) { state.clearSongFilters() }
            } else {
                LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    ForEach(Array(list.prefix(shown).enumerated()), id: \.element.id) { i, e in
                        MusicPersonSongRow(entry: e, hub: hub, play: { let rest = list.dropFirst(i + 1).map(\.id); Task { await playback.playSong(e.id, queue: Array(rest.prefix(MusicArtistPlayCap.songs))) } }, role: MusicArtistWording.songRole(e))
                    }
                }
                if list.count > shown {
                    Button(Localized.string("Show more")) { shown += MusicArtistPlayCap.pageSize }.musicButton(.secondary).atlas("control.music.artistSongsMore")
                }
            }
        }
        .onChange(of: state.songs) { _, _ in shown = MusicArtistPlayCap.pageSize }
        .onChange(of: state.year) { _, _ in shown = MusicArtistPlayCap.pageSize }
    }

    @ViewBuilder private func actions(_ list: [MusicPersonEntry]) -> some View {
        let cap = MusicArtistPlayCap.songs
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await playback.playSet(MusicArtistPlayCap.play(list), shuffle: false) } } label: { Label(Localized.string("Play these"), systemImage: "play.fill") }
                .musicButton(.primary, size: .compact).disabled(list.isEmpty || playback.busy).atlas("control.music.artistSongsPlay")
            Button {
                var g = SystemRandomNumberGenerator()
                let ids = MusicArtistPlayCap.sample(list, cap: cap, using: &g)
                Task { await playback.playSet(ids, shuffle: true) }
            } label: { Label(Localized.string("Shuffle these"), systemImage: "shuffle") }
                .musicButton(.secondary, size: .compact).disabled(list.isEmpty || playback.busy).atlas("control.music.artistSongsShuffle")
            Text(verbatim: list.count > cap ? Localized.string("%1$d songs match. Play takes the first %2$d; Shuffle picks %2$d at random.", list.count, cap) : MusicArtistWording.count(songs: list.count))
                .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            // The list is what Music has found for this person so far, not a promise that nothing else exists.
            Text(Localized.string("These are the songs Music has found so far."))
                .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }
}

/// The Albums pill: albums, soundtracks and singles & EPs as a grid or a list, grouped by type, with a decade filter. Regional editions of one release are one row.
struct MusicArtistAlbumsView: View {
    let hub: MusicHub
    let catalog: MusicArtistCatalog
    @Bindable var state: MusicArtistPageState
    @State private var limit = 60
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let all = catalog.albums
        let types = MusicAlbumType.allCases.filter { t in all.contains { $0.type == t } }
        let decades = MusicArtistFacets.decades(in: all.map(\.entry))
        let scope = MusicArtistListScope(decade: state.albumDecade, language: nil, year: state.year)
        let kept = all.filter { (state.albumType == nil || $0.type == state.albumType) && !scope.apply(to: [$0.entry]).isEmpty }
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSectionTitle(title: Localized.string("Albums"))
            MusicChipFlow(spacing: MusicSpace.xs) {
                if MusicArtistChipRules.offered(types.count, above: 1, selected: state.albumType != nil) {
                    MusicChip(title: MusicPersonWording.filterAll, selected: state.albumType == nil) { state.albumType = nil }.atlas("control.music.artistAlbumType")
                    ForEach(types, id: \.self) { t in
                        MusicChip(title: MusicArtistWording.albumTypeTitle(t), selected: state.albumType == t) { state.albumType = state.albumType == t ? nil : t }.atlas("control.music.artistAlbumType")
                    }
                }
                if MusicArtistChipRules.offered(decades.count, above: 1, selected: state.albumDecade != nil) {
                    MusicMenuChip(label: Localized.string("Decade"), anyTitle: Localized.string("Any decade"),
                                  options: decades.map { (value: $0.decade, title: MusicPersonWording.filterDecade($0.decade) + " · \($0.count)") }, selection: $state.albumDecade, atlas: "control.music.artistAlbumDecade")
                }
                MusicChip(title: Localized.string("Grid"), selected: state.albumGrid, systemImage: "square.grid.2x2") { state.albumGrid = true }.atlas("control.music.artistAlbumLayout")
                MusicChip(title: Localized.string("List"), selected: !state.albumGrid, systemImage: "list.bullet") { state.albumGrid = false }.atlas("control.music.artistAlbumLayout")
                MusicArtistYearChip(state: state)
            }
            if kept.isEmpty {
                MusicEmptyState(symbol: "square.stack", title: Localized.string("No albums match."), message: Localized.string("Try removing a filter."), actionTitle: Localized.string("Clear filters")) { state.clearAlbumFilters() }
            }
            ForEach(groups(kept)) { g in
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    if types.count > 1 && state.albumType == nil { Text(verbatim: MusicArtistWording.albumTypeTitle(g.type)).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textSecondary) }
                    if state.albumGrid {
                        MusicCardGrid { ForEach(g.items) { a in card(a) } }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) { ForEach(g.items) { a in row(a) } }
                    }
                }
            }
            if kept.count > limit { Button(Localized.string("Show more")) { limit += 60 }.musicButton(.secondary).atlas("control.music.artistAlbumsMore") }
        }
    }

    private struct AlbumGroup: Identifiable { var type: MusicAlbumType; var items: [MusicArtistAlbum]; var id: Int { type.rawValue } }

    private func groups(_ kept: [MusicArtistAlbum]) -> [AlbumGroup] {
        var budget = limit
        var out: [AlbumGroup] = []
        for t in MusicAlbumType.allCases {
            let items = kept.filter { $0.type == t }
            guard !items.isEmpty, budget > 0 else { continue }
            out.append(AlbumGroup(type: t, items: Array(items.prefix(budget))))
            budget -= min(items.count, budget)
        }
        return out
    }

    private func caption(_ a: MusicArtistAlbum) -> String? {
        let e = a.entry
        var parts: [String] = []
        if let f = e.filmTitle { parts.append(f) } else if let d = e.detail { parts.append(d) }
        if let y = e.year { parts.append(String(y)) }
        if a.editions > 1 { parts.append(Localized.plural(a.editions, one: "%@ edition", other: "%@ editions")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func card(_ a: MusicArtistAlbum) -> some View {
        let e = a.entry
        return MusicGraphAlbumCard(title: e.name, subtitle: caption(a), imageRef: MusicPersonImage.address(e.imageRef), reason: MusicPersonWording.reason(e.reason),
                                   tag: MusicGraphTag(status: e.status ?? .verified, level: .film, forFilmLink: e.filmID != nil), width: MusicGraphCardWidth.width(for: layoutClass), entity: e.id) { hub.open(e.id) }
    }

    private func row(_ a: MusicArtistAlbum) -> some View {
        Button { hub.open(a.entry.id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: a.entry.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    if let c = caption(a) { Text(verbatim: c).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                Spacer()
            }
            .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().atlas("control.music.artistAlbumRow")
    }
}

/// The Films pill: poster cards with year, role and language, an industry filter (by language) and a decade filter. Opens the film's own page.
struct MusicArtistFilmsView: View {
    let hub: MusicHub
    let catalog: MusicArtistCatalog
    @Bindable var state: MusicArtistPageState
    /// The page's own person: on a director's page every film has them as director, so they are not offered as a director chip.
    var person: MusicEntityID? = nil
    @State private var limit = 48
    @State private var facts = MusicArtistFilmFacts.empty
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let industries = MusicArtistFacets.industries(in: catalog.films)
        let decades = MusicArtistFacets.decades(in: catalog.films)
        let scope = MusicArtistListScope(decade: state.filmDecade, language: state.filmLanguage, year: state.year)
        let soundtracks = MusicArtistFilmFilter.soundtrackFilms(catalog)
        let credits = MusicArtistFilmFilter.roles(in: catalog.films)
        let kept = state.filmFilter.apply(to: scope.apply(to: catalog.films), soundtracks: soundtracks, facts: facts)
        let directorChips = MusicArtistFilmFacts.chips(facts.directors, films: catalog.films, exclude: catalog.view == .director ? person : nil)
        let genreChips = MusicArtistFilmFacts.chips(facts.genres, films: catalog.films)
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSectionTitle(title: Localized.string("Films"))
            MusicChipFlow(spacing: MusicSpace.xs) {
                if MusicArtistChipRules.offered(credits.count, above: 1, selected: state.filmFilter.role != nil) {
                    MusicMenuChip(label: Localized.string("Credit"), anyTitle: Localized.string("Any credit"),
                                  options: credits.map { (value: $0.role, title: (MusicPersonWording.roleCaption([$0.role]) ?? $0.role.rawValue) + " · \($0.count)") }, selection: $state.filmFilter.role, atlas: "control.music.artistFilmCredit")
                }
                if catalog.films.contains(where: { soundtracks.contains($0.id) }) || state.filmFilter.withSoundtrack {
                    MusicChip(title: Localized.string("With soundtrack"), selected: state.filmFilter.withSoundtrack, systemImage: "music.note.list") { state.filmFilter.withSoundtrack.toggle() }.atlas("control.music.artistFilmSoundtrack")
                }
                if MusicArtistChipRules.offered(directorChips.count, above: 1, selected: state.filmFilter.director != nil) {
                    MusicMenuChip(label: Localized.string("Director"), anyTitle: Localized.string("Any director"),
                                  options: directorChips.map { (value: $0.facet.id, title: $0.facet.name + " · \($0.count)") }, selection: $state.filmFilter.director, atlas: "control.music.artistFilmDirector")
                }
                if MusicArtistChipRules.offered(genreChips.count, above: 1, selected: state.filmFilter.genre != nil) {
                    MusicMenuChip(label: Localized.string("Genre"), anyTitle: Localized.string("Any genre"),
                                  options: genreChips.map { (value: $0.facet.id, title: $0.facet.name + " · \($0.count)") }, selection: $state.filmFilter.genre, atlas: "control.music.artistFilmGenre")
                }
                if MusicArtistChipRules.offered(industries.count, above: 1, selected: state.filmLanguage != nil) {
                    MusicMenuChip(label: Localized.string("Industry"), anyTitle: Localized.string("Any industry"),
                                  options: industries.map { (value: $0.code, title: Localized.string($0.name) + " · \($0.count)") }, selection: $state.filmLanguage, atlas: "control.music.artistFilmIndustry")
                }
                if MusicArtistChipRules.offered(decades.count, above: 1, selected: state.filmDecade != nil) {
                    MusicMenuChip(label: Localized.string("Decade"), anyTitle: Localized.string("Any decade"),
                                  options: decades.map { (value: $0.decade, title: MusicPersonWording.filterDecade($0.decade) + " · \($0.count)") }, selection: $state.filmDecade, atlas: "control.music.artistFilmDecade")
                }
                MusicArtistYearChip(state: state)
            }
            if kept.isEmpty {
                MusicEmptyState(symbol: "film", title: Localized.string("No films match."), message: Localized.string("Try removing a filter."), actionTitle: Localized.string("Clear filters")) { state.clearFilmFilters() }
            } else {
                MusicCardGrid { ForEach(kept.prefix(limit)) { e in MusicPersonFilmCard(hub: hub, entry: e, width: MusicGraphCardWidth.width(for: layoutClass), extraLine: extra(e)) } }
                if kept.count > limit { Button(Localized.string("Show more")) { limit += 48 }.musicButton(.secondary).atlas("control.music.artistFilmsMore") }
            }
        }
        .task(id: "\(catalog.films.count)|\(catalog.films.first?.id.rawValue ?? "")") {
            facts = await MusicArtistFilmFacts.load(films: catalog.films, store: MusicEntityRuntime.shared.center.store.graph)
        }
        .onChange(of: state.filmFilter) { _, _ in limit = 48 }
    }

    /// The credited role (when the card does not already say "as <character>") and the film's language.
    private func extra(_ e: MusicPersonEntry) -> String? {
        var parts: [String] = []
        if e.detail == nil, let r = MusicPersonWording.roleCaption(e.roles) { parts.append(r) }
        if let c = MusicPersonReader.languageCode(e.lang) { parts.append(MusicPersonReader.languageName(c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
