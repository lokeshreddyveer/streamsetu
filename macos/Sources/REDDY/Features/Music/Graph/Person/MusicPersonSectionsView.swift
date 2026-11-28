import SwiftUI

/// The sections of the active role, drawn in the owner's order. A section with nothing in it is not drawn (no heading, no empty line). The role files
/// (`PersonSingerSections` and the others) add the drawing of their own sections as extensions of this view.
struct MusicPersonSectionsView: View {
    let hub: MusicHub
    let data: MusicPersonViewData
    let name: String
    let playback: MusicPersonPlayback
    let memoryKey: String
    /// When set, a language chip opens the artist's Songs pill filtered to that language (one language filter for the page) instead of filtering these shelves in place.
    var exploreLanguage: ((String) -> Void)?
    @State var expanded: Set<String>
    /// The language chosen on the Languages chips: every shelf then shows only that language's songs and albums (nil shows everything).
    @State var languageFilter: String?
    @Environment(\.musicLayoutClass) var layoutClass

    init(hub: MusicHub, data: MusicPersonViewData, name: String, playback: MusicPersonPlayback, memoryKey: String, exploreLanguage: ((String) -> Void)? = nil) {
        self.hub = hub; self.data = data; self.name = name; self.playback = playback; self.memoryKey = memoryKey; self.exploreLanguage = exploreLanguage
        _expanded = State(initialValue: MusicPageMemoryCenter.shared.memory(for: memoryKey).expandedSections)
    }

    /// The sections as drawn: all of them, or with a language chosen, each shelf cut to the entries of that language and the shelves left empty dropped. An entry
    /// that does not say its language is not shown under a language (nothing is guessed). The Languages shelf itself stays, so the choice can be changed.
    var shownSections: [MusicPersonSection] {
        guard let f = languageFilter else { return data.visible }
        return data.visible.compactMap { s in
            if s.id == .languages { return s }
            let kept = s.entries.filter { MusicPersonReader.languageCode($0.lang) == f }
            return kept.isEmpty ? nil : MusicPersonSection(s.id, kept, total: kept.count)
        }
    }

    var cardWidth: CGFloat { MusicGraphCardWidth.width(for: layoutClass) }

    var body: some View {
        // A plain VStack, not a lazy one: a page is a handful of sections whose heights change as their data lands, and a lazy stack only estimates the
        // height of what it has not drawn, then corrects it while the person scrolls, which moves the scroll offset (the page jumps back). Long lists
        // inside a section stay lazy.
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            ForEach(shownSections) { s in section(s) }
            if !data.complete { MusicShelfSkeleton(width: cardWidth, count: 4).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    @ViewBuilder private func section(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .topSongs, .albums, .singles, .filmSongs, .playbackSongs, .collaborations, .composersWorkedWith, .languages, .relatedArtists, .playlists, .radio:
            if data.view == .singer { singerSection(s) } else { sharedSection(s) }
        case .popularCompositions, .soundtracks, .films, .singersWorkedWith, .lyricistsWorkedWith, .relatedComposers: composerSection(s)
        case .songsWritten, .composers, .singers, .frequentCollaborators: lyricistSection(s)
        case .filmography, .popularMovies, .movieSoundtracks, .songsFromMovies, .coStars, .directorsWorkedWith, .relatedCinema:
            if data.view == .actor { actorSection(s) } else { sharedSection(s) }
        case .filmSoundtracks, .composersCollaborated, .frequentCast, .relatedFilms: directorSection(s)
        case .memberOf, .members, .influencedBy, .influenced: peopleShelf(s)
        case .soloCareers: albumShelf(s)
        case .producedSongs, .instrumentSongs, .conductedSongs, .labelCatalogue: songList(s)
        }
    }

    /// Sections that more than one role draws the same way (albums of a composer, films of a lyricist...).
    @ViewBuilder func sharedSection(_ s: MusicPersonSection) -> some View {
        switch s.id {
        case .albums, .singles, .soundtracks, .movieSoundtracks, .filmSoundtracks: albumShelf(s)
        case .films, .filmography, .popularMovies, .relatedCinema, .relatedFilms: filmShelf(s)
        case .topSongs, .popularCompositions, .songsWritten, .filmSongs, .playbackSongs, .songsFromMovies: songList(s)
        default: peopleShelf(s)
        }
    }

    // MARK: shelves

    @ViewBuilder func shelf<C: View>(_ s: MusicPersonSection, subtitle: String? = nil, @ViewBuilder card: @escaping (MusicPersonEntry) -> C) -> some View {
        let title = MusicPersonWording.sectionTitle(s.id, name: name)
        if s.entries.count > 6 {
            MusicShelf(title: title, subtitle: subtitle) { ForEach(s.entries.prefix(12)) { card($0) } } showAll: { ForEach(s.entries) { card($0) } }
        } else {
            MusicShelf(title: title, subtitle: subtitle) { ForEach(s.entries) { card($0) } }
        }
    }

    @ViewBuilder func albumShelf(_ s: MusicPersonSection) -> some View {
        shelf(s) { e in
            MusicGraphAlbumCard(title: e.name, subtitle: albumCaption(e), imageRef: MusicPersonImage.address(e.imageRef), reason: MusicPersonWording.reason(e.reason),
                                tag: MusicGraphTag(status: e.status ?? .verified, level: .film, forFilmLink: e.filmID != nil), width: cardWidth, entity: e.id) { hub.open(e.id) }
        }
    }

    @ViewBuilder func filmShelf(_ s: MusicPersonSection) -> some View {
        shelf(s) { e in MusicPersonFilmCard(hub: hub, entry: e, width: cardWidth) }
    }

    @ViewBuilder func peopleShelf(_ s: MusicPersonSection) -> some View {
        shelf(s) { e in
            MusicGraphPersonCard(name: e.name, caption: MusicPersonWording.roleCaption(e.roles),
                                 imageRef: MusicPersonImage.address(e.imageRef), reason: MusicPersonWording.reason(e.reason), width: cardWidth, entity: e.id) { hub.open(e.id, role: e.openRole) }
        }
    }

    func albumCaption(_ e: MusicPersonEntry) -> String? {
        if let f = e.filmTitle { return e.year.map { "\(f) · \($0)" } ?? f }
        if let d = e.detail { return e.year.map { "\(d) · \($0)" } ?? d }
        return e.year.map(String.init)
    }

    // MARK: song lists

    func songList(_ s: MusicPersonSection) -> some View {
        let open = expanded.contains(s.id.rawValue)
        let shown = open ? s.entries : Array(s.entries.prefix(5))
        return VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack {
                MusicSectionTitle(title: MusicPersonWording.sectionTitle(s.id, name: name))
                Spacer()
                if s.entries.count > 5 {
                    Button(open ? Localized.string("Show less") : MusicPersonWording.showAll(s.entries.count)) { toggle(s.id) }
                        .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                        .frame(minHeight: MusicTokens.hitTarget).hoverHighlight().atlas("control.music.personShowAll")
                }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                let rest = shown.dropFirst(i + 1).map(\.id)
                MusicPersonSongRow(entry: e, hub: hub, play: { Task { await playback.playSong(e.id, queue: rest) } })
            }
        }
    }

    private func toggle(_ id: MusicPersonSectionID) {
        if expanded.contains(id.rawValue) { expanded.remove(id.rawValue) } else { expanded.insert(id.rawValue) }
        let now = expanded
        MusicPageMemoryCenter.shared.update(memoryKey) { $0.expandedSections = now }
    }
}
