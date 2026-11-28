import SwiftUI

// States: skeleton placeholders, empty and error pages, the partial-failure banner and chips. Nothing here moves while idle; the one bounded
// motion (a short skeleton pulse) is off unless asked for and never runs under Reduce Motion.

// MARK: - Skeleton geometry (pure)

/// Placeholder sizes derived from `MusicCardGeometry`, so a skeleton card occupies exactly the box of the card that replaces it.
enum MusicSkeletonGeometry {
    struct CardParts: Equatable {
        var cover: CGSize
        var titleBar: CGSize
        var subtitleBar: CGSize
        var titleBox: CGFloat
        var subtitleBox: CGFloat
        var coverToText: CGFloat
        var textSpacing: CGFloat
        /// Total height of the placeholder (cover, gap, text block).
        var height: CGFloat { cover.height + coverToText + titleBox + textSpacing + subtitleBox }
    }

    static let titleBarRatio: CGFloat = 0.8
    static let subtitleBarRatio: CGFloat = 0.55
    /// Bars are a little shorter than their line boxes.
    static let barHeightRatio: CGFloat = 0.7

    static func card(width: CGFloat) -> CardParts {
        let side = MusicCardGeometry.coverSide(width: width)
        return CardParts(
            cover: CGSize(width: side, height: side),
            titleBar: CGSize(width: side * titleBarRatio, height: (MusicTypeRole.card.pointSize * barHeightRatio).rounded()),
            subtitleBar: CGSize(width: side * subtitleBarRatio, height: (MusicTypeRole.caption.pointSize * barHeightRatio).rounded()),
            titleBox: MusicCardGeometry.titleLineHeight, subtitleBox: MusicCardGeometry.subtitleLineHeight,
            coverToText: MusicCardGeometry.coverToText, textSpacing: MusicCardGeometry.textSpacing)
    }

    /// How many placeholder cards fill `available` points of a shelf (at least one).
    static func cardCount(available: CGFloat, width: CGFloat) -> Int {
        let step = MusicCardGeometry.step(width: width)
        guard step > 0, available.isFinite, available > 0 else { return 1 }
        return max(1, Int(((available + MusicCardGeometry.shelfSpacing) / step).rounded(.up)))
    }
}

/// When a screen shows a banner over healthy results, and when it shows a full error instead.
enum MusicPartialFailure {
    static func showsBanner(healthy: Int, failed: Int) -> Bool { healthy > 0 && failed > 0 }
    static func showsFullError(healthy: Int, failed: Int) -> Bool { healthy == 0 && failed > 0 }
}

// MARK: - Skeleton primitives

/// A flat rounded block in the card colour. Static.
struct MusicSkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var corner: CGFloat = MusicCorner.control
    var emphasis = true
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(emphasis ? ColorTokens.elevated : ColorTokens.card)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

private struct MusicSkeletonPulseModifier: ViewModifier {
    let enabled: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let cycles = 2
    static let dimmedOpacity = 0.55

    func body(content: Content) -> some View {
        content
            .opacity(dim ? Self.dimmedOpacity : 1)
            .task {
                guard enabled, !reduceMotion else { return }
                let step = MusicMotion.seconds(.panel, reduce: false)
                for _ in 0..<(Self.cycles * 2) {
                    if Task.isCancelled { break }
                    withAnimation(MusicMotion.animation(.panel, reduce: false)) { dim.toggle() }
                    try? await Task.sleep(for: .seconds(step))
                }
                withAnimation(MusicMotion.animation(.fade, reduce: reduceMotion)) { dim = false }
            }
    }
}

/// A soft band of light that sweeps across placeholders: three sweeps and it stops, so a slow load shows life without an animation running forever.
/// Nothing moves under Reduce Motion. Drawn over the placeholders only (masked to them).
private struct MusicSkeletonShimmerModifier: ViewModifier {
    let enabled: Bool
    @State private var phase: CGFloat = -0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let sweeps = 3
    static let sweepSeconds = 1.4
    static let startDelay = 1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, ColorTokens.textPrimary.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: phase * g.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .task {
                guard enabled, !reduceMotion else { return }
                // Fluent's shimmer guidance: for loads of more than about a second. A quick load never shows it.
                try? await Task.sleep(for: .seconds(Self.startDelay))
                for _ in 0..<Self.sweeps {
                    if Task.isCancelled { return }
                    phase = -0.5
                    withAnimation(.linear(duration: Self.sweepSeconds)) { phase = 1.0 }
                    try? await Task.sleep(for: .seconds(Self.sweepSeconds + 0.2))
                }
            }
    }
}

