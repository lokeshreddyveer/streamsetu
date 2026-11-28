import SwiftUI

// The Related tab of the context panel: everything real that is known around the playing song, one compact section at a time.
// Artist card(s), the album with its song list, more from the artist, similar artists and related songs. A section shows a small placeholder while it
// loads and disappears quietly when its source has nothing or fails. Resolution (own source first, then the names on the other sources) is in
// `MusicRelatedResolver`; this file only draws what the model holds.

// MARK: - live wiring

/// One resolver per hub for the whole session, so each song's answers are fetched once.
@MainActor
enum MusicRelatedShared {
    private struct Entry { weak var hub: MusicHub?; let resolver: MusicRelatedResolver }
    private static var entries: [Entry] = []
    private struct ModelEntry { weak var hub: MusicHub?; let model: MusicRelatedModel }
    private static var models: [ModelEntry] = []

    /// One Related model per hub, so leaving the tab and coming back shows the same answers at once instead of starting again from placeholders.
    static func model(for hub: MusicHub) -> MusicRelatedModel {
        models.removeAll { $0.hub == nil }
        if let e = models.first(where: { $0.hub === hub }) { return e.model }
        let m = MusicRelatedModel(resolver: resolver(for: hub), isBlocked: { [hub] in hub.library.isBlacklisted($0) || MusicHiddenRecommendations.shared.set.hides($0) })   // a hidden song or artist does not come back in Related
        models.append(ModelEntry(hub: hub, model: m))
        return m
    }

    static func resolver(for hub: MusicHub) -> MusicRelatedResolver {
        entries.removeAll { $0.hub == nil }
        if let e = entries.first(where: { $0.hub === hub }) { return e.resolver }
        let r = MusicRelatedResolver(environment: .live(hub: hub))
        entries.append(Entry(hub: hub, resolver: r))
        return r
    }
}

extension MusicRelatedResolver.Environment {
    /// The app's registry, catalogue switch, lock gate and blacklist behind the resolver's questions.
    @MainActor static func live(hub: MusicHub) -> Self {
        var e = Self()
        e.isGated = { await MainActor.run { hub.gated } }
        e.catalogueEnabled = { MusicCatalogRuntime.shared.isEnabled }
        e.provider = { id in await MainActor.run { hub.registry.isEnabled(id) ? hub.registry.metadataProvider(id: id) : nil } }
        e.searchSources = {
            await MainActor.run {
                let all = hub.registry.metadata.filter { !MusicSearchEnrichment.isCatalogueOnly($0.capabilities) }
                guard let active = hub.registry.activeMetadata?.id else { return all }
                return all.filter { $0.id == active } + all.filter { $0.id != active }
            }
        }
        e.isCatalogueOnly = { id in await MainActor.run { hub.registry.provider(id: id).map { MusicSearchEnrichment.isCatalogueOnly($0.capabilities) } ?? false } }
        e.playableTwins = { await MusicSearchEnrichment.playableOnly($0) }
        e.canonical = { t in
            let rt = MusicCatalogRuntime.shared
            guard rt.isEnabled, let c = rt.store.canonical(for: t) else { return nil }
            return MusicRelatedCanon(title: c.title, artists: c.artists, film: c.film, album: c.album)
        }
        e.isBlocked = { t in await MainActor.run { hub.library.isBlacklisted(t) || MusicHiddenRecommendations.shared.set.hides(t) } }
        let search = e.searchSources
        e.externalSimilar = { track in
            if await MainActor.run(body: { MusicPrivateListening.shared.isOn }) { return [] }
            let candidates = await MusicSimilarityService.shared.similar(to: track)
            guard !candidates.isEmpty else { return [] }
            return await MusicSimilarityService.shared.resolve(candidates, using: await search(), limit: 12)
        }
        e.isArtistBlocked = { a in await MainActor.run { hub.library.isBlacklisted(artist: a) } }
        return e
    }
}

// MARK: - the tab

struct MusicRelatedPanel: View {
    let hub: MusicHub
    @State private var model: MusicRelatedModel

    init(hub: MusicHub) {
        self.hub = hub
        _model = State(initialValue: MusicRelatedShared.model(for: hub))
    }

