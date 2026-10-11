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
    /// Cards draw their own placeholder underneath, so the image view stays transparent until the picture arrives.
    var showsPlaceholder = true
    @Environment(\.artwork) private var artwork
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if showsPlaceholder { LinearGradient(colors: [ColorTokens.elevated, ColorTokens.card], startPoint: .topLeading, endPoint: .bottomTrailing) }
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            } else if showsPlaceholder {
                Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(ColorTokens.textTertiary)
                    .opacity(failed || url == nil ? 1 : 0.4)
                if !failed, url.nilIfEmpty != nil { LoadingShimmer() }        // a soft highlight sweeps over it while the picture arrives
            }
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
