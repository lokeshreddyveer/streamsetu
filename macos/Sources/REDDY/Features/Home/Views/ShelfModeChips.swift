import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The header every ranked shelf shares (Trending in Your Library and each genre shelf), on Mac, iPhone and iPad:
//   row 1: title (left)                                   See all ›  (right, genre shelves)
//   row 2: one short subtitle (secondary)        [ All time | This week ]  (small segmented control)
// Same pieces on every shelf. At large Dynamic Type sizes the second row stacks (subtitle, then the control) so nothing truncates.

/// The two-option view switch: a small segmented control with a sliding selection, a light haptic on touch devices, no animation with Reduce Motion.
/// The control is 30 pt tall; the touch target is 44 pt (the hit area reaches past the drawn shape).
struct ShelfModeControl: View {
    let shelfTitle: String
    let mode: SMShelfMode
    let onSelect: (SMShelfMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var slide

    var body: some View {
        HStack(spacing: 0) {
            segment(.allTime, "All time", spoken: "All time top")
            segment(.weekly, "This week", spoken: "Trending this week")
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: mode)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ranking for \(shelfTitle)"))
    }

    private func segment(_ m: SMShelfMode, _ label: LocalizedStringKey, spoken: LocalizedStringKey) -> some View {
        let on = mode == m
        return Button {
            guard !on else { return }
            Haptics.tap()
            onSelect(m)
        } label: {
            Text(label).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.65))
                .padding(.horizontal, 10).frame(minWidth: 64, minHeight: 26)
                .background {
                    if on { Capsule().fill(ColorTokens.accentDefault.opacity(0.30)).overlay(Capsule().strokeBorder(ColorTokens.accentDefault.opacity(0.9), lineWidth: 1)).matchedGeometryEffect(id: "selection", in: slide) }
                }
                .contentShape(Rectangle().inset(by: -9))          // hit slop: 44 pt target around the 26 pt segment
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spoken))
        .accessibilityAddTraits(on ? [.isSelected] : []).atlas("control.home.shelfMode")
    }
}

/// "See all ›" for the right end of the title row.
struct SeeAllLabel: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("See all")
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        .frame(height: 24).contentShape(Rectangle().inset(by: -10))
    }
}

/// Title row + subtitle row. `title` is the platform's own title text; `trailing` sits at the right end of the title row (See all, and the Mac scroll arrows).
struct ShelfHeader<Title: View, Trailing: View>: View {
    let shelfTitle: String
    let title: Title
    var caption: String?
    var mode: SMShelfMode?
    var onMode: ((SMShelfMode) -> Void)?
    let trailing: Trailing

    private var hasSecondRow: Bool { !(caption ?? "").isEmpty || (mode != nil && onMode != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                title.lineLimit(2).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            if hasSecondRow {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) { subtitle.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 8); control }
                    VStack(alignment: .leading, spacing: 6) { subtitle; control }
                }
                .frame(minHeight: 30)                  // the same height whichever view is on, so nothing moves when it changes
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        if let caption, !caption.isEmpty { Text(caption.loc).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
    }

    @ViewBuilder private var control: some View {
        if let mode, let onMode { ShelfModeControl(shelfTitle: shelfTitle, mode: mode, onSelect: onMode) }
    }
}

// MARK: - Home layout system (docs/SMART-MIX.md section 11)

/// One spacing system for every Home row on Mac, iPhone and iPad (an 8-pt grid with 4-pt half steps): rows are 24 apart, a header sits 12 above its tiles, tiles are 12 apart.
/// The title, subtitle, control, See all and the first tile share one leading edge (the screen's content inset).
enum HomeLayout {
    static let rowGap: CGFloat = 24
    static let headerGap: CGFloat = 12
    static let tileGap: CGFloat = 12
    static let subtitleRowHeight: CGFloat = 30
}

/// A franchise on the Collections row: the lead poster with two cards peeking out behind it, the franchise name (two lines at most, always reserved) and "N titles".
/// Same poster size as the other rows, so the row lines up with its neighbours.
struct CollectionTileCard: View {
    let tile: CollectionTile
    var width: CGFloat = 150
    let onOpen: () -> Void
    private let peek: CGFloat = 8

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    ForEach([2, 1], id: \.self) { layer in
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(layer == 2 ? 0.07 : 0.12))
                            .frame(width: width - CGFloat(layer) * 14, height: width * 1.5).offset(y: -CGFloat(layer) * peek)
                    }
                    ArtworkImage(url: tile.lead.posterURL.nilIfEmpty ?? tile.lead.backdropURL, kind: .poster, contentMode: .fill, symbol: "square.stack.3d.up",
                                 tile: .init(title: tile.name, detail: nil, showsTitle: true))
                        .frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .frame(width: width, height: width * 1.5 + 2 * peek, alignment: .bottom)
                Text(tile.name).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading).frame(width: width, alignment: .leading)
                Text("\(tile.count) titles").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore).accessibilityLabel(Text("\(tile.name), \(tile.count) titles")).accessibilityHint(Text("Shows every title in this collection"))
        .atlas("control.home.collection")
    }
}

/// The grid of titles a collection tile opens (sheet on Mac, pushed screen on iPhone and iPad). `card` draws one title.
struct CollectionGrid<Card: View>: View {
    let tile: CollectionTile
    var width: CGFloat = 130
    @ViewBuilder let card: (LibraryItem) -> Card
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 20), spacing: HomeLayout.tileGap, alignment: .top)], alignment: .leading, spacing: HomeLayout.rowGap) {
                ForEach(tile.members) { card($0) }
            }.padding(HomeLayout.tileGap + 4)
        }
    }
}

/// The shape of a Home row while it loads: a header (title, subtitle row) and a line of tiles with the same measurements as a real row, so nothing jumps when the rows arrive.
struct ShelfSkeleton: View {
    var tileWidth: CGFloat = 150
    var tiles = 7
    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerGap) {
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBlock(width: 180, height: 20, radius: 6)
                SkeletonBlock(width: 120, height: 12, radius: 6).frame(minHeight: HomeLayout.subtitleRowHeight, alignment: .leading)
            }
            HStack(alignment: .top, spacing: HomeLayout.tileGap) {
                ForEach(0..<tiles, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: tileWidth, height: tileWidth * 1.5, radius: 9)
                        SkeletonBlock(width: tileWidth * 0.8, height: 12, radius: 5)
                        SkeletonBlock(width: tileWidth * 0.5, height: 10, radius: 5)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
