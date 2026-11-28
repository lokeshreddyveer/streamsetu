import SwiftUI

/// Hover and press for a plain control: a soft wash under the pointer, a deeper one while it is held with a small settle (the control gives under the finger and springs
/// back), and a light haptic tap on a Force Touch trackpad. Reduce Motion keeps the wash and drops the settle and the tap.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    var radius: CGFloat = LayoutTokens.radiusSmall
    private var reduce: Bool { BrandMotion.reduced(systemReduce) }

    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(pressed ? 0.12 : (hovering ? 0.06 : 0)), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            #if os(macOS)
            .scaleEffect(pressed && !reduce ? 0.985 : 1)
            .animation(pressed ? AnimationTokens.quick : .spring(response: 0.3, dampingFraction: 0.62), value: pressed)
            #endif
            .animation(AnimationTokens.quick, value: hovering)
            .onHover { hovering = $0 }
            #if os(macOS)
            // The pressed state of whatever is under the pointer (SwiftUI's own press tracking, the one buttons use), so the control's click is untouched.
            ._onButtonGesture(pressing: { down in
                guard down != pressed else { return }
                pressed = down
                if down { PremiumFeedback.tick() }
            }, perform: {})
            #endif
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = LayoutTokens.radiusSmall) -> some View { modifier(HoverHighlight(radius: radius)) }
}
