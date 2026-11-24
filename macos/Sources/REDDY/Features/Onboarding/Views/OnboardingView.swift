import SwiftUI

/// Shown only while no playlist exists. Two columns on the dark start backdrop: the TV symbol, headline and what StreamSetu
/// promises on the left; the ways to connect (the same form the Add Source sheet uses) on the right. On a narrow window the
/// columns stack, and the page scrolls whenever it does not fit.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(\.container) private var container
    @State private var restore = ICloudRestore()

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            let symbol = min(300, max(220, geo.size.width * 0.19))
            let headline = min(52, max(44, geo.size.width * 0.034))
            ScrollView(.vertical) {
                Group {
                    if wide {
                        // About 45% for the introduction and 55% for the ways to connect, each with a sensible maximum. Near the
                        // window's minimum width the tiles get a little more of it, so their titles do not wrap.
                        let roomy = geo.size.width >= 1200
                        let gap: CGFloat = roomy ? 56 : 40
                        let content = min(geo.size.width - (roomy ? 128 : 96), 1240)
                        HStack(alignment: .center, spacing: gap) {
                            intro(symbol: symbol, headline: headline).frame(width: min(520, (content - gap) * (roomy ? 0.45 : 0.4)), alignment: .leading)
                            connect.frame(maxWidth: 680, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 40) {
                            intro(symbol: 160, headline: 44)
                            connect.frame(maxWidth: 640, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: 1240)
                .padding(.horizontal, geo.size.width >= 1200 ? 64 : (wide ? 48 : 32)).padding(.vertical, 48)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.automatic)
            .background(StartBackdrop(glowCenter: wide ? UnitPoint(x: glowX(width: geo.size.width), y: 0.3) : UnitPoint(x: 0.3, y: 0.12)))
        }
        .preferredColorScheme(.dark)
        // The welcome comes before any theme choice, so it keeps the brand palette.
        .environment(\.startBranded, true)
        .startMotionGate()
    }

    /// The teal glow sits behind the symbol, which is centred over the left column.
    private func glowX(width: CGFloat) -> CGFloat {
        let content = min(width - (width >= 1200 ? 128 : 96), 1240)
        let left = (width - content) / 2
        return (left + content * 0.2) / max(width, 1)
    }

    private func intro(symbol: CGFloat, headline: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FloatingBrandSymbol(size: symbol).padding(.leading, -symbol * 0.06).startRiseIn()
            Text("STREAMSETU").font(.system(size: 12, weight: .bold)).tracking(3.2).foregroundStyle(StartStyle.textSecondary(true))
                .padding(.top, 18).startRiseIn(delay: 0.05)
            Text("Your streams. One home.").font(.system(size: headline, weight: .bold)).tracking(-headline * 0.025).foregroundStyle(StartStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                .accessibilityAddTraits(.isHeader).startRiseIn(delay: 0.08)
            Text("Bring the playlists, logins and media servers you already have. StreamSetu keeps them together and plays them.")
                .font(.system(size: 16)).lineSpacing(3).foregroundStyle(StartStyle.textSecondary(true))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14).startRiseIn(delay: 0.11)
            trust.padding(.top, 28).startRiseIn(delay: 0.14)
        }
    }

    /// Three short promises, side by side when they fit, otherwise one under the other.
    private var trust: some View {
        let items: [(String, String)] = [("lock.fill", "Logins stay encrypted on this device"),
                                         ("person.crop.circle.badge.xmark", "No account needed"),
                                         ("shippingbox", "Nothing is included: you bring your own")]
        let row = { (item: (String, String)) in
            Label { Text(item.1.loc) } icon: { Image(systemName: item.0).foregroundStyle(StartStyle.teal) }
                .font(.system(size: 13)).foregroundStyle(StartStyle.textSecondary(true))
        }
        return VStack(alignment: .leading, spacing: 10) { ForEach(items, id: \.1) { row($0) } }
            .accessibilityElement(children: .combine)
    }

    private var connect: some View {
        AddSourceForm(onAdded: { added in state.reload(); state.playlistAdded(added.id); router.navigate(.home, .shortcut(.discover)) }) {
            restoreActions.padding(.top, Spacing.xxl).startRiseIn(delay: 0.4)
        }
    }

    private var restoreActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SecondaryButton(title: restore.phase == .looking ? "Looking…" : "Restore from iCloud", symbol: "icloud.and.arrow.down") {
                    if let container { Task { await restore.start(container: container, state: state) } }
                }.disabled(restore.phase == .looking).atlas("screen.onboarding")
                if restore.phase == .looking { ProgressView().controlSize(.small) }
            }
            if restore.phase != .idle {
                Text(restore.detail).font(Typography.caption).foregroundStyle(restore.phase == .nothingFound ? ColorTokens.warning : StartStyle.textSecondary(true))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The TV symbol on the welcome: it floats gently (2.5 pt over six seconds) and a soft sheen, masked to the symbol's shape, passes
/// over it every seven seconds. Still when motion is off.
private struct FloatingBrandSymbol: View {
    let size: CGFloat
    @Environment(\.startMotion) private var motion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motion)) { context in
            let t = motion ? context.date.timeIntervalSinceReferenceDate : 0
            let cycle = t.truncatingRemainder(dividingBy: 7)
            let sheen = min(1, cycle / 1.6)
            BrandSymbol(size: size)
                .overlay {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: size * 0.32)
                        .rotationEffect(.degrees(20))
                        .offset(x: -size * 0.75 + size * 1.5 * sheen)
                        .opacity(motion && cycle < 1.6 ? 1 : 0)
                        .blendMode(.plusLighter)
                        .mask(BrandSymbol(size: size))
                }
                .offset(y: motion ? 2.5 * sin(t * 2 * .pi / 6) : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
