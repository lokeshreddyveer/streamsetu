import SwiftUI
import Observation

/// Banner size rules. The slideshow shrinks with the window so the catalog below it always keeps a usable area.
enum FeaturedLayout {
    static let maxHeight: CGFloat = 340
    static let minHeight: CGFloat = 180
    /// Height reserved for the page title and the search/sort toolbar that sit around the banner.
    static let chrome: CGFloat = 120
    /// The least room the poster area keeps no matter how short the window is.
    static let minCatalogHeight: CGFloat = 220

    /// About 40% of the content height, between 180 and 340 pt, and never so tall that fewer than `minCatalogHeight` points
    /// are left for the posters.
    static func bannerHeight(contentHeight: CGFloat) -> CGFloat {
        let wanted = min(maxHeight, max(minHeight, contentHeight * 0.40))
        let allowed = contentHeight - chrome - minCatalogHeight
        return max(0, min(wanted, max(minHeight * 0.75, allowed)))
    }
}

/// The slideshow's behaviour without any view: which slide is showing, and when it may advance by itself.
@MainActor @Observable
final class SlideshowController {
    static let interval: Duration = .seconds(7)
    static let crossfade: Double = 0.5

    private(set) var count = 0
    private(set) var index = 0
    /// The slide being faded out, while a crossfade is running.
    private(set) var previousIndex: Int?
    var userPaused = false
    /// The pointer is over the slideshow or keyboard focus is inside it.
    var interacting = false
    var windowActive = true
    var reduceMotion = false

    /// Whether the countdown to the next slide should be running right now.
    var shouldAutoplay: Bool { count > 1 && !userPaused && !interacting && windowActive && !reduceMotion }

    /// Called when the slide list is (re)built. The current position survives a refresh that keeps the same slides;
    /// it is only clamped if the list got shorter.
    func configure(count newCount: Int) {
        count = newCount
        index = newCount == 0 ? 0 : min(index, newCount - 1)
        previousIndex = nil
    }

    func next() { go(to: count == 0 ? 0 : (index + 1) % count) }
    func previous() { go(to: count == 0 ? 0 : (index - 1 + count) % count) }

    func go(to i: Int) {
        guard count > 0, i != index, (0..<count).contains(i) else { return }
        previousIndex = index
        index = i
    }

    func finishedCrossfade() { previousIndex = nil }
    func togglePause() { userPaused.toggle() }
}

/// An Apple TV-style featured banner: backdrop art, title and facts, Play and More Info, previous / next, position dots
/// and pause. It only displays the slides it is given; choosing the slides, daily rotation and detail lookups happen
/// elsewhere (`FeaturedService`), so changing slides never causes a network request.
struct FeaturedSlideshow: View {
    let slides: [FeaturedSlide]
    let kicker: String
    let height: CGFloat
    let onPlay: (FeaturedSlide) -> Void
    let onInfo: (FeaturedSlide) -> Void

