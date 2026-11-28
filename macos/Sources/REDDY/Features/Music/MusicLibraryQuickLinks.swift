import SwiftUI

// One click from the top of Your library to each way into the music: Favorites, Recently added, Recently played, Most played and Never played.
// Favorites is the Songs tab and Recently added is the Recently Added section of Music; the other three open their smart collection (built from the plays on this Mac). Downloads has its own button in the tab bar.

enum MusicLibraryQuickLink: String, CaseIterable, Identifiable, Sendable {
    case favorites, recentlyAdded, recentlyPlayed, mostPlayed, neverPlayed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: Localized.string("Favorites")
        case .recentlyAdded: Localized.string("Recently added")
        case .recentlyPlayed: Localized.string("Recently played")
        case .mostPlayed: Localized.string("Most played")
        case .neverPlayed: Localized.string("Never played")
        }
    }

    var symbol: String {
        switch self {
        case .favorites: "heart"
        case .recentlyAdded: "clock.badge.checkmark"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .mostPlayed: "chart.bar"
        case .neverPlayed: "sparkles"
        }
    }

    enum Destination: Equatable, Sendable {
        case songs(sort: MusicLibrarySort)
        /// The dated "Recently added" view: songs, albums, artists, playlists and local files together.
        case recentlyAdded
        case collection(MusicCollectionKey)
    }

    /// Where the link leads. A pure mapping so the wiring is tested without a screen.
    var destination: Destination {
        switch self {
        case .favorites: .songs(sort: MusicLibraryTab.songs.defaultSort)
        case .recentlyAdded: .recentlyAdded
        case .recentlyPlayed: .collection(.recentlyPlayed)
        case .mostPlayed: .collection(.mostPlayed)
        case .neverPlayed: .collection(.neverPlayed)
        }
    }
}

/// The shortcuts under the tabs, drawn the way a designer treats a tertiary action: plain text that reads as a link, no border and no fill, a quiet dot between them,
/// the current one in the accent colour. They are not tabs and not filters, so they do not look like either.
struct MusicLibraryQuickLinks: View {
    var active: MusicLibraryQuickLink? = nil
    var onChoose: (MusicLibraryQuickLink) -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var hovered: MusicLibraryQuickLink?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MusicSpace.xs) {
                ForEach(Array(MusicLibraryQuickLink.allCases.enumerated()), id: \.element.id) { i, l in
                    if i > 0 { Text(verbatim: "·").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true) }
                    let on = l == active
                    Button {
                        MusicDebugLog.log("library", "quick link: \(l.rawValue)")
                        onChoose(l)
                    } label: {
                        Text(verbatim: l.title)
                            .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? accent : (hovered == l ? ColorTokens.textPrimary : ColorTokens.textSecondary))
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? l : (hovered == l ? nil : hovered) }
                    .accessibilityLabel(Text(verbatim: l.title)).accessibilityAddTraits(on ? .isSelected : [])
                    .atlas("control.music.libraryQuickLink")
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(Text(verbatim: Localized.string("Quick links")))
    }
}
