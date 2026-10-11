import SwiftUI

/// Visible keyboard-focus ring in the accent colour (accessibility).
struct FocusRing: ViewModifier {
    var radius: CGFloat = LayoutTokens.radius
    @Environment(\.reddyAccent) private var accent
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent, lineWidth: focused ? 2 : 0))
    }
}

extension View {
    func focusRing(radius: CGFloat = LayoutTokens.radius) -> some View { modifier(FocusRing(radius: radius)) }
}