    private var current: MusicTrack? { hub.player.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                if let t = current {
                    artistsSection(t)
                    MusicRelatedMoreSection(track: t, hub: hub)
                    albumSection(t)
                    MusicFilmInfoView(album: nil, track: t, albumTracks: [], hub: hub)
                    topSongsSection(t)
                    albumsShelf
                    similarShelf
                    songsSection
                    if model.finishedEmpty || model.gated {
                        Text("No more information for this song").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task(id: hub.player.current?.uid) { await model.load(hub.player.current) }
    }

    // MARK: sections

    @ViewBuilder private func artistsSection(_ t: MusicTrack) -> some View {
        switch model.artists {
        case .loading: MusicRelatedArtistSkeleton()
        case .hidden: EmptyView()
        case .loaded(let list):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                MusicRelatedHeading(title: list.count > 1 ? Localized.string("Artists") : Localized.string("Artist"))
                ForEach(Array(list.enumerated()), id: \.element.id) { i, entry in
                    // A card with no resolved artist would start the same song radio that "Around this song" already offers.
                    MusicRelatedArtistCard(entry: entry, track: t, hub: hub, offersRadio: entry.artist != nil)
                }
            }
        }
    }

    @ViewBuilder private func albumSection(_ t: MusicTrack) -> some View {
        switch model.album {
        case .loading: MusicRelatedAlbumSkeleton()
        case .hidden: EmptyView()
        case .loaded(let a):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                MusicRelatedHeading(title: Localized.string("From this album"))
                MusicRelatedAlbumCard(info: a, playing: t, hub: hub)
            }
        }
    }

    @ViewBuilder private func topSongsSection(_ t: MusicTrack) -> some View {
        switch model.topSongs {
        case .loading: MusicRelatedRowsSkeleton(count: 3)
        case .hidden: EmptyView()
        case .loaded(let list):
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicRelatedHeading(title: Localized.string("More from %@", model.primary?.name ?? ""))
                MusicRelatedTrackList(tracks: list, hub: hub)
            }
        }
    }

    @ViewBuilder private var albumsShelf: some View {
        switch model.albums {
        case .loading: MusicShelfSkeleton(width: MusicCardSize.compact.width, count: 3)
        case .hidden: EmptyView()
        case .loaded(let list):
            MusicShelf(title: Localized.string("Albums and singles")) {
                ForEach(list) { a in MusicCard(album: a, hub: hub, width: MusicCardSize.compact.width, subtitle: MusicRelatedAlbumCard.releaseLine(a)) }
            }
            .cardWidth(MusicCardSize.compact.width)
        }
    }

    @ViewBuilder private var similarShelf: some View {
        switch model.similar {
        case .loading: MusicShelfSkeleton(width: MusicCardSize.compact.width, count: 3)
        case .hidden: EmptyView()
        case .loaded(let list):
            MusicShelf(title: Localized.string("Similar artists")) {
                ForEach(list) { a in MusicCard(artist: a, hub: hub, width: MusicCardSize.compact.width) }
            }
            .cardWidth(MusicCardSize.compact.width)
        }
    }

    @ViewBuilder private var songsSection: some View {
        switch model.songs {
        case .loading: MusicRelatedRowsSkeleton(count: 4)
        case .hidden: EmptyView()
        case .loaded(let list):
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicRelatedHeading(title: Localized.string("Related songs"))
                MusicRelatedTrackList(tracks: list, hub: hub)
            }
        }
    }
}

// MARK: - parts

struct MusicRelatedHeading: View {
    let title: String
    var body: some View {
        Text(verbatim: title).musicText(.section).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
}

/// Song rows in the shared row, without the extra columns so the title keeps the room at panel width.
struct MusicRelatedTrackList: View {
    let tracks: [MusicTrack]
    let hub: MusicHub
    private var options: MusicRowOptions {
        var o = MusicRowOptions()
        o.columns = MusicTrackColumns(shown: [])
        o.cellData = MusicTrackCells.data(for: tracks)
        return o
    }

    var body: some View {
        LazyVStack(spacing: MusicSpace.xxs) {
            ForEach(Array(tracks.enumerated()), id: \.element.uid) { i, t in
                MusicTrackRow(track: t, index: nil, queue: tracks, hub: hub, options: options)
            }
        }
    }
}

struct MusicRelatedArtistCard: View {
    let entry: MusicRelatedArtist
    let track: MusicTrack
    let hub: MusicHub
    var offersRadio = true
    @State private var wiki: MusicPersonWikiInfo?

    static let portrait: CGFloat = MusicSpace.giant + MusicSpace.md

