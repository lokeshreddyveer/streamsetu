import SwiftUI

struct CardStyle: ViewModifier {
    var radius: CGFloat = LayoutTokens.radiusPanel
    var fill: Color = ColorTokens.surface
    func body(content: Content) -> some View {
        content
            .background { SurfaceBackground(radius: radius, fill: fill) }
            .overlay { if ColorTokens.highlight > 0 { GlossSheen(cornerRadius: radius, streak: false).opacity(0.7) } }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ColorTokens.border))
    }
}

extension View {
    func cardStyle(radius: CGFloat = LayoutTokens.radiusPanel, fill: Color = ColorTokens.surface) -> some View { modifier(CardStyle(radius: radius, fill: fill)) }
}
