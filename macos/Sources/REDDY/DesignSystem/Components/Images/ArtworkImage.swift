import SwiftUI

private struct ArtworkKey: EnvironmentKey { static let defaultValue: ArtworkService? = nil }
private struct ContainerKey: EnvironmentKey { static let defaultValue: AppContainer? = nil }
extension EnvironmentValues {
    var artwork: ArtworkService? { get { self[ArtworkKey.self] } set { self[ArtworkKey.self] = newValue } }
    var container: AppContainer? { get { self[ContainerKey.self] } set { self[ContainerKey.self] = newValue } }
}

/// Lazily loaded, cached artwork. Shows a quiet placeholder until the image arrives (or when there is none).
struct ArtworkImage: View {
    let url: String?
    let kind: ArtworkKind
    var contentMode: ContentMode = .fill
    var symbol = "photo"
    /// Where a picture that is cropped to fill sits in its frame. `.top` keeps heads in view on tall banners.
    var alignment: Alignment = .center
    /// Cards draw their own placeholder underneath, so the image view stays transparent until the picture arrives.
    var showsPlaceholder = true
    /// A title with no usable picture gets a designed tile instead of a bare symbol: the app's gradient in a colour taken from the title, the title itself, and a short detail ("2022 · 4K"). The real picture fades in over it.
    var tile: ArtworkTile.Content? = nil
    @Environment(\.artwork) private var artwork
    @State private var loaded: CGImage?
    @State private var loadedURL: String?
    @State private var failed = false
    /// Whether the last picture arrived after the tile was already showing a placeholder; only then does it fade in.
    @State private var fades = false

    /// A picture already in memory paints in the first frame (no placeholder flash, no fade); otherwise whatever has been loaded for this address.
    private var image: CGImage? {
        if loadedURL == url, let loaded { return loaded }
        return url.nilIfEmpty == nil ? nil : artwork?.cachedImage(url, kind: kind)
    }

    var body: some View {
        let image = image
        ZStack {
            if showsPlaceholder {
                if let tile { ArtworkTile(content: tile) }
                else { LinearGradient(colors: [ColorTokens.elevated, ColorTokens.card], startPoint: .topLeading, endPoint: .bottomTrailing) }
            }
            if let image {
                if alignment == .center { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode).transition(.opacity) }
                else { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment).transition(.opacity) }
            } else if showsPlaceholder, tile == nil {
                Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(ColorTokens.textTertiary)
                    .opacity(failed || url == nil ? 1 : 0.4)
                if !failed, url.nilIfEmpty != nil { LoadingShimmer() }        // a soft highlight sweeps over it while the picture arrives
            } else if showsPlaceholder, !failed, url.nilIfEmpty != nil { LoadingShimmer() }
        }
        .clipped()
        .animation(fades ? .smooth(duration: 0.35) : nil, value: image != nil)
        .task(id: url) {
            failed = false
            guard let artwork, url.nilIfEmpty != nil else { loaded = nil; loadedURL = nil; return }
            if let hit = artwork.cachedImage(url, kind: kind) { fades = false; loaded = hit; loadedURL = url; return }
            loaded = nil; loadedURL = nil; fades = true
            let sp = SmoothSignpost.begin("TileImageLoad")
            let img = await artwork.image(url, kind: kind)
            SmoothSignpost.end(sp, "TileImageLoad")
            if Task.isCancelled { return }
            loaded = img; loadedURL = url; failed = img == nil
        }
    }
}

/// The tile drawn for a title that has no picture (or whose picture failed for good). Pure drawing from the title: nothing is fetched.
struct ArtworkTile: View {
    struct Content: Hashable, Sendable {
        var title: String
        var detail: String?
        /// False on a card that prints the title under the picture: the tile then shows only the detail and a quiet symbol, so the title is never printed twice.
        var showsTitle = true
        /// "2022 · 4K" from a year and a quality label; nil when there is neither.
        static func detail(year: Int?, quality: String?) -> String? {
            let s = [year.map(String.init), quality].compactMap { $0 }.joined(separator: " · ")
            return s.isEmpty ? nil : s
        }
        /// A stable hue (0 to 360) taken from the title, so the same title always gets the same quiet colour.
        var hue: Double {
            var h: UInt64 = 1469598103934665603
            for b in title.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return Double(h % 360)
        }
    }
    let content: Content
    @Environment(\.colorScheme) private var scheme

    private func color(_ lightness: Double, _ saturation: Double) -> Color {
        let v = lightness + saturation * min(lightness, 1 - lightness)
        let s = v == 0 ? 0 : 2 * (1 - lightness / v)
        return Color(hue: content.hue / 360, saturation: s, brightness: v)
    }

    var body: some View {
        GeometryReader { g in
            let small = g.size.width < 72
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: scheme == .light ? [color(0.80, 0.30), color(0.64, 0.30)] : [color(0.29, 0.25), color(0.08, 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if small {
                    Text(String(content.title.first { $0.isLetter || $0.isNumber } ?? "·").uppercased()).font(.system(size: g.size.width * 0.42, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !content.showsTitle {
                    Image(systemName: "film").font(.system(size: g.size.width * 0.28, weight: .ultraLight)).foregroundStyle(.primary.opacity(0.28)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let d = content.detail { Text(d).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(1).padding(10) }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.title).font(.system(.footnote, design: .default).weight(.semibold)).lineLimit(4).minimumScaleFactor(0.75).multilineTextAlignment(.leading)
                            .foregroundStyle(.primary.opacity(0.92))
                        if let d = content.detail { Text(d).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(10)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A soft highlight that sweeps across a placeholder while its picture loads, as in the streaming apps. Still when Reduce Motion is on.
private struct LoadingShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sweep exists only while it can be seen (the app in front and on screen), so a placeholder that waits costs nothing in the background.
    var body: some View {
        if !(reduceMotion || BrandMotion.reduced(false)) && AppActivity.shared.isLive { ShimmerSweep() } else { Color.clear.allowsHitTesting(false).accessibilityHidden(true) }
    }
}

private struct ShimmerSweep: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.6)
                .offset(x: phase * g.size.width * 1.6)
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

/// Square channel logo that falls back to the channel's initials.
struct ChannelLogo: View {
    let url: String?
    let name: String
    var size: CGFloat = 44
    /// The playlist's logo, else one from the public channel database (an overlay), else the initials.
    private var shownURL: String? { url.nilIfEmpty ?? GuideLogoOverlay.logo(forName: name) }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color.white.opacity(0.05))
            ArtworkImage(url: shownURL, kind: .logo, contentMode: .fit, symbol: "tv")
                .padding(size * 0.1)
                .overlay { if shownURL.nilIfEmpty == nil { Text(initials).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary) } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