    private var name: String { entry.artist?.name ?? entry.credited.name }
    private var thumbs: [MusicThumbnail] {
        let own = MusicArtistPortrait.portraits((entry.artist?.thumbnails ?? []) + entry.credited.thumbnails)
        guard own.isEmpty, let file = wiki?.portraitFile, let u = MusicPortraitRef.commonsThumbnailURL(file: file, width: 300) else { return own }
        return [MusicThumbnail(url: u.absoluteString, width: 300, height: 300)]
    }
    /// One line about the artist: Wikipedia's short description when there is one, else the source's own biography cut to a short sentence.
    private var about: String? {
        if let d = wiki?.description, !d.isEmpty { return d }
        return entry.artist?.bio.flatMap { MusicBioText.shortLine($0) }
    }
    /// The page to open: the resolved artist, or the credit itself when the song's source gave it a real id.
    private var target: MusicArtist? {
        if let a = entry.artist { return a }
        return entry.credited.id.isEmpty ? nil : MusicLinks.artist(entry.credited, providerID: track.providerID)
    }
    private var statLine: String {
        var parts: [String] = []
        if let f = entry.artist?.followers, f > 0 { parts.append(Localized.string("%@ followers", f.formatted(.number.notation(.compactName)))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .top, spacing: MusicSpace.sm) {
                MusicCoverImage(thumbs: thumbs, artworkClass: .artistPortrait, size: Self.portrait, corner: MusicCardGeometry.roundCorner,
                                seed: name, initials: MusicArtistPortrait.initials(name), subject: .personNamed(name))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    nameView
                    if !statLine.isEmpty { Text(verbatim: statLine).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    if let about { Text(verbatim: about).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            actions
        }
        .accessibilityElement(children: .contain)
        .task(id: name) {
            wiki = nil   // the last artist's line must not show under the next one while this lookup runs
            // The same Wikipedia and Wikidata lookup the artist page uses, strict about who the person is; nothing is shown that is not matched.
            guard let transport = MusicEntityArtwork.shared.transportIfAllowed() else { return }
            let lookup = MusicPersonWikiInfoLoader.Lookup(name: name, isGroup: false, roleWords: MusicPersonWikiRules.roleWords(forView: "singer"))
            wiki = await MusicPersonWikiInfoLoader.shared.info(qid: nil, tmdbID: nil, sitelinks: nil, readingLanguages: MusicPersonNames.readerLanguages, transport: transport,
                                                              tmdb: MusicEntityArtwork.shared.tmdbFetch, lookup: lookup)
        }
    }

    @ViewBuilder private var nameView: some View {
        if let target {
            Button { hub.open(.artist(target)) } label: {
                Text(verbatim: name).musicText(.card).foregroundStyle(ColorTokens.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).accessibilityLabel(Localized.string("Open artist %@", name)).atlas("control.music.relatedArtistName")
        } else {
            Text(verbatim: name).musicText(.card).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
        }
    }

    @ViewBuilder private var actions: some View {
        let following = (entry.artist ?? target).map { hub.library.isFollowing($0) } ?? false
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MusicSpace.xs) { open; radio; follow(following) }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                HStack(spacing: MusicSpace.xs) { open; radio }
                follow(following)
            }
        }
    }

    @ViewBuilder private var open: some View {
        if let target {
            Button { hub.open(.artist(target)) } label: { Text("Open artist") }
                .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Open artist %@", name)).atlas("control.music.relatedOpenArtist")
        }
    }

    @ViewBuilder private var radio: some View {
        if offersRadio {
            Button {
                if let a = entry.artist { Task { await MusicEntityActions.startRadio(.artist(a), hub: hub) } }
            } label: { Text("Start radio") }
                .musicButton(.secondary, size: .compact)
                .accessibilityLabel(Localized.string("Start radio from %@", name))
                .atlas("control.music.relatedArtistRadio")
        }
    }

    @ViewBuilder private func follow(_ following: Bool) -> some View {
        if let a = entry.artist ?? target {
            Button { MusicEntityActions.toggleFollow(a, hub: hub) } label: { Text(following ? "Following" : "Follow") }
                .musicButton(.secondary, size: .compact).accessibilityLabel(following ? Localized.string("Unfollow %@", a.name) : Localized.string("Follow %@", a.name))
                .atlas("control.music.relatedArtistFollow")
        }
    }
}

struct MusicRelatedAlbumCard: View {
    let info: MusicRelatedAlbum
    let playing: MusicTrack
    let hub: MusicHub

    static let cover: CGFloat = MusicSpace.giant + MusicSpace.md
    /// How many album songs are listed before the rest is left to the album page.
    static let listLimit = 10

    static func releaseLine(_ a: MusicAlbum) -> String { MusicRelatedResolver.year(a.releaseDate) ?? "" }

