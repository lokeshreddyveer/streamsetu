import SwiftUI

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
    func hoverHighlight(radius: CGFloat = LayoutTokens.radiusSmall) -> some View { modifier(HoverHighlight(radius: radius)) }
}
