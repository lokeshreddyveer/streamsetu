import SwiftUI

// Section A: the header. Original artwork, the film it is the soundtrack of, year, language, type, the music directors and composers, and the actions
// (Play, Shuffle, Favourite, Add to playlist, Share, View film). Play and Shuffle work from the provider's tracklist the moment it is in; nothing here
// waits for metadata. On a narrow window the cover sits above the text and the actions wrap.

/// The words of a reason, from the app's own tables.
extension MusicSoundtrackReason {
    var words: String { text { Localized.string($0) } }
}

extension MusicSoundtrackHeaderFacts {
    /// "Soundtrack", "Score", "EP"... the eyebrow over the title. What the record IS (a soundtrack of a film) and how it was released (an EP, a single) are two
    /// facts: a five-song record that belongs to a film reads "Soundtrack · EP", never just "EP".
    var kindLabel: String {
        let format: String? = switch subkind {
        case MusicAlbumSubkind.ep.rawValue: Localized.string("EP")
        case MusicAlbumSubkind.single.rawValue: Localized.string("Single")
        default: nil
        }
        switch subkind {
        case MusicAlbumSubkind.soundtrack.rawValue: return Localized.string("Soundtrack")
        case MusicAlbumSubkind.score.rawValue: return Localized.string("Score")
        case MusicAlbumSubkind.compilation.rawValue: return Localized.string("Compilation")
        default:
            if isFilm { return [Localized.string("Soundtrack"), format].compactMap { $0 }.joined(separator: " · ") }
            return format ?? Localized.string("Album")
        }
    }
}

struct MusicSoundtrackHeaderSection: View {
    let page: MusicSoundtrackPageModel
    /// The album page's extras (editions, release facts) and how the page's pills are switched; both optional so the header also stands alone.
    var extras: MusicAlbumExtrasModel? = nil
    var onSelect: (MusicAlbumPill) -> Void = { _ in }
    /// The pills the page offers; an overflow item that would open a pill that is not there (a single with one song has none) is disabled.
    var pills: [MusicAlbumPill] = MusicAlbumPill.allCases
    @State private var showCover = false
    @State private var showPersonal = false
    @State private var gallery = MusicAlbumArtworkModel()
    @Environment(\.musicLayoutClass) private var layoutClass

    private var hub: MusicHub { page.hub }
    private var compact: Bool { layoutClass == .compact }
    /// 220 to 300 pt on larger windows, smaller on a narrow one.
    private var coverSize: CGFloat { compact ? MusicCardSize.large.width : MusicCardSize.large.width + MusicSpace.xxl + MusicSpace.xs }

    var body: some View {
        let h = page.displayHeader
        Group {
            if compact {
                VStack(alignment: .leading, spacing: MusicSpace.md) { cover; text(h) }
            } else {
                HStack(alignment: .bottom, spacing: MusicSpace.lg) { cover; text(h) }
            }
        }
        .background(alignment: .top) { wash }
        .accessibilityElement(children: .contain)
        // The sheets hang off the whole header, not the cover button: a sheet inherits `.disabled`, and the cover button is disabled when the album has no artwork,
        // which would otherwise open "Your rating and notes" with every control dead.
        .sheet(isPresented: $showCover) { MusicAlbumCoverViewer(thumbs: page.coverThumbs, title: page.displayHeader?.title ?? "", entity: page.entity, gallery: gallery) { showCover = false } }
        .sheet(isPresented: $showPersonal) {
            if let e = extras { MusicAlbumPersonalSheet(extras: e, title: page.displayHeader?.title ?? "") { showPersonal = false } }
        }
    }

