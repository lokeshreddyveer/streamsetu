import SwiftUI

/// The big banner at the top of Home, Movies and Series: a few titles that slide by on their own and can be swiped. Which titles it shows is
/// mixed up each time the app is opened (see FeaturedPicker).
struct FeaturedBanner: View {
    let items: [LibraryItem]
    var height: CGFloat = 260
    var scrollY: CGFloat = 0
    /// Edge to edge and up under the status bar (Home), instead of an inset rounded card (Movies, Series).
    var immersive = false
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tabActive) private var tabActive

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HeroCard(item: item, height: height, scrollY: scrollY, immersive: immersive).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == index ? 0.95 : 0.35)).frame(width: i == index ? 22 : 6, height: 5)
                    }
                }
                .padding(.trailing, immersive ? 22 : 30).padding(.bottom, immersive ? 16 : 14).allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: index)
                .accessibilityHidden(true)
            }
        }
        // Moves on every six seconds; a swipe starts the count again. Off when Reduce Motion is on.
        .task(id: "\(index)-\(scenePhase == .active)-\(tabActive)") {          // stops while the app is not in front, and while this tab is not the one on show
            guard items.count > 1, !reduceMotion, scenePhase == .active, tabActive else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % items.count } }
        }
        .onChange(of: items.map(\.id)) { _, _ in index = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured titles, \(index + 1) of \(items.count)")
    }
}

struct HeroCard: View {
    let item: LibraryItem
    var height: CGFloat = 260
    var scrollY: CGFloat = 0
    var immersive = false

    var body: some View {
        NavigationLink(value: item) { immersive ? AnyView(immersiveBody) : AnyView(cardBody) }
            .buttonStyle(.press)
    }

    /// Full width, melting into the page below: the artwork fades to the page colour, so there is no edge where the banner stops.
    private var immersiveBody: some View {
        ZStack(alignment: .bottomLeading) {
            ParallaxBanner(height: height, scrollY: scrollY) {
                ArtworkImage(url: item.backdropURL ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film", alignment: .top)
            }
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2))
            LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: ColorTokens.background.opacity(0.6), location: 0.74),
                                   .init(color: ColorTokens.background.opacity(0.94), location: 0.92), .init(color: ColorTokens.background, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.cleanTitle).appFont(30, .heavy).lineLimit(2).minimumScaleFactor(0.7).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                HStack(spacing: 8) {
                    if let r = item.ratingValue {
                        Label(String(format: "%.1f", r), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow)
                            .appFont(12, .bold).padding(.horizontal, 8).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule())
                    }
                    let meta = [item.year.map(String.init), item.genre].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).appFont(13, .medium).foregroundStyle(.white.opacity(0.8)).lineLimit(1) }
                }
                if let o = item.overview, !o.isEmpty {
                    Text(o).appFont(13).foregroundStyle(.white.opacity(0.7)).lineLimit(2).frame(maxWidth: 520, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Label("Play", systemImage: "play.fill").appFont(15, .bold).foregroundStyle(.white)
                        .padding(.horizontal, 24).frame(height: 44).background(GlossyBackground(shape: Capsule(), accent: true))
                    Image(systemName: "info").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.16)))
                        .accessibilityLabel("Details")
                }.padding(.top, 4)
                Color.clear.frame(height: 6)          // room for the page dots
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .frame(height: height)
        .clipped()
    }

    private var eyebrow: String { (item.isSeries ? "SERIES" : "FILM") + (item.year.map { " · \($0)" } ?? "") }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            ParallaxBanner(height: height, scrollY: scrollY) {
                ArtworkImage(url: item.backdropURL ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film", alignment: .top)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.5), location: 0.65), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).appFont(height > 280 ? 30 : 24, .heavy).lineLimit(2).shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                HStack(spacing: 8) {
                    if let r = item.ratingValue {
                        Label(String(format: "%.1f", r), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow)
                            .appFont(12, .bold).padding(.horizontal, 8).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule())
                    }
                    if !item.detailLine.isEmpty { Text(item.detailLine).lineLimit(1) }
                }.appFont(12, .medium).foregroundStyle(.white.opacity(0.82))
                if let o = item.overview, !o.isEmpty { Text(o).appFont(13).foregroundStyle(.white.opacity(0.72)).lineLimit(2) }
                HStack(spacing: 8) {
                    Label("Play", systemImage: "play.fill").appFont(14, .bold).foregroundStyle(.black)
                        .padding(.horizontal, 20).frame(height: 38).background(.white, in: Capsule())
                    Label("Details", systemImage: "info.circle").appFont(13, .semibold).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 38).background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                }.padding(.top, 2)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 34)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .padding(.horizontal, 16)
    }
}

extension UIScreen {
    /// The status-bar / Dynamic Island height, for pages whose artwork runs up under it.
    static var safeTop: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 0
    }
}

/// How tall a full-width banner is: a share of the screen (on an iPhone 18 Pro Max, 956 pt high, 0.54 is about 516 pt including the status bar), so the first
/// shelf or the filter chips always peek in under it.
enum HeroMetrics {
    static func height(wide: Bool, share: CGFloat = 0.54) -> CGFloat { min(max(UIScreen.main.bounds.height * (wide ? share * 0.78 : share), 360), 620) }
}
