import SwiftUI

/// The film's poster, title, year and languages, the synopsis when one is stored, Play and Shuffle for the soundtrack, and
/// Watch Movie. Everything that is not known yet is simply absent; the header does not move when it arrives.
struct MusicFilmHeader: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    /// Opens the film's About tab (the More menu's "View film info").
    var onViewInfo: () -> Void = {}
    @State private var expanded = false
    /// The link Share hands out, once the film's other ids are read (see `MusicFilmShare`).
    @State private var shareLink: URL?
    @Environment(\.reddyAccent) private var accent

    private let posterWidth: CGFloat = 200

    var body: some View {
        let o = model.overview
        let snap = model.entity?.snapshot
        let title = o?.title ?? snap?.name ?? Localized.string("Loading %1$@", model.isSeries ? Localized.string("Series") : Localized.string("Film"))
        HStack(alignment: .bottom, spacing: MusicSpace.xl) {
            MusicGraphCover(imageRef: o?.imageRef ?? snap?.imageRef, aspect: MusicGraphCardMetrics.posterAspect, corner: MusicCorner.card, seed: title,
                            subject: model.entity.map { MusicArtworkSubject(kind: model.isSeries ? .series : .film, name: title, id: $0.id, year: o?.year ?? snap?.year) }, slot: .poster)
                .frame(width: posterWidth)
                .shadow(color: ColorTokens.background.opacity(0.7), radius: MusicSpace.md, y: MusicSpace.xs)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: (model.isSeries ? Localized.string("Series") : Localized.string("Film"))).musicText(.caption).tracking(1.2)
                    .foregroundStyle(ColorTokens.textTertiary)
                Text(verbatim: title).font(Typography.pageTitle).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let ot = o?.originalTitle { Text(verbatim: ot).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                if let facts = factsLine(o, snap) { Text(verbatim: facts).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
                credits
                if let tag = o?.tagline { Text(verbatim: tag).musicText(.body).italic().foregroundStyle(ColorTokens.textTertiary).lineLimit(2) }
                if let g = o?.genres, !g.isEmpty {
                    // Plain text: a chip look would promise a tap that does nothing.
                    Text(verbatim: g.joined(separator: " · ")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                }
                if let line = soundtrackLine { Text(verbatim: line).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1) }
                synopsis(o)
                actions
                    .padding(.top, MusicSpace.xxs)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .top) { backdrop(o?.backdropURL) }
    }

    /// The film's own wide still as a real hero: large, sharp (asked at the hero size, never the card size), and faded into the page on its
    /// bottom and its text side so the words on it stay readable. Absent when the source has none.
    @ViewBuilder private func backdrop(_ url: String?) -> some View {
        if let url {
            MusicCoverImage(thumbs: [MusicThumbnail(url: url, width: 1280, height: 720)], size: nil, corner: 0, pixelHint: 1280)
                .artwork(of: nil, slot: .filmHero)
                .frame(maxWidth: .infinity).frame(height: Self.heroHeight).clipped()
                .opacity(0.62)
                .overlay(LinearGradient(colors: [ColorTokens.background.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing))
                // The bottom and the two sides fade away with masks, so no edge shows where the picture ends.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.35), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05), .init(color: .black, location: 0.95), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, -MusicSpace.xl).padding(.top, -MusicSpace.xl)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    private static let heroHeight: CGFloat = 400

    private func factsLine(_ o: MusicFilmOverview?, _ s: MusicEntitySnapshot?) -> String? {
        var parts: [String] = []
        if let d = o?.releaseDate { parts.append(MusicFilmAboutSection.displayDate(d)) } else if let y = o?.year ?? s?.year { parts.append(String(y)) }
        if let l = o?.languages, !l.isEmpty { parts.append(MusicFilmWording.joined(l)) }
        if !model.isSeries, let ind = MusicFilmIndustry.classify(language: s?.lang ?? o?.languages.first, country: s?.country) { parts.append(ind.title) }
        if let m = o?.runtimeMinutes { parts.append(MusicFilmAboutSection.runtime(m)) }
        if let c = o?.certification { parts.append(c) }
        if let r = o?.rating { parts.append("★ " + r) }
        if let n = o?.seasons { parts.append(Localized.string("Seasons: %1$@", String(n))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func synopsis(_ o: MusicFilmOverview?) -> some View {
        if let text = o?.synopsis, !text.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: text).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(expanded ? nil : 3)
                HStack(spacing: MusicSpace.xs) {
                    if text.count > 220 {
                        Button(expanded ? Localized.string("Show less") : Localized.string("Show more")) { expanded.toggle() }
                            .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.filmSynopsisMore")
                    }
                }
            }
        } else if let d = o?.description, !d.isEmpty {
            Text(verbatim: d).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
        }
    }

    // MARK: director and music director

    /// The director and the music director as names that open their pages on that role (the music director falls back to the composer when the film names no music director).
    private var credits: some View {
        let crew = model.crew.filter { $0.department == nil }
        let groups = [(Localized.string("Directed by"), crew.first { $0.role == .director }),
                      (Localized.string("Music by"), crew.first { $0.role == .musicDirector } ?? crew.first { $0.role == .composer })]
        return MusicChipFlow(spacing: MusicSpace.md) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                if let group = g.1 {
                    HStack(spacing: MusicSpace.xxs) {
                        Text(verbatim: g.0).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                        ForEach(Array(group.people.prefix(2)), id: \.person) { p in
                            MusicInlineLink(title: p.name, font: Typography.body, label: Localized.string("%1$@, %2$@", p.name, MusicFilmWording.roleTitle(group.role))) { hub.open(p.person, role: group.role) }
                        }
                    }
                }
            }
        }
    }

    // MARK: soundtrack summary

    /// "12 songs · 3 albums · 1 h 4 min" from the songs and albums the page has read; nothing while there are no songs.
    private var soundtrackLine: String? {
        guard let sum = MusicFilmSoundtrackSummary.make(songs: model.ownSongs, albums: model.albums.filter { !model.scoreAlbums.contains($0) }) else { return nil }
        var parts = [Localized.plural(sum.songs, one: "%@ song", other: "%@ songs")]
        if sum.albums > 0 { parts.append(Localized.plural(sum.albums, one: "%@ album", other: "%@ albums")) }
        if sum.minutes > 0 { parts.append(MusicFilmAboutSection.runtime(sum.minutes)) }
        return parts.joined(separator: " · ")
    }

    // MARK: actions

    private var allLiked: Bool {
        let tracks = model.playableOriginals
        return !tracks.isEmpty && tracks.allSatisfy { hub.library.isLiked($0) }
    }

    /// Likes every playable song of the film, or, when they are all liked already, removes those likes.
    private func toggleFavourite() {
        let tracks = model.playableOriginals
        let remove = allLiked
        for t in tracks where hub.library.isLiked(t) == remove { hub.library.toggleLike(t) }
    }

    private func iconButton(_ symbol: String, label: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(MusicTokens.iconLarge) }
            .musicButton(.glassIcon, size: .large).accessibilityLabel(label).musicTooltip(verbatim: label).atlas(id)
    }

    @ViewBuilder private var shareMenu: some View {
        if let id = model.entity?.id, let url = shareLink ?? MusicDeepLinks.link(entity: .entity(id, role: nil)) {
            Menu {
                Button(Localized.string("Copy link"), systemImage: "link") { MusicShare.copy(url) }.atlas("control.music.filmShareCopyLink")
                Button(Localized.string("Share…"), systemImage: "square.and.arrow.up") { MusicShare.showPicker(for: url) }.atlas("control.music.filmSharePicker")
            } label: {
                Image(systemName: "square.and.arrow.up").font(MusicTokens.iconLarge)
            }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel(Localized.string("Share")).musicTooltip(verbatim: Localized.string("Share")).atlas("control.music.filmShare")
            .task(id: id) {
                let ids = (try? await MusicEntityRuntime.shared.center.store.graph.externalIDs(of: id)) ?? []
                if !Task.isCancelled { shareLink = MusicFilmShare.url(entity: id, externalIDs: ids) }
            }
        }
    }

    private var actions: some View {
        let tracks = model.playableOriginals
        return HStack(spacing: MusicSpace.sm) {
            if !tracks.isEmpty { MusicPlayShuffleButtons(hub: hub, tracks: tracks, sourceName: model.overview?.title ?? model.entity?.snapshot?.name) }   // "Playing from" names the film
            if let seed = tracks.first {
                iconButton("dot.radiowaves.left.and.right", label: Localized.string("Film radio"), id: "control.music.filmRadio") { Task { await MusicQueueActions.startRadio(seed, hub: hub) } }
                iconButton(allLiked ? "heart.fill" : "heart", label: allLiked ? Localized.string("Remove the film's songs from your likes") : Localized.string("Like the film's songs"), id: "control.music.filmFavourite") { toggleFavourite() }
                iconButton("text.badge.plus", label: Localized.string("Add the film's songs to a playlist"), id: "control.music.filmAddToPlaylist") { MusicChromeState.shared.addToPlaylist = tracks }
            }
            shareMenu
            MusicOverflowMenu {
                Button { onViewInfo() } label: { Label(Localized.string("View film info"), systemImage: "info.circle") }.atlas("control.music.filmViewInfo")
                if !tracks.isEmpty {
                    Button { hub.player.playNext(tracks) } label: { Label(Localized.string("Play next"), systemImage: "text.insert") }.atlas("control.music.filmPlayNext")
                    Button { hub.player.enqueue(tracks) } label: { Label(Localized.string("Add to queue"), systemImage: "text.badge.plus") }.atlas("control.music.filmAddToQueue")
                }
            }
            MusicWatchMovieButton(state: model.watch, isSeries: model.isSeries) { model.pressWatch(gated: hub.gated) }
        }
    }
}
