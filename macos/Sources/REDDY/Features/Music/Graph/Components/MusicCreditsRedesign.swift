import SwiftUI

// The credits of a song, album or film, drawn the way a booklet reads: three short groups (the music, the words and voices, the film's crew), each name a tile with a
// round photo, the name, and what they did, then the cast as one row of portraits. A group shows its first few names and opens in place for the rest; nothing is a
// paragraph and no chip is a sentence. Grouping follows what the services do (Apple Music: performers, composition and lyrics, production; films: cast apart from crew).

/// One person in one group, with every role they hold there ("Music director · Composer"), so a person credited twice is one tile.
struct MusicCreditTile: Identifiable, Hashable, Sendable {
    var id: MusicEntityID
    var name: String
    var roles: [String]
    var openRole: MusicRole
    /// How many of this release's songs they are credited on, when that says something.
    var songs: Int

    var caption: String {
        var parts = roles
        if songs > 0 { parts.append(Localized.plural(songs, one: "%@ song", other: "%@ songs")) }
        return parts.joined(separator: " · ")
    }
}

struct MusicCreditGroupModel: Identifiable, Sendable {
    var id: String
    var title: String
    var tiles: [MusicCreditTile]

    /// Merges credits into tiles by person, in the order the credits arrive.
    static func tiles(_ credits: [(credit: MusicSoundtrackCredit, roleName: String)], songTotal: Int) -> [MusicCreditTile] {
        var order: [MusicEntityID] = []
        var byID: [MusicEntityID: MusicCreditTile] = [:]
        for (c, roleName) in credits {
            let songs = (songTotal > 1 && c.songCount > 0 && c.songCount < songTotal) ? c.songCount : 0
            if var t = byID[c.person.id] {
                if !t.roles.contains(roleName) { t.roles.append(roleName) }
                t.songs = max(t.songs, songs)
                byID[c.person.id] = t
            } else {
                order.append(c.person.id)
                byID[c.person.id] = MusicCreditTile(id: c.person.id, name: c.person.name, roles: [roleName], openRole: c.role, songs: songs)
            }
        }
        return order.compactMap { byID[$0] }
    }
}

struct MusicCreditsGroupView: View {
    let group: MusicCreditGroupModel
    let onOpen: (MusicCreditTile) -> Void
    /// Names shown before "Show all".
    static let collapsedLimit = 4
    @State private var expanded = false

    private var shown: [MusicCreditTile] { expanded || group.tiles.count <= Self.collapsedLimit + 1 ? group.tiles : Array(group.tiles.prefix(Self.collapsedLimit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: group.title.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if group.tiles.count > Self.collapsedLimit + 1 {
                    Button { withAnimation(.easeOut(duration: 0.22)) { expanded.toggle() } } label: {
                        Text(verbatim: expanded ? Localized.string("Show less") : Localized.string("Show all %d", group.tiles.count))
                    }
                    .musicButton(.tertiary, size: .compact).atlasCovers("control.music.graphCreditChip")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: MusicSpace.xs, alignment: .leading)], alignment: .leading, spacing: MusicSpace.xs) {
                ForEach(shown) { tile in MusicCreditTileView(tile: tile, group: group.title) { onOpen(tile) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct MusicCreditTileView: View {
    let tile: MusicCreditTile
    let group: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.sm) {
                MusicCoverImage(thumbs: [], artworkClass: .trackThumb, size: 40, corner: 20, seed: tile.name, initials: MusicArtistPortrait.initials(tile.name),
                                subject: .card(.person, name: tile.name, entity: tile.id))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: tile.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    Text(verbatim: tile.caption).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ColorTokens.textTertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, MusicSpace.sm).padding(.vertical, MusicSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ColorTokens.elevated : ColorTokens.surface, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel([tile.name, tile.caption, group].filter { !$0.isEmpty }.joined(separator: ", "))
        .help(tile.name)
        .atlas("control.music.graphCreditChip")
    }
}

/// The cast: one row of portraits, name and character beneath, scrolling sideways; the first few are the lead roles.
struct MusicCreditsCastRow: View {
    struct Member: Identifiable, Hashable, Sendable { var id: MusicEntityID; var name: String; var character: String? }
    let cast: [Member]
    let onOpen: (Member) -> Void

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(verbatim: Localized.string("Cast").uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MusicSpace.md) {
                        ForEach(cast) { m in
                            Button { onOpen(m) } label: {
                                VStack(spacing: MusicSpace.xs) {
                                    MusicCoverImage(thumbs: [], artworkClass: .trackThumb, size: 64, corner: 32, seed: m.name, initials: MusicArtistPortrait.initials(m.name),
                                                    subject: .card(.person, name: m.name, entity: m.id))
                                        .accessibilityHidden(true)
                                    Text(verbatim: m.name).font(Typography.caption).foregroundStyle(ColorTokens.textPrimary).lineLimit(2).multilineTextAlignment(.center)
                                    if let c = m.character, !c.isEmpty { Text(verbatim: c).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary).lineLimit(1) }
                                }
                                .frame(width: 92)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.card)
                            .accessibilityLabel([m.name, m.character].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                            .atlas("control.music.graphCreditChip")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
