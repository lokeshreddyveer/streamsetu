import SwiftUI

/// Quick picks: a grid of songs to start in one tap (the grid the song pages use), under the hero. It is drawn anew each visit.
struct MusicHomeQuickPicks: View {
    let section: HomeSection
    let hub: MusicHub

    var body: some View {
        let tracks = section.items.compactMap(\.track)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: section.title)
            if let r = section.reason { Text(verbatim: r).musicText(.caption).foregroundStyle(ColorTokens.textSecondary) }
            MusicSongGrid(tracks: tracks, hub: hub, ranked: false)
        }
        .accessibilityElement(children: .contain)
    }
}
