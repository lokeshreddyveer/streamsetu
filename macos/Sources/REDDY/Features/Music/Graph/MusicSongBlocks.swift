import SwiftUI

// The blocks of the song page under its header. Each block loads when it first appears (one graph section at a time, under the page's gate), shows a
// placeholder of its final shape while it waits, shows what it has as it arrives, and takes no room at all when the graph has nothing for it.

struct MusicSongBlockView: View {
    let page: MusicSongPageModel
    let data: MusicSongPageData
    let block: MusicSongBlock

    var body: some View {
        let state = data.state(block)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            switch block {
            case .header: EmptyView()
            case .credits: MusicSongCreditsBlock(page: page, groups: data.creditGroups, state: state, film: data.context?.film, title: data.selfName)
            case .lyrics: MusicSongLyricsBlock(page: page)
            case .versions: MusicSongVersionsBlock(page: page, groups: data.versionGroups, state: state)
            case .live: MusicSongLiveBlock(page: page, items: data.liveItems)
            case .samples: MusicSongSamplesBlock(page: page, from: data.samplesFrom, by: data.sampledBy, state: state)
            case .related: shelf("Related songs", data.related, state)
            case .moreBySinger: shelf("More by the singer", data.moreBySinger, state)
            case .moreByComposer: shelf("More by the composer", data.moreByComposer, state)
            case .films: shelf("More films with these artists", data.films, state, film: true)
            case .playlists: MusicSongPlaylistsBlock(page: page, items: data.playlists, state: state)
            case .similar: shelf("Similar recordings", data.similar, state)
            case .sources: EmptyView()      // no list of where a song comes from: names of services, badges and "Unverified" are not shown
            }
        }
        .onAppear { load() }
    }

    private func shelf(_ title: String, _ items: [MusicSongRelatedItem], _ state: MusicSongBlockState, film: Bool = false) -> some View {
        MusicSongShelf(page: page, title: Localized.string(title), items: items, loading: state == .skeleton, film: film)
    }

    private func load() {
        switch block {
        case .credits: page.ensure(.credits)
        case .versions, .live: page.ensure(.versions)
        case .samples: page.ensure(.samples)
        case .related: page.ensure(.related); page.loadProviderRelated()
        case .moreBySinger: page.ensure(.moreBySinger)
        case .moreByComposer: page.ensure(.moreByComposer)
        case .films: page.ensure(.films)
        case .playlists: page.ensure(.playlists); page.refreshLocalPlaylists()
        case .similar: page.ensure(.similar); page.ensure(.related)
        case .header, .lyrics, .sources: break
        }
    }
}

struct MusicSongHeading: View {
    let key: String
    var body: some View {
        Text(verbatim: Localized.string(key)).musicText(.section).foregroundStyle(ColorTokens.textPrimary).accessibilityAddTraits(.isHeader)
    }
}

/// The quiet line for "nothing here" (never an error, never a button).
struct MusicSongQuietLine: View {
    let key: String
    var body: some View { Text(verbatim: Localized.string(key)).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary) }
}

// MARK: credits (items 5 to 8)

struct MusicSongCreditsBlock: View {
    let page: MusicSongPageModel
    let groups: [MusicSongCreditGroup]
    let state: MusicSongBlockState
    var film: MusicSongFilmLink?
    var title = ""

    var body: some View {
        switch state {
        case .skeleton:
            MusicSongHeading(key: "Credits")
            VStack(alignment: .leading, spacing: MusicSpace.sm) { MusicSkeletonRow(cover: MusicSpace.xl); MusicSkeletonRow(cover: MusicSpace.xl) }.musicSkeletonPulse(false)
        case .quietEmpty:
            MusicSongQuietLine(key: "Not credited in the sources we checked")
        case .content:
            MusicSongHeading(key: "Credits")
            let wheel = MusicRelationshipWheel.nodes(groups: groups, film: film)
            if MusicRelationshipWheel.isWorthShowing(wheel) { MusicRelationshipWheelView(page: page, title: title, nodes: wheel) }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: Localized.string(g.kind.titleKey)).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                    MusicSongFlow {
                        ForEach(g.people) { p in
                            MusicSongPersonButton(page: page, person: p)
                            if let i = p.instrument, !i.isEmpty { Text(verbatim: i).musicText(.caption).foregroundStyle(ColorTokens.textTertiary) }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: versions and live recordings (items 10 and 11)

struct MusicSongVersionRow: View {
    let page: MusicSongPageModel
    let item: MusicSongVersionItem

    private var sub: String { [item.year.map(String.init), item.artistLine].compactMap { $0 }.joined(separator: " · ") }

    var body: some View {
        Button { page.open(item.id) } label: {
            HStack(spacing: MusicSpace.sm) {
                MusicArtwork(MusicSongText.thumbs(item.imageRef), size: MusicSpace.huge, corner: MusicCorner.control,
                             subject: .card(.recording, name: item.name, entity: item.id, year: item.year, creator: item.artistLine))
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: item.name).musicText(.card).lineLimit(2)
                    if !sub.isEmpty { Text(verbatim: sub).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: MusicSpace.xs)
                if let key = MusicSongVersioning.badgeKey(item.kind, inferred: item.status != .verified), item.relation != .original {
                    MusicStatusChip(title: Localized.string(key), symbol: item.status == .verified ? "arrow.triangle.2.circlepath" : "questionmark.circle")
                }
            }
            .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xxs).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(sub.isEmpty ? item.name : item.name + ", " + sub)
        .atlas("control.music.songPageVersion")
    }
}

struct MusicSongVersionsBlock: View {
    let page: MusicSongPageModel
    let groups: [MusicSongVersionGroup]
    let state: MusicSongBlockState

    var body: some View {
        switch state {
        case .skeleton:
            MusicSongHeading(key: "Other versions")
            VStack(alignment: .leading, spacing: MusicSpace.xs) { MusicSkeletonRow(); MusicSkeletonRow() }
        case .content:
            MusicSongHeading(key: "Other versions")
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: Localized.string(MusicSongVersioning.groupTitleKey(g.kind))).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                    ForEach(g.items) { MusicSongVersionRow(page: page, item: $0) }
                }
            }
        case .quietEmpty, .hidden:
            EmptyView()
        }
    }
}

