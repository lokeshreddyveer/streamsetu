import SwiftUI

/// Smoked-black glass for app chrome (header, sidebar, menus, dialogs, player controls).
/// Falls back to a solid surface when Reduce Transparency is on.
struct GlassBackground: View {
    var radius: CGFloat = 0
    var edge = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if reduceTransparency { shape.fill(ColorTokens.elevated) }
            else if ColorTokens.nativeGlass {
                NativeGlass(shape: shape, tint: ColorTokens.glassFill.opacity(0.2))
            }
            else {
                shape.fill(.ultraThinMaterial)
                shape.fill(ColorTokens.glassFill.opacity(0.72))
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.02 + ColorTokens.sheen * 0.8), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
            }
        }
        .overlay { if edge { shape.strokeBorder(ColorTokens.glassEdge.opacity(0.7), lineWidth: 0.75) } }
    }
}

extension View {
    func glass(radius: CGFloat = 0, edge: Bool = true) -> some View { background(GlassBackground(radius: radius, edge: edge)) }
}

/// Quiet content surface: a solid fill with a hairline.
struct SurfaceStyle: ViewModifier {
    var radius: CGFloat = LayoutTokens.radiusPanel
    var fill: Color = ColorTokens.surface
    func body(content: Content) -> some View {
        content
            .background { SurfaceBackground(radius: radius, fill: fill) }
            .overlay { if ColorTokens.highlight > 0 { GlossSheen(cornerRadius: radius, streak: false).opacity(0.7) } }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ColorTokens.line))
    }
}

extension View {
    func surface(radius: CGFloat = LayoutTokens.radiusPanel, fill: Color = ColorTokens.surface) -> some View { modifier(SurfaceStyle(radius: radius, fill: fill)) }
}
