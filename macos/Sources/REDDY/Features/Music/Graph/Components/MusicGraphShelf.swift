import SwiftUI

// MusicGraphShelf: a titled shelf whose state comes from the entity model's section phase. It shows a skeleton of the final geometry while the section
// loads, the cards as soon as the first ones arrive (a partial result keeps showing while more land), and NOTHING at all (no heading, no empty line)
// when the section finished empty or failed with nothing to show. A source attribution, when a licence asks for one, sits under the cards.
//
// API (owned by the album/soundtrack page package; the person, song and film pages reuse it):
//   MusicGraphShelf(title: String, subtitle: String? = nil, phase: MusicSectionPhase, itemCount: Int,
//                   itemWidth: CGFloat = MusicCardGeometry.defaultWidth, posterAspect: CGFloat? = nil, textLines: Int = 2,
//                   attribution: String? = nil, onAppear: (() -> Void)? = nil, @ViewBuilder content: () -> Content)
// `posterAspect` (height over width) makes the skeleton match poster or portrait cards; nil matches square covers. `onAppear` is where a page starts the
// section's load: the page keeps its shelves in a LazyVStack, so it fires when the shelf is about one viewport from view. The shelf's own height does
// not change when the content replaces the skeleton, so late data does not push the page.

struct MusicGraphShelf<Content: View>: View {
    let title: String
    var subtitle: String?
    var phase: MusicSectionPhase
    var itemCount: Int
    var itemWidth: CGFloat
    var posterAspect: CGFloat?
    var textLines: Int
    var attribution: String?
    var onAppear: (() -> Void)?
    let content: Content

    init(title: String, subtitle: String? = nil, phase: MusicSectionPhase, itemCount: Int, itemWidth: CGFloat = MusicCardGeometry.defaultWidth,
         posterAspect: CGFloat? = nil, textLines: Int = 2, attribution: String? = nil, onAppear: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.phase = phase; self.itemCount = itemCount; self.itemWidth = itemWidth
        self.posterAspect = posterAspect; self.textLines = textLines; self.attribution = attribution; self.onAppear = onAppear; self.content = content()
    }

    /// What the shelf shows for a phase and a count. Pure (`MusicSoundtrackShelfRule`), so a test can check the hide rules.
    typealias Presentation = MusicSoundtrackShelfRule.Presentation
    static func presentation(phase: MusicSectionPhase, itemCount: Int) -> Presentation { MusicSoundtrackShelfRule.presentation(phase: phase, itemCount: itemCount) }

    var body: some View {
        Group {
            switch Self.presentation(phase: phase, itemCount: itemCount) {
            case .hidden: EmptyView()      // no heading, no gap: a stack adds no spacing around a view that is not there
            case .skeleton: skeleton
            case .cards:
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    MusicShelf(title: title, subtitle: subtitle) { content }.cardWidth(itemWidth)
                    if let attribution, !attribution.isEmpty {
                        Text(verbatim: attribution).musicText(.micro).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(attribution)
                    }
                }
            }
        }
        .onAppear { onAppear?() }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: title)
            if let posterAspect {
                HStack(alignment: .top, spacing: MusicCardGeometry.shelfSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: MusicCardGeometry.coverToText) {
                            MusicSkeletonBlock(width: itemWidth, height: itemWidth * posterAspect, corner: MusicCorner.card)
                            MusicSkeletonBlock(width: itemWidth * MusicSkeletonGeometry.titleBarRatio, height: (MusicTypeRole.card.pointSize * MusicSkeletonGeometry.barHeightRatio).rounded(),
                                               corner: MusicSpace.xxs / 2)
                        }
                    }
                }
                .padding(.vertical, MusicSpace.xxs).accessibilityHidden(true)
            } else {
                MusicShelfSkeleton(width: itemWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localized.string("Loading %1$@", title))
    }
}