struct MusicSongSamplesBlock: View {
    let page: MusicSongPageModel
    let from: [MusicSongSampleItem]
    let by: [MusicSongSampleItem]
    let state: MusicSongBlockState

    var body: some View {
        if state == .content {
            if !from.isEmpty { group("Samples from", from) }
            if !by.isEmpty { group("Sampled by", by) }
        }
    }

    @ViewBuilder private func group(_ key: String, _ items: [MusicSongSampleItem]) -> some View {
        MusicSongHeading(key: key)
        ForEach(items) { item in
            Button { page.open(item.id) } label: {
                HStack(spacing: MusicSpace.sm) {
                    MusicArtwork(MusicSongText.thumbs(item.imageRef), size: MusicSpace.huge, corner: MusicCorner.control,
                                 subject: .card(.recording, name: item.name, entity: item.id, year: item.year, creator: item.artistLine))
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        Text(verbatim: item.name).musicText(.card).lineLimit(2)
                        let sub = [item.year.map(String.init), item.artistLine].compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty { Text(verbatim: sub).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    }
                    Spacer(minLength: MusicSpace.xs)
                    if item.status != .verified { MusicStatusChip(title: Localized.string("Possible"), symbol: "questionmark.circle") }
                }
                .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xxs).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight().atlas("control.music.songPageSample")
        }
    }
}

struct MusicSongLiveBlock: View {
    let page: MusicSongPageModel
    let items: [MusicSongVersionItem]

    var body: some View {
        MusicSongHeading(key: "Live performances")
        ForEach(items) { MusicSongVersionRow(page: page, item: $0) }
    }
}

// MARK: shelves of songs and films (items 12 to 15 and 17)

struct MusicSongShelf: View {
    let page: MusicSongPageModel
    let title: String
    let items: [MusicSongRelatedItem]
    let loading: Bool
    var film = false
    static let visible = 12

    var body: some View {
        if loading {
            MusicShelf(title: title) { EmptyView() }.loading(true)
        } else if items.count > Self.visible {
            MusicShelf(title: title) { ForEach(items.prefix(Self.visible)) { card($0, width: MusicCardGeometry.defaultWidth) } } showAll: { ForEach(items) { card($0, width: nil) } }
        } else {
            MusicShelf(title: title) { ForEach(items) { card($0, width: MusicCardGeometry.defaultWidth) } }
        }
    }

    private func card(_ item: MusicSongRelatedItem, width: CGFloat?) -> some View {
        let name = film ? (item.year.map { item.name + " (" + String($0) + ")" } ?? item.name) : item.name
        let reason = MusicSongText.reason(item.reason)
        return MusicCard(title: name, subtitle: reason.isEmpty ? item.artistLine : reason, thumbs: MusicSongText.thumbs(item.imageRef), width: width, hub: page.hub,
                         subject: .card(.recording, name: item.name, entity: item.id, year: item.year, creator: item.artistLine)) {
            page.open(item.id)
        }
        .atlasCovers("control.music.songPageCard")
    }
}

// MARK: playlists (item 16)

struct MusicSongPlaylistsBlock: View {
    let page: MusicSongPageModel
    let items: [MusicSongPlaylistItem]
    let state: MusicSongBlockState

    var body: some View {
        switch state {
        case .skeleton:
            MusicSongHeading(key: "In playlists")
            MusicSkeletonRow()
        case .content:
            MusicSongHeading(key: "In playlists")
            ForEach(items) { p in
                Button { open(p) } label: {
                    HStack(spacing: MusicSpace.sm) {
                        Image(systemName: "music.note.list").frame(width: MusicSpace.xl).foregroundStyle(ColorTokens.textSecondary).accessibilityHidden(true)
                        Text(verbatim: p.name).musicText(.card).lineLimit(1)
                        Spacer(minLength: MusicSpace.xs)
                        Text(verbatim: Localized.string(p.source == .local ? "Your playlist" : "Playlist")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                    .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xs).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight()
                .accessibilityLabel(p.name)
                .atlas("control.music.songPagePlaylist")
            }
        case .quietEmpty, .hidden:
            EmptyView()
        }
    }

    private func open(_ p: MusicSongPlaylistItem) {
        if let id = p.localID { page.hub.open(.localPlaylist(id)) } else if let e = p.entityID { page.open(e) }
    }
}
