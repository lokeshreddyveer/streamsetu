import SwiftUI

/// Subtle lift + highlight on pointer hover.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 1.03
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: 14, y: 8)
            .animation(reduceMotion ? nil : AnimationTokens.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = LayoutTokens.radiusSmall
    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(AnimationTokens.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.03) -> some View { modifier(HoverLift(scale: scale)) }
    func hoverHighlight(radius: CGFloat = LayoutTokens.radiusSmall) -> some View { modifier(HoverHighlight(radius: radius)) }
}
