import SwiftUI

// The layouts of Apple Music's New and Radio pages, in the app's own colours: a heading that links on, a row of wide feature cards (the words above the picture), a grid
// of compact song rows in columns, and a grid of media rows (a square cover, a small label, a title and a line about it). Pure layout: every part opens and plays through the
// same calls the shelves and cards already use.

/// A section heading. With an action it carries a chevron and the whole heading is the button ("Best new songs ›").
struct MusicLinkHeading: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                HStack(spacing: MusicSpace.xxs) {
                    Text(verbatim: title).font(Typography.title)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ColorTokens.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(.isHeader).accessibilityLabel(title).atlasCovers("control.music.sharedPartsMusiccardcardButton")
        } else {
            Text(verbatim: title).font(Typography.title).accessibilityAddTraits(.isHeader).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MusicBrowseItem {
    /// The entity a card for this item opens or plays.
    var editorialEntity: MusicEntity {
        switch self {
        case .album(let a): .album(a)
        case .artist(let a): .artist(a)
        case .playlist(let p): .playlist(p)
        case .track(let t): .track(t)
        }
    }
    var editorialKind: String {
        switch self {
        case .album: Localized.string("Album")
        case .artist: Localized.string("Artist")
        case .playlist: Localized.string("Playlist")
        case .track: Localized.string("Song")
        }
    }
    var editorialTitle: String { editorialEntity.title }
    var editorialSubtitle: String {
        switch self {
        case .album(let a): MusicHeroText.cardCredit(a.artists)
        case .artist: ""
        case .playlist(let p): MusicPlaylistCaption.line(p)
        case .track(let t): MusicHeroText.cardCredit(t.artists)
        }
    }
    var editorialThumbs: [MusicThumbnail] {
        switch self {
        case .album(let a): a.thumbnails
        case .artist(let a): a.thumbnails
        case .playlist(let p): p.thumbnails
        case .track(let t): t.thumbnails
        }
    }
}

/// Up to three wide cards in a row: the kind in small capitals, the title and the line under it, then the picture (wider than tall) with its corners rounded.
struct MusicFeatureCards: View {
    let items: [MusicBrowseItem]
    let hub: MusicHub

    var body: some View {
        let shown = Array(items.prefix(3))
        if !shown.isEmpty {
            HStack(alignment: .top, spacing: MusicSpace.md) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in card(item) }
                if shown.count < 3 { ForEach(0..<(3 - shown.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) } }
            }
        }
    }

    private func card(_ item: MusicBrowseItem) -> some View {
        Button { MusicEntityActions.open(item.editorialEntity, hub: hub) } label: {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.editorialKind.uppercased()).font(Typography.eyebrow).tracking(1.0).foregroundStyle(ColorTokens.textTertiary)
                    Text(verbatim: item.editorialTitle).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    Text(verbatim: item.editorialSubtitle.isEmpty ? " " : item.editorialSubtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                Color.clear.aspectRatio(1.55, contentMode: .fit)
                    .overlay { MusicCoverImage(thumbs: item.editorialThumbs, artworkClass: .hero, corner: 0, seed: item.editorialEntity.key) }
                    .clipShape(RoundedRectangle(cornerRadius: MusicCorner.cardLarge, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: MusicCorner.cardLarge, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.cardLarge)
        .accessibilityLabel([item.editorialTitle, item.editorialSubtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .atlas("control.music.sharedPartsMusiccardcardButton")
    }
}

/// Songs as compact rows in columns (three where the page is wide enough): cover, title and artist, the heart and the menu of the song row.
struct MusicSongGrid: View {
    let tracks: [MusicTrack]
    let hub: MusicHub
    /// A chart: each row carries its place (1, 2, 3...), in the number column the song rows already have.
    var ranked = false
    /// What a tapped row plays on through, when that is more than the rows shown (a chart cut to its first rows plays the whole chart).
    var queue: [MusicTrack]? = nil

    private var options: MusicRowOptions {
        var o = MusicRowOptions()
        o.columns = MusicTrackColumns(shown: [])
        o.cellData = MusicTrackCells.data(for: tracks)
        return o
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: MusicSpace.md, alignment: .top)], alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.uid) { i, t in MusicTrackRow(track: t, index: ranked ? i : nil, queue: queue ?? tracks, hub: hub, options: options) }
        }
    }
}


