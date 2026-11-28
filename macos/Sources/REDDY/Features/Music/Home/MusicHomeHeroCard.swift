import SwiftUI

/// The one big card of Listen Now: artwork-led, the cover's own colours washed behind the words (MusicHeroBackdrop), the reason line above the title
/// ("Because you play X"), a capsule Play and Open. 240 to 340 points high by layout class. The backdrop's picture is drawn in an overlay, so it
/// cannot set the card's size or take clicks outside it. The pick changes only when the feed is composed, never by itself.
struct MusicHomeHeroCard: View {
    let hero: HomeHero
    let hub: MusicHub
    @Environment(\.musicLayoutClass) private var layoutClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var primaryInk: Color { reduceTransparency ? ColorTokens.textPrimary : MusicInk.onArtwork }
    private var secondaryInk: Color { reduceTransparency ? ColorTokens.textSecondary : MusicInk.onArtworkSecondary }

    /// What the main button says and does: a radio idea starts a station, a film opens its page, everything else plays.
    private var primaryTitle: String {
        switch hero.kind {
        case .radioIdea: Localized.string("Start radio")
        case .filmSoundtrack: Localized.string("Open")
        default: Localized.string("Play")
        }
    }
    private var primarySymbol: String {
        switch hero.kind {
        case .radioIdea: "dot.radiowaves.left.and.right"
        case .filmSoundtrack: "arrow.up.right"
        default: "play.fill"
        }
    }
    private var showsOpen: Bool { hero.kind != .filmSoundtrack }

    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        let item = hero.item
        let art = spec.heroHeight - MusicSpace.lg * 2
        ZStack(alignment: .leading) {
            MusicHeroBackdrop(thumbs: item.thumbnails)
            HStack(alignment: .center, spacing: MusicSpace.xl) {
                if spec.heroShowsCover, !item.thumbnails.isEmpty {
                    MusicCoverImage(thumbs: item.kind == .artist ? MusicArtistPortrait.portraits(item.thumbnails) : item.thumbnails, artworkClass: .hero, size: art, corner: item.kind == .artist ? art / 2 : MusicCorner.card)
                        .musicElevation(.floating, cornerRadius: item.kind == .artist ? art / 2 : MusicCorner.card)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(verbatim: hero.reason).musicText(.caption).fontWeight(.semibold).foregroundStyle(secondaryInk).lineLimit(1)
                    Button { MusicDebugLog.log("home", "hero title tapped: \(item.title)"); MusicHomeActions.open(item, hub: hub) } label: {
                        Text(verbatim: item.title).musicText(.display).foregroundStyle(primaryInk).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
                    }.atlas("control.music.homeHeroTitle")
                    .buttonStyle(.plain).accessibilityAddTraits(.isHeader).accessibilityLabel(Localized.string("Open %@", item.title))
                    if !item.subtitle.isEmpty { Text(verbatim: item.subtitle).musicText(.body).foregroundStyle(primaryInk.opacity(0.9)).lineLimit(1) }
                    HStack(spacing: MusicSpace.sm) {
                        Button { primary() } label: { Label(primaryTitle, systemImage: primarySymbol) }
                            .musicButton(.primary).accessibilityLabel(Localized.string("%1$@ %2$@", primaryTitle, item.title)).atlas("control.music.homeHeroPlay")
                        if showsOpen {
                            Button { MusicDebugLog.log("home", "hero open tapped"); MusicHomeActions.open(item, hub: hub) } label: { Text(Localized.string("Open")) }
                                .musicButton(.secondary).accessibilityLabel(Localized.string("Open %@", item.title)).atlas("control.music.homeHeroOpen")
                        }
                    }
                    .padding(.top, MusicSpace.xs)
                }
                Spacer(minLength: 0)
            }
            .padding(MusicSpace.lg)
        }
        .frame(maxWidth: .infinity).frame(height: spec.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous))
        .musicElevation(.edge, cornerRadius: MusicCorner.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Localized.string("%1$@: %2$@", hero.reason, item.title))
    }

    private func primary() {
        MusicDebugLog.log("home", "hero primary tapped: \(hero.kind.rawValue) '\(hero.item.title)'")
        switch hero.kind {
        case .radioIdea: MusicHomeActions.startRadio(hero.item, hub: hub)
        default: MusicHomeActions.play(hero.item, hub: hub)
        }
    }
}

/// The hero's slot while the first feed loads: the same height as the real card.
struct MusicHomeHeroSkeleton: View {
    @Environment(\.musicLayoutClass) private var layoutClass
    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous).fill(ColorTokens.elevated)
            .frame(maxWidth: .infinity).frame(height: spec.heroHeight)
            .musicSkeletonShimmer()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
