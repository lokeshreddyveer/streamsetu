import SwiftUI

/// The big banner at the top of Home, Movies and Series: a few titles that slide by on their own and can be swiped. Which titles it shows is
/// mixed up each time the app is opened (see FeaturedPicker).
struct FeaturedBanner: View {
    let items: [LibraryItem]
    var height: CGFloat = 260
    var scrollY: CGFloat = 0
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tabActive) private var tabActive

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HeroCard(item: item, height: height, scrollY: scrollY).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == index ? 0.95 : 0.4)).frame(width: i == index ? 16 : 6, height: 6)
                    }
                }
                .padding(.trailing, 30).padding(.bottom, 14).allowsHitTesting(false)
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

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                ParallaxBanner(height: height, scrollY: scrollY) {
                    ArtworkImage(url: item.backdropURL ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film")
                }
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).appFont(height > 280 ? 30 : 22, .bold).lineLimit(2)
                    HStack(spacing: 8) {
                        if !item.detailLine.isEmpty { Text(item.detailLine) }
                        if let r = item.ratingValue { Label(String(format: "%.1f", r), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow) }
                    }.appFont(12, .medium).foregroundStyle(.white.opacity(0.8))
                    if let o = item.overview, !o.isEmpty { Text(o).appFont(13).foregroundStyle(.white.opacity(0.78)).lineLimit(2) }
                    Label("Play", systemImage: "play.fill").appFont(13, .semibold).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 7).background(.white, in: Capsule()).padding(.top, 2)
                }.padding(16)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.horizontal, 16)
        }
        .buttonStyle(.press)
    }
}
