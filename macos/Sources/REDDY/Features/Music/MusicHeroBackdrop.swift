import SwiftUI
import CoreGraphics

/// The colour field behind a hero (Listen Now, Explore): the cover's own colours, blurred and made richer (the same wash the player uses), laid over the
/// surface and held to a brightness at which white text stays readable. Two rules decide how it looks:
/// - the darkening is sized to THIS cover (its real brightest point), not to a cover as bright as white, so a deep red stays red and a pale one is held down;
/// - a scrim covers only the side the text sits on, not the whole picture (Material's rule: protect the text area, do not blanket the image).
/// With Reduce Transparency, or before the cover has loaded, it is the plain surface. It never animates by itself: the colour fades in once.
struct MusicHeroBackdrop: View {
    let thumbs: [MusicThumbnail]
    /// The side the text sits on.
    var textEdge: HorizontalEdge = .leading

    @State private var image: CGImage?
    @State private var shown = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The brightest the field may be (the app's brightness scale, 0 to 1). White text on it then keeps a contrast of about 4.5 to 1 (WCAG AA for body text).
    static let maxBrightness = 0.45

    /// How much of the cover's wash to show: all of it when the cover is dark enough, less as its brightest point goes over the limit. Never above 1.
    static func opacity(brightest: Double) -> Double { brightest > 0 ? min(1, maxBrightness / brightest) : 1 }

    /// The wash as a picture (an `side` by `side` RGBA image), or nil when the bytes are not that size.
    static func cgImage(rgba: [UInt8], side: Int) -> CGImage? {
        guard side > 0, rgba.count == side * side * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @State private var strength = 1.0
    private var address: String? { MusicArtworkService.pickThumbnail(thumbs, neededPixels: 256) }

    var body: some View {
        // The surface sets the size; the picture is drawn over it and cannot make the backdrop bigger. A picture that fills a square is far taller than a hero, and a view that
        // size sits over whatever is above the hero and swallows its clicks (the clip hides the overflow but does not stop it taking hits).
        ColorTokens.elevated
            .overlay {
                if let image, !reduceTransparency {
                    ZStack {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
                            .opacity(shown ? strength : 0)
                        LinearGradient(colors: [MusicInk.scrim(.medium), .clear], startPoint: textEdge == .leading ? .leading : .trailing, endPoint: .center)
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: address) {
            shown = false
            guard let address, !reduceTransparency, let baked = await MusicAdaptiveColorCache.shared.wash(for: address),
                  let img = Self.cgImage(rgba: baked.rgba, side: MusicCoverWash.side) else { image = nil; return }
            strength = Self.opacity(brightest: baked.brightest)
            image = img
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { shown = true }
        }
    }
}