    @State private var controller = SlideshowController()
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppSettings.self) private var settings
    @Environment(\.artwork) private var artwork
    @Environment(\.reddyAccent) private var accent
    @FocusState private var focused: Bool

    private var reduceMotion: Bool { systemReduceMotion || settings.reduceMotion }
    private struct AutoplayKey: Equatable { var index: Int; var running: Bool; var count: Int }

    var body: some View {
        let i = min(controller.index, max(0, slides.count - 1))
        ZStack(alignment: .bottomLeading) {
            Color(hex: 0x0C121A)
            if slides.indices.contains(i) {
                backdrop(slides[i]).id(slides[i].id).transition(.opacity)
                scrim
                caption(slides[i]).id("caption-\(slides[i].id)").transition(.opacity)
                controls(slides[i])
            }
        }
        .frame(height: height).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .animation(reduceMotion ? nil : .easeInOut(duration: SlideshowController.crossfade), value: controller.index)
        .onHover { controller.interacting = $0 }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { controller.previous(); return .handled }
        .onKeyPress(.rightArrow) { controller.next(); return .handled }
        .onKeyPress(.space) { controller.togglePause(); return .handled }
        .onChange(of: focused) { _, f in controller.interacting = f }
        .onChange(of: activeState) { _, s in controller.windowActive = s != .inactive }
        .onChange(of: reduceMotion) { _, r in controller.reduceMotion = r }
        .task(id: slides.map(\.id)) {
            controller.reduceMotion = reduceMotion; controller.windowActive = activeState != .inactive
            controller.configure(count: slides.count)
        }
        // The countdown is a task keyed on everything that should restart or stop it. When the slideshow disappears, or
        // pauses, the task is cancelled: nothing keeps ticking in the background.
        .task(id: AutoplayKey(index: controller.index, running: controller.shouldAutoplay, count: slides.count)) {
            guard controller.shouldAutoplay else { return }
            try? await Task.sleep(for: SlideshowController.interval)
            if !Task.isCancelled { controller.next() }
        }
        // Only the neighbouring slides are fetched ahead of time; the image cache de-duplicates and bounds them.
        .task(id: controller.index) {
            guard let artwork, slides.count > 1 else { return }
            for offset in [1, -1] {
                let n = (controller.index + offset + slides.count) % slides.count
                if slides.indices.contains(n) { _ = await artwork.image(slides[n].backdropURL, kind: .backdrop) }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Featured titles")
    }

    // MARK: layers

    private func backdrop(_ s: FeaturedSlide) -> some View {
        GeometryReader { g in
            ArtworkImage(url: s.backdropURL, kind: .backdrop, contentMode: .fill, symbol: "film", showsPlaceholder: false)
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .accessibilityHidden(true)
    }

    private var scrim: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0C121A, opacity: 0.92), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.75, y: 0.5))
            LinearGradient(colors: [Color(hex: 0x0C121A, opacity: 0.95), .clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.1))
        }.allowsHitTesting(false)
    }

    private func caption(_ s: FeaturedSlide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker).font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(Color(hex: 0xC4D0D2)).lineLimit(1)
            Text(s.title).font(.system(size: height < 260 ? 26 : 34, weight: .semibold)).tracking(-0.4).lineLimit(2).minimumScaleFactor(0.7)
                .padding(.top, 6).frame(maxWidth: 560, alignment: .leading)
            Text(facts(s)).font(.system(size: 12)).foregroundStyle(Color(hex: 0xC7CEDA)).lineLimit(1).padding(.top, 6)
            if height >= 230 {
                Text(s.synopsis).font(.system(size: 12)).foregroundStyle(Color(hex: 0xB6BCC7)).lineLimit(2).lineSpacing(2)
                    .frame(maxWidth: 440, alignment: .leading).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Year · genre · duration · rating, only the parts that exist.
    private func facts(_ s: FeaturedSlide) -> String {
        [s.year.flatMap { y in s.title.contains(String(y)) ? nil : String(y) }, s.genre, s.durationMinutes.map { $0 >= 60 ? "\($0 / 60)h \($0 % 60)m" : "\($0)m" }, s.rating.map { "★ \($0)" }]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func controls(_ s: FeaturedSlide) -> some View {
        HStack(spacing: 8) {
            Button { onPlay(s) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(SlidePrimaryStyle())
            Button { onInfo(s) } label: { Label("More info", systemImage: "info.circle") }.buttonStyle(SlideSecondaryStyle())
            Spacer(minLength: 12)
            if slides.count > 1 {
                HStack(spacing: 6) {
                    roundButton("chevron.left", "Previous slide") { controller.previous() }
                    HStack(spacing: 5) {
                        ForEach(Array(slides.enumerated()), id: \.element.id) { n, slide in
                            Button { controller.go(to: n) } label: {
                                Capsule().fill(n == controller.index ? accent : Color.white.opacity(0.4)).frame(width: n == controller.index ? 18 : 6, height: 6)
                                    .frame(height: 16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Slide \(n + 1): \(slide.title)").accessibilityAddTraits(n == controller.index ? .isSelected : [])
                        }
                    }
                    roundButton("chevron.right", "Next slide") { controller.next() }
                    roundButton(controller.userPaused ? "play.fill" : "pause.fill", controller.userPaused ? "Resume slideshow" : "Pause slideshow") { controller.togglePause() }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.black.opacity(0.35), in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9)).help(label).accessibilityLabel(label)
    }
}

private struct SlidePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x14171F)).padding(.horizontal, 14).frame(height: 32)
            .background(LinearGradient(colors: [.white, Color(hex: 0xD4D9E2)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct SlideSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 14).frame(height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }
}