extension View {
    /// A shimmer over placeholders for a slow load: three sweeps, then still; none under Reduce Motion.
    func musicSkeletonShimmer(_ enabled: Bool = true) -> some View { modifier(MusicSkeletonShimmerModifier(enabled: enabled)) }
    /// A short pulse (two cycles) for placeholders on a slow load. Does nothing under Reduce Motion, and never repeats forever.
    func musicSkeletonPulse(_ enabled: Bool = true) -> some View { modifier(MusicSkeletonPulseModifier(enabled: enabled)) }
}

/// One placeholder card with the geometry of `MusicCard`.
struct MusicSkeletonCard: View {
    var width: CGFloat = MusicCardGeometry.defaultWidth
    var round = false
    var body: some View {
        let parts = MusicSkeletonGeometry.card(width: width)
        VStack(alignment: round ? .center : .leading, spacing: parts.coverToText) {
            MusicSkeletonBlock(width: parts.cover.width, height: parts.cover.height, corner: round ? MusicCardGeometry.roundCorner : MusicCorner.card)
            VStack(alignment: round ? .center : .leading, spacing: parts.textSpacing) {
                MusicSkeletonBlock(width: parts.titleBar.width, height: parts.titleBar.height, corner: MusicSpace.xxs / 2)
                    .frame(height: parts.titleBox)
                MusicSkeletonBlock(width: parts.subtitleBar.width, height: parts.subtitleBar.height, corner: MusicSpace.xxs / 2, emphasis: false)
                    .frame(height: parts.subtitleBox)
            }
        }
        .frame(width: width, height: parts.height, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// A placeholder song row: cover, two text bars.
struct MusicSkeletonRow: View {
    var cover: CGFloat = MusicSpace.huge
    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            MusicSkeletonBlock(width: cover, height: cover, corner: MusicCorner.control)
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                MusicSkeletonBlock(width: cover * 4, height: MusicSpace.xs + MusicSpace.xxs / 2, corner: MusicSpace.xxs / 2)
                MusicSkeletonBlock(width: cover * 2.5, height: MusicSpace.xs, corner: MusicSpace.xxs / 2, emphasis: false)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}

/// Still placeholders for a shelf that has not loaded yet; the cards have the final geometry.
struct MusicShelfSkeleton: View {
    var width: CGFloat = MusicCardGeometry.defaultWidth
    var count = 6
    var pulse = false
    /// The shimmer is on by default: a shelf that is still loading looks alive without moving forever.
    var shimmer = true
    var body: some View {
        HStack(alignment: .top, spacing: MusicCardGeometry.shelfSpacing) {
            ForEach(0..<max(1, count), id: \.self) { _ in MusicSkeletonCard(width: width) }
        }
        .padding(.vertical, MusicSpace.xxs)
        .musicSkeletonPulse(pulse)
        .musicSkeletonShimmer(shimmer)
        .accessibilityHidden(true)
    }
}

// MARK: - Empty, loading and error

/// Centered message for an empty page. Still: nothing here moves, so an idle screen costs no CPU.
struct MusicEmptyState: View {
    enum Icon { case symbol(String), glyph(MusicGlyph) }
    let icon: Icon
    let title: String
    var message: String = ""
    var actionTitle: String?
    var action: (() -> Void)?
    var compact = false

    init(symbol: String, title: String, message: String = "", actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = .symbol(symbol); self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action
    }

    /// The same page with one of the drawn glyphs (`.emptyLibrary`, `.emptySearch`, `.offline`, `.note`, ...).
    init(glyph: MusicGlyph, title: String, message: String = "", actionTitle: String? = nil, action: (() -> Void)? = nil, compact: Bool = false) {
        self.icon = .glyph(glyph); self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action; self.compact = compact
    }

    private var badge: CGFloat { compact ? MusicSpace.giant : MusicSpace.giant + MusicSpace.xl }

    var body: some View {
        VStack(spacing: MusicSpace.xs) {
            Group {
                switch icon {
                case .symbol(let name): Image(systemName: name).font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textTertiary)
                case .glyph(let g): MusicIcon(glyph: g, size: compact ? MusicIconSize.toolbar : MusicIconSize.hero, tint: .tertiary)
                }
            }
            .frame(width: badge, height: badge).background(ColorTokens.elevated, in: Circle()).accessibilityHidden(true)
            Text(verbatim: title).musicText(compact ? .card : .section).multilineTextAlignment(.center)
            if !message.isEmpty { Text(verbatim: message).musicText(.body).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420) }
            if let actionTitle, let action { Button(actionTitle, action: action).musicButton(.secondary).padding(.top, MusicSpace.xxs).atlas("control.music.sharedPartsMusicemptystatebodyButton") }
        }
        .frame(maxWidth: .infinity).padding(.vertical, compact ? MusicSpace.md : MusicSpace.xl + MusicSpace.xxs).padding(.horizontal, MusicSpace.md)
        .accessibilityElement(children: .contain)
    }
}

/// Placeholder rows with a soft shimmer, shown only while something loads (Apple's loading guidance: show something at once, replace it as content
/// arrives). The shimmer stops after three sweeps and is absent under Reduce Motion; VoiceOver hears "Loading…".
struct MusicLoadingView: View {
    var rows = 3
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) { ForEach(0..<max(1, rows), id: \.self) { _ in MusicSkeletonRow() } }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .musicSkeletonShimmer()
            .accessibilityElement(children: .ignore).accessibilityLabel(Localized.string("Loading content"))
    }
}

