import SwiftUI

/// One titled shelf of Listen Now: the title, the line that says why it is there, and a row of tiles that scrolls sideways with hover paging buttons
/// and arrow keys (the shared shelf). Past eight items it offers "Show all" in a grid. The covers just past the visible edge are warmed ahead of the scroll.
/// Cards are as wide as the layout class says, so the row and its skeleton are the same size.
struct MusicHomeShelf: View {
    let section: HomeSection
    let hub: MusicHub
    @Environment(\.musicLayoutClass) private var layoutClass
    @Environment(\.displayScale) private var displayScale

    private var items: [HomeItem] { section.items }
    private var queue: [MusicTrack] { items.compactMap(\.track) }

    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        let px = MusicArtworkClass.tile.pixels(scale: displayScale)
        let addresses = items.compactMap { MusicArtworkService.pickThumbnail($0.thumbnails, neededPixels: px) }
        let shown = Array(items.prefix(16))
        Group {
            if items.count > 8 {
                MusicShelf(title: section.title) {
                    ForEach(shown, id: \.id) { MusicHomeTile(item: $0, hub: hub, width: spec.tileWidth, queue: queue) }
                } showAll: {
                    ForEach(items, id: \.id) { MusicHomeTile(item: $0, hub: hub, width: nil, queue: queue) }
                }
                .modified(width: spec.tileWidth, section: section, addresses: addresses)
            } else {
                MusicShelf(title: section.title) {
                    ForEach(shown, id: \.id) { MusicHomeTile(item: $0, hub: hub, width: spec.tileWidth, queue: queue) }
                }
                .modified(width: spec.tileWidth, section: section, addresses: addresses)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
    }
}

extension MusicShelf {
    /// The shelf with its card width, the line that says why it is there, and the artwork warm-up.
    fileprivate func modified(width: CGFloat, section: HomeSection, addresses: [String]) -> Self {
        cardWidth(width).detail(section.reason).prefetching(addresses, artworkClass: .tile)
    }
}

/// A shelf that is still loading: the title bar and tiles at their final size.
struct MusicHomeShelfSkeleton: View {
    @Environment(\.musicLayoutClass) private var layoutClass
    var round = false
    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSkeletonBlock(width: 160, height: 20, corner: MusicSpace.xxs)
            HStack(alignment: .top, spacing: MusicCardGeometry.shelfSpacing) {
                ForEach(0..<5, id: \.self) { _ in MusicSkeletonCard(width: spec.tileWidth, round: round) }
            }
            .musicSkeletonShimmer()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
