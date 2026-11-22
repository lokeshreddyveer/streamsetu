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
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
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
        .animation(.smooth(duration: 0.35), value: image != nil)
        .task(id: url) {
            failed = false
            image = nil
            guard let artwork, url.nilIfEmpty != nil else { return }
            let img = await artwork.image(url, kind: kind)
            if Task.isCancelled { return }
            image = img; failed = img == nil
        }
    }
}

/// The tile drawn for a title that has no picture (or whose picture failed for good). Pure drawing from the title: nothing is fetched.
struct ArtworkTile: View {
    struct Content: Hashable, Sendable {
        var title: String
        var detail: String?
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
                Circle().strokeBorder(Color.white.opacity(scheme == .light ? 0.35 : 0.10), lineWidth: 1)
                    .frame(width: g.size.width * 0.86, height: g.size.width * 0.86)
                    .position(x: g.size.width * 0.58, y: g.size.height * 0.30)
                if small {
                    Text(String(content.title.first { $0.isLetter || $0.isNumber } ?? "·").uppercased()).font(.system(size: g.size.width * 0.42, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.6)
                .offset(x: phase * g.size.width * 1.6)
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Square channel logo that falls back to the channel's initials.
struct ChannelLogo: View {
    let url: String?
    let name: String
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color.white.opacity(0.05))
            ArtworkImage(url: url, kind: .logo, contentMode: .fit, symbol: "tv")
                .padding(size * 0.1)
                .overlay { if url.nilIfEmpty == nil { Text(initials).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary) } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