    private var line: String {
        var parts: [String] = []
        if let y = info.year { parts.append(y) }
        let n = info.tracks.isEmpty ? (info.trackCount ?? 0) : info.tracks.count
        if n > 0 { parts.append(Localized.plural(n, one: "%@ song", other: "%@ songs")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .top, spacing: MusicSpace.sm) {
                MusicCoverImage(thumbs: info.thumbnails, artworkClass: .tile, size: Self.cover, corner: MusicCorner.card, seed: info.knownTitle, subject: .album(info.knownTitle, creator: playing.artistLine))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: info.knownTitle).musicText(.card).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                    if !line.isEmpty { Text(verbatim: line).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    if let album = info.album, !album.id.isEmpty {
                        Button { hub.open(.album(album)) } label: { Text("Open album") }
                            .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Open album %@", info.knownTitle)).atlas("control.music.relatedOpenAlbum")
                            .padding(.top, MusicSpace.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            if !info.tracks.isEmpty { list }
        }
        .accessibilityElement(children: .contain)
    }

    private var list: some View {
        let playingIndex = info.tracks.firstIndex { MusicRelatedMatch.sameSong($0, playing) }
        let range = MusicRelatedMatch.window(count: info.tracks.count, playing: playingIndex, limit: Self.listLimit)
        return VStack(spacing: 0) {
            ForEach(Array(range), id: \.self) { i in
                let t = info.tracks[i]
                MusicRelatedAlbumRow(number: t.trackNumber ?? i + 1, track: t, isCurrent: i == playingIndex, isPlaying: hub.player.isPlaying) {
                    hub.play(info.tracks, at: i, sourceName: info.knownTitle)
                }
            }
        }
    }
}

struct MusicRelatedAlbumRow: View {
    let number: Int
    let track: MusicTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.sm) {
                ZStack {
                    if isCurrent { MusicCurrentRowGlyph(isPlaying: isPlaying) }
                    else { Text(verbatim: "\(number)").musicText(.caption).foregroundStyle(ColorTokens.textTertiary).monospacedDigit() }
                }
                .frame(width: MusicSpace.lg)
                Text(verbatim: track.title).musicText(isCurrent ? .card : .secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isCurrent ? ColorTokens.accent : ColorTokens.textPrimary)
                Spacer(minLength: 0)
                let d = MusicInfoRows.duration(ms: track.durationMs)
                if !d.isEmpty { Text(verbatim: d).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).monospacedDigit() }
            }
            .padding(.horizontal, MusicSpace.xs).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(Localized.string("Play %@", track.title)).accessibilityAddTraits(isCurrent ? .isSelected : [])
        .atlas("control.music.relatedAlbumTrack")
    }
}

// MARK: - placeholders

struct MusicRelatedArtistSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSkeletonBlock(width: MusicSpace.giant * 2, height: MusicSpace.md, corner: MusicSpace.xxs / 2)
            HStack(spacing: MusicSpace.sm) {
                MusicSkeletonBlock(width: MusicRelatedArtistCard.portrait, height: MusicRelatedArtistCard.portrait, corner: MusicCardGeometry.roundCorner)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    MusicSkeletonBlock(width: MusicSpace.giant * 2, height: MusicSpace.sm, corner: MusicSpace.xxs / 2)
                    MusicSkeletonBlock(width: MusicSpace.giant + MusicSpace.xl, height: MusicSpace.xs, corner: MusicSpace.xxs / 2, emphasis: false)
                }
                Spacer(minLength: 0)
            }
        }
        .musicSkeletonPulse().accessibilityHidden(true)
    }
}

struct MusicRelatedAlbumSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSkeletonBlock(width: MusicSpace.giant * 2, height: MusicSpace.md, corner: MusicSpace.xxs / 2)
            HStack(spacing: MusicSpace.sm) {
                MusicSkeletonBlock(width: MusicRelatedAlbumCard.cover, height: MusicRelatedAlbumCard.cover, corner: MusicCorner.card)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    MusicSkeletonBlock(width: MusicSpace.giant * 2, height: MusicSpace.sm, corner: MusicSpace.xxs / 2)
                    MusicSkeletonBlock(width: MusicSpace.giant + MusicSpace.xl, height: MusicSpace.xs, corner: MusicSpace.xxs / 2, emphasis: false)
                }
                Spacer(minLength: 0)
            }
        }
        .musicSkeletonPulse().accessibilityHidden(true)
    }
}

struct MusicRelatedRowsSkeleton: View {
    var count = 3
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSkeletonBlock(width: MusicSpace.giant * 2, height: MusicSpace.md, corner: MusicSpace.xxs / 2)
            ForEach(0..<max(1, count), id: \.self) { _ in MusicSkeletonRow() }
        }
        .musicSkeletonPulse().accessibilityHidden(true)
    }
}