    /// The cover's own colours, blurred and faded into the page behind the header: every album gets its own mood without a second picture being fetched.
    @ViewBuilder private var wash: some View {
        if !page.coverThumbs.isEmpty {
            MusicCoverImage(thumbs: page.coverThumbs, size: nil, corner: 0).artwork(of: nil, slot: .backdrop)
                .frame(maxWidth: .infinity).frame(height: 360).clipped()
                .blur(radius: 60).opacity(0.38)
                .overlay(LinearGradient(colors: [.clear, ColorTokens.background], startPoint: .center, endPoint: .bottom))
                .padding(.horizontal, -MusicSpace.xl).padding(.top, -MusicSpace.xl)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    private var cover: some View {
        Button { showCover = true } label: {
            MusicArtwork(page.coverThumbs, size: coverSize, corner: MusicCorner.cardLarge, subject: page.model?.snapshot.map { MusicArtworkSubject.derive($0) }, slot: .poster)
                .shadow(color: MusicInk.scrim(.strong), radius: MusicElevation.floating.shadowRadius, y: MusicElevation.floating.shadowOffsetY)
        }
        .buttonStyle(.plain).disabled(page.coverThumbs.isEmpty)
        .accessibilityLabel(Localized.string("View cover")).atlas("control.music.albumCoverOpen")
    }

    /// Original / Standard / Deluxe... only when it says something (a lone release is not labelled).
    private var editionLabel: String? {
        guard let e = extras, let own = e.own else { return nil }
        let b = MusicAlbumEditionRules.badge(own, siblings: e.versions.filter { $0.category == .edition || $0.category == .language }.map(\.facts) + [own])
        return b == .standard ? nil : b.label
    }

    @ViewBuilder private func text(_ h: MusicSoundtrackHeaderFacts?) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if let h {
                Text(verbatim: [h.kindLabel, editionLabel].compactMap { $0 }.joined(separator: " · ")).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
                Text(verbatim: h.title).font(Typography.pageTitle).lineLimit(3).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                filmLine(h)
                artistsLine(h)
                makersLine(h)
                factsLine(h)
                detailLine
            } else {
                MusicSkeletonBlock(width: coverSize, height: MusicSpace.xl, corner: MusicCorner.control)
                MusicSkeletonBlock(width: coverSize * 1.5, height: MusicSpace.xxl, corner: MusicCorner.control)
            }
            actions(h).padding(.top, MusicSpace.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: lines

    @ViewBuilder private func filmLine(_ h: MusicSoundtrackHeaderFacts) -> some View {
        if let film = h.film {
            HStack(spacing: MusicSpace.xs) {
                Button { hub.open(film.id) } label: {
                    Label { Text(verbatim: Localized.string("Soundtrack of %@", filmTitle(film))) } icon: { Image(systemName: "film") }
                        .labelStyle(.titleAndIcon)
                }
                .musicButton(.chip, size: .compact)
                .accessibilityLabel(Localized.string("Soundtrack of %@", filmTitle(film)))
                .accessibilityHint(Localized.string("Opens the film page"))
                .atlas("control.music.soundtrackFilmChip")
            }
        } else if let hint = h.filmHint {
            // A provider's "(From "Film")" wording: plain text, no link, no cast.
            Text(verbatim: Localized.string("From \"%@\"", hint)).musicText(.body).foregroundStyle(ColorTokens.textSecondary)
        }
    }

    /// The album's own artists, each a link to the artist's page, for an album with no listed music directors or composers (an album of songs by an artist). A soundtrack
    /// shows its makers instead, so the same names are not said twice.
    @ViewBuilder private func artistsLine(_ h: MusicSoundtrackHeaderFacts) -> some View {
        // A film soundtrack shows its makers instead (the same names would be said twice); any other album keeps its artists linked even when it has a composer credit.
        if h.makers.isEmpty || h.film == nil, let album = page.providerAlbum {
            let artists = album.artists.filter { MusicCompilationArtist.isUsableArtist($0) }
            if !artists.isEmpty {
                MusicGraphFlowLayout(spacing: MusicSpace.xs) {
                    ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                        HStack(spacing: 0) {
                            if a.id.isEmpty {
                                Text(verbatim: a.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                            } else {
                                MusicInlineLink(title: a.name, font: Typography.bodyMedium, label: Localized.string("Open %@", a.name), rest: ColorTokens.textPrimary) {
                                    hub.open(.artist(hub.artist(from: a, providerID: album.providerID)))
                                }
                            }
                            if i < artists.count - 1 { Text(verbatim: ",").musicText(.body).foregroundStyle(ColorTokens.textSecondary) }
                        }
                    }
                }
            }
        } else if h.makers.isEmpty || h.film == nil {
            // No source holds this album (or its songs are still paging): the artists the graph credits on the album itself, each linked by id, so the header is not left without one.
            var seen = Set<MusicEntityID>()
            let people = page.rawCredits.filter { !$0.isFilmCredit && $0.level == .album && MusicSoundtrackSinging.roles.contains($0.role) && seen.insert($0.person.id).inserted }.prefix(4).map { $0 }
            if !people.isEmpty {
                MusicGraphFlowLayout(spacing: MusicSpace.xs) {
                    ForEach(Array(people.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 0) {
                            MusicInlineLink(title: c.person.name, font: Typography.bodyMedium, label: Localized.string("Open %@", c.person.name), rest: ColorTokens.textPrimary) { hub.open(c.person.id, role: c.role) }
                            if i < people.count - 1 { Text(verbatim: ",").musicText(.body).foregroundStyle(ColorTokens.textSecondary) }
                        }
                    }
                }
            }
        }
    }

    private func filmTitle(_ f: MusicSoundtrackFilm) -> String { f.year.map { "\(f.title), \($0)" } ?? f.title }

    @ViewBuilder private func makersLine(_ h: MusicSoundtrackHeaderFacts) -> some View {
        if !h.makers.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
                Text(verbatim: h.makers.contains { $0.role == .musicDirector } ? Localized.string("Music by") : Localized.string("Composed by"))
                    .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                ForEach(Array(h.makers.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 0) {
                        MusicInlineLink(title: c.person.name, font: Typography.bodyMedium, label: Localized.string("Open %@", c.person.name)) { hub.open(c.person.id, role: c.role) }
                        if let d = c.person.detail { Text(verbatim: " (\(d))").musicText(.caption).foregroundStyle(ColorTokens.textTertiary) }
                        if i < h.makers.count - 1 { Text(verbatim: ",").musicText(.body).foregroundStyle(ColorTokens.textSecondary) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func factsLine(_ h: MusicSoundtrackHeaderFacts) -> some View {
        var parts: [String] = []
        if let y = h.year { parts.append(String(y)) }
        if let l = h.languageName, !l.isEmpty { parts.append(l) }
        let n = page.tracks.count > 0 ? page.tracks.count : page.rows.count
        if n > 0 { parts.append(Localized.plural(n, one: "%@ song", other: "%@ songs")) }
        let discs = Set(page.rows.compactMap(\.disc)).count
        if discs > 1 { parts.append(Localized.plural(discs, one: "%@ disc", other: "%@ discs")) }
        if page.totalDurationMs > 0 { parts.append(MusicDurationText.total(ms: page.totalDurationMs)) }
        return Text(verbatim: parts.joined(separator: " · ")).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
    }

    /// The second quiet line: label, genres, explicit, partial availability, library status, an edition's own release date. Each part only when known.
    @ViewBuilder private var detailLine: some View {
        let line = detailParts.joined(separator: " · ")
        if !line.isEmpty { Text(verbatim: line).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(2) }
    }

    private var detailParts: [String] {
        let info = extras?.info ?? MusicAlbumInfo()
        var parts: [String] = []
        if let d = info.releaseDate, let date = MusicAlbumPageLogic.fullDate(d) { parts.append(date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current))) }
        if let l = info.label { parts.append(l) }
        if !info.genres.isEmpty { parts.append(info.genres.prefix(2).joined(separator: ", ")) }
        if let d = info.releaseDate, let ry = Int(d.prefix(4)), let oy = info.originalYear, ry != oy { parts.append(Localized.string("Original release %@", String(oy))) }
        if page.rows.contains(where: \.explicit) { parts.append(Localized.string("Explicit")) }
        if let p = MusicAlbumAvailability.partial(playable: page.rows.filter(\.isPlayable).count, total: page.rows.count) {
            parts.append(Localized.string("%1$@ of %2$@ playable", String(p.playable), String(p.total)))
        }
        if let a = page.providerAlbum, hub.library.isSaved(a) { parts.append(Localized.string("In your library")) }
        if let r = extras?.rating { parts.append(Localized.string("Your rating: %@ of 5", String(r))) }
        if let t = extras?.tags, !t.isEmpty { parts.append(t.prefix(4).joined(separator: ", ")) }
        return parts
    }

    // MARK: actions

    private func actions(_ h: MusicSoundtrackHeaderFacts?) -> some View {
        MusicGraphFlowLayout(spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.xs) { MusicPlayShuffleButtons(hub: hub, tracks: page.tracks, sourceName: page.displayHeader?.title) }
            if let album = page.providerAlbum { favourite(album) }
            iconButton("dot.radiowaves.left.and.right", label: Localized.string("Start Radio"), disabled: page.tracks.isEmpty, id: "control.music.albumRadioButton") { startAlbumRadio() }
            iconButton("music.note.list", label: Localized.string("Add to playlist"), disabled: page.tracks.isEmpty, id: "control.music.soundtrackAddToPlaylist") {
                MusicChromeState.shared.addToPlaylist = page.tracks
            }
            share
            if let film = h?.film {
                Button { hub.open(film.id) } label: { Label(Localized.string("View film"), systemImage: "film") }
                    .musicButton(.secondary, size: .large).accessibilityLabel(Localized.string("View film %@", film.title)).atlas("control.music.soundtrackViewFilm")
            }
            MusicOverflowMenu { overflow }
        }
    }

    private func favourite(_ album: MusicAlbum) -> some View {
        let saved = hub.library.isSaved(album)
        return iconButton(saved ? "heart.fill" : "heart", label: saved ? Localized.string("Remove album from Your library") : Localized.string("Save album to Your library"), id: "control.music.soundtrackFavourite") {
            MusicEntityActions.toggleSave(album, hub: hub)
        }
    }

    private func iconButton(_ symbol: String, label: String, disabled: Bool = false, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(MusicTokens.iconLarge) }
            .musicButton(.glassIcon, size: .large).disabled(disabled)
            .accessibilityLabel(label).musicTooltip(verbatim: label).atlas(id)
            .atlasCovers("control.music.soundtrackFavourite")
    }

    @ViewBuilder private var share: some View {
        if let url = page.shareURL {
            Menu {
                Button(Localized.string("Copy link"), systemImage: "link") { MusicShare.copy(url) }.atlas("control.music.shareCopyLink")
                #if os(macOS)
                Button(Localized.string("Share…"), systemImage: "square.and.arrow.up") { MusicShare.showPicker(for: url) }.atlas("control.music.shareShare")
                #else
                ShareLink(item: url) { Label(Localized.string("Share…"), systemImage: "square.and.arrow.up") }
                #endif
            } label: {
                Image(systemName: "square.and.arrow.up").font(MusicTokens.iconLarge)
            }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel(Localized.string("Share")).musicTooltip(verbatim: Localized.string("Share")).atlas("control.music.soundtrackShare")
        }
    }

    /// Credits exist when the page would draw the Credits pill (the same test the page uses).
    private var hasCredits: Bool { page.rawCredits.contains { !$0.isFilmCredit && MusicAlbumCreditGroup.of($0.role) != nil } }

    @ViewBuilder private var overflow: some View {
        Button(Localized.string("Play Next"), systemImage: "text.insert") { if !page.tracks.isEmpty, hub.player.playNext(page.tracks, from: page.displayHeader?.title) { MusicToasts.shared.success(Localized.string("Playing next.")) } }
            .disabled(page.tracks.isEmpty).atlas("control.music.albumArtistAndPlaylistPagesPlayNext")
        Button(Localized.string("Add to Queue"), systemImage: "text.append") { if !page.tracks.isEmpty, hub.player.enqueue(page.tracks, from: page.displayHeader?.title) { MusicToasts.shared.success(Localized.string("Added to the queue.")) } }
            .disabled(page.tracks.isEmpty).atlas("control.music.albumArtistAndPlaylistPagesAddToQueue")
        Button(Localized.string("Start Radio"), systemImage: "dot.radiowaves.left.and.right") { startAlbumRadio() }
        .disabled(page.tracks.isEmpty).atlas("control.music.albumArtistAndPlaylistPagesStartRadio")
        Button(Localized.string("Add to playlist"), systemImage: "music.note.list") { MusicChromeState.shared.addToPlaylist = page.tracks }
            .disabled(page.tracks.isEmpty).atlas("control.music.albumAddToPlaylist")
        Button(Localized.string("Download album"), systemImage: "arrow.down.circle") { downloadAlbum() }
            .disabled(!MusicPlaylistActionRules.canDownloadAll(count: page.tracks.count)).atlas("control.music.albumDownload")
        Divider()
        Button(Localized.string("View artwork"), systemImage: "photo") { showCover = true }
            .disabled(page.coverThumbs.isEmpty).atlas("control.music.albumViewArtwork")
        Button(Localized.string("Album information"), systemImage: "info.circle") { onSelect(.about) }
            .disabled((extras?.info.isEmpty ?? true) || !pills.contains(.about)).atlas("control.music.albumInformation")
        if let e = extras {
            Button(Localized.string("Your rating and notes"), systemImage: "star.bubble") { showPersonal = true }
                .disabled(!e.canChoose).atlas("control.music.albumPersonal")
        }
        Divider()
        if let album = page.providerAlbum, let a = album.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) && !$0.id.isEmpty }) {
            Button(Localized.string("Go to artist"), systemImage: "person.crop.circle") { hub.open(.artist(hub.artist(from: a, providerID: album.providerID))) }.atlas("control.music.albumGoToArtist")
        }
        if let film = page.displayHeader?.film {
            Button(Localized.string("Go to film"), systemImage: "film") { hub.open(film.id) }.atlas("control.music.albumGoToFilm")
        }
        Button(Localized.string("View credits"), systemImage: "person.2") { onSelect(.credits) }.disabled(!hasCredits || !pills.contains(.credits)).atlas("control.music.albumViewCredits")
        if let e = extras {
            if !e.versions.isEmpty {
                Button(Localized.string("Show other editions"), systemImage: "rectangle.split.2x1") { onSelect(.versions) }.disabled(!pills.contains(.versions)).atlas("control.music.albumShowEditions")
            }
            // Until the versions have loaded the album's concept is unknown, and a choice would be saved under the wrong key.
            if e.preferredEdition == page.entity {
                Button(Localized.string("Clear preferred edition"), systemImage: "star.slash") { e.setPreferred(nil) }.disabled(!e.canChoose).atlas("control.music.albumSetPreferred")
            } else {
                Button(Localized.string("Set as preferred edition"), systemImage: "star") { e.setPreferred(page.entity) }.disabled(!e.canChoose).atlas("control.music.albumSetPreferred")
            }
        }
        Button(Localized.string("Export tracklist as text"), systemImage: "doc.plaintext") { export(csv: false) }.disabled(page.rows.isEmpty).atlas("control.music.albumExport")
        Button(Localized.string("Export tracklist as CSV"), systemImage: "tablecells") { export(csv: true) }.disabled(page.rows.isEmpty).atlas("control.music.albumExport")
        Button(Localized.string("Refresh metadata"), systemImage: "arrow.clockwise") {
            page.refreshMetadata(); extras?.loadVersions(force: true); extras?.loadInfo(provider: page.providerAlbum, force: true)
        }.atlas("control.music.albumRefresh")
    }

    /// A station seeded from the whole album, not from its first song.
    private func startAlbumRadio() {
        let list = page.tracks, title = page.displayHeader?.title
        Task { await MusicQueueActions.startAlbumRadio(list, title: title, hub: hub) }
    }

    private func downloadAlbum() {
        let list = page.tracks
        guard MusicPlaylistActionRules.canDownloadAll(count: list.count) else { MusicToasts.shared.show(Localized.string("Nothing to download here yet.")); return }
        for t in list { hub.downloads.enqueue(t) }
        MusicToasts.shared.success(Localized.plural(list.count, one: "Downloading %@ song.", other: "Downloading %@ songs."))
    }

    private func export(csv: Bool) {
        let items = page.rows.map { MusicAlbumTrackItem(id: $0.trackUID ?? $0.id.rawValue, title: $0.title, artistLine: $0.singerLine, disc: $0.disc, number: $0.number, durationMs: $0.durationMs, isPlayable: $0.isPlayable) }
        MusicAlbumExporter.save(title: page.displayHeader?.title ?? "", items: items, csv: csv)
    }
}
