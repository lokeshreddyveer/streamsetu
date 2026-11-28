import SwiftUI

/// Which Explore shelf the person opened with "See all". Explore shows that shelf as a full page (every item, in a grid) in place of the shelves, and Back returns to them.
@MainActor @Observable
final class MusicExploreSeeAll {
    static let shared = MusicExploreSeeAll()
    var section: MusicBrowseSection?
}

/// The full list behind an Explore shelf: the whole chart or list, with a Back button and Play when it holds songs.
struct MusicExploreSeeAllPage: View {
    let section: MusicBrowseSection
    let hub: MusicHub
    let back: () -> Void

    /// Each item once (a chart that repeats an item would give the grid two rows with one id).
    private var uniqueItems: [MusicBrowseItem] { var seen = Set<MusicBrowseItem>(); return section.items.filter { seen.insert($0).inserted } }

    private var songs: [MusicTrack] { section.items.compactMap { if case .track(let t) = $0 { t } else { nil } } }

    var body: some View {
        MusicScreen(title: section.title, trailing: { playButton }, content: {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                Button { back() } label: { Label(Localized.string("Back to Explore"), systemImage: "chevron.left") }
                    .musicButton(.tertiary, size: .compact).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Localized.string("Back to Explore")).atlas("control.music.exploreSeeAllBack")
                LazyVGrid(columns: MusicLayout.gridColumns, alignment: .leading, spacing: 18) {
                    ForEach(uniqueItems, id: \.self) { MusicCard(result: $0, queue: songs, hub: hub, width: nil) }
                }
            }
        })
        .atlas("control.music.exploreSeeAllPage")
    }

    @ViewBuilder private var playButton: some View {
        if songs.count >= 2 {
            Button { hub.play(songs, at: 0, sourceName: section.title) } label: { Label(Localized.string("Play"), systemImage: "play.fill") }
                .musicButton(.primary, size: .compact).atlas("control.music.exploreSeeAllPlay")
        }
    }
}