/// The whole page failed: a drawn glyph, what happened, and a retry.
struct MusicErrorState: View {
    var title: String
    var message: String = ""
    var retryTitle: String?
    var retry: (() -> Void)?

    init(title: String = Localized.string("Could not load"), message: String = "", retryTitle: String? = nil, retry: (() -> Void)? = nil) {
        self.title = title; self.message = message; self.retryTitle = retryTitle; self.retry = retry
    }

    var body: some View {
        VStack(spacing: MusicSpace.xs) {
            MusicEmptyState(glyph: .offline, title: title, message: message)
            if let retry {
                Button(retryTitle ?? Localized.string("Try again"), action: retry)
                    .musicButton(.secondary).atlas("control.music.errorRetry")
            }
        }
        .padding(.bottom, MusicSpace.md)
        .accessibilityElement(children: .contain)
    }
}

/// Part of a page failed while the rest loaded: this banner sits above the healthy results, which stay visible.
struct MusicPartialFailureBanner: View {
    var message: String = Localized.string("Some results could not be loaded.")
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.warning).accessibilityHidden(true)
            Text(verbatim: message).musicText(.secondary).foregroundStyle(ColorTokens.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
            if let onRetry {
                Button("Try again", action: onRetry).musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.bannerRetry")
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                        .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight().accessibilityLabel("Dismiss").musicTooltip("Dismiss").atlas("control.music.bannerDismiss")
            }
        }
        .padding(.horizontal, MusicSpace.md)
        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Chips

/// THE chip of Music: one capsule for every filter, scope, tab and choice (search types, library tabs, language, person roles, filmography filters).
/// - at rest: quiet, a hairline edge; hover lifts it; the keyboard ring shows for the keyboard only;
/// - chosen: a tint of the accent, an accent edge and a CHECK, so the state never rests on colour alone; VoiceOver says "selected";
/// - `systemImage` leads when it is not chosen (the check replaces it when it is); `trailing` adds a chevron for a chip that opens a menu;
/// - pressing a chosen chip is the caller's to answer (a filter clears itself; a tab does nothing).
/// A static label ("Film credit") is not a chip: see `MusicGraphTagView`.
struct MusicChip: View {
    enum Trailing { case none, chevron }
    let title: String
    let selected: Bool
    var systemImage: String?
    var trailing: Trailing = .none
    let action: () -> Void

    init(title: String, selected: Bool, systemImage: String? = nil, trailing: Trailing = .none, action: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.systemImage = systemImage; self.trailing = trailing; self.action = action
    }

    @Environment(\.reddyAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.xxs) {
                if selected { Image(systemName: "checkmark").font(.system(size: MusicIconSize.small, weight: .bold)).foregroundStyle(accent).accessibilityHidden(true) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: MusicIconSize.small, weight: .semibold)).accessibilityHidden(true) }
                Text(verbatim: title)
                if trailing == .chevron { Image(systemName: "chevron.down").font(.system(size: MusicIconSize.tiny, weight: .bold)).accessibilityHidden(true) }
            }
        }
        .musicButton(.chip, size: .compact, selected: selected)
        .accessibilityAddTraits(selected ? .isSelected : []).atlas("control.music.sharedPartsMusicchipbodyButton")
    }
}

/// The look of a chip on something that cannot be a Button (a Menu's label): the same capsule, edge and text, so a menu chip sits in a row of chips without
/// being a different shape. It is only the surface; the Menu keeps its own click and keyboard behaviour.
struct MusicChipSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(MusicButtonSize.compact.role.font).foregroundStyle(ColorTokens.textSecondary)
            .padding(.horizontal, MusicButtonSize.compact.horizontalPadding)
            .frame(minWidth: MusicSpace.huge, minHeight: MusicButtonMetrics.height(.compact))
            .background(ColorTokens.elevated, in: Capsule())
            .overlay(Capsule().strokeBorder(ColorTokens.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

extension View {
    /// Makes a Menu's label look like a chip (see `MusicChipSurface`).
    func musicChipSurface() -> some View { modifier(MusicChipSurface()) }
}
