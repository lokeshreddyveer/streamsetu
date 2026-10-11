import SwiftUI

/// The window's backdrop. Flat for ordinary themes; for glassy ones a lit gradient with two soft glows, which the frosted panels
/// above it pick colour from.
struct ThemeBackdrop: View {
    var body: some View {
        let p = ThemeStore.palette
        if p.glassy, p.backdrop.count >= 3 {
            ZStack {
                LinearGradient(colors: p.backdrop.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                if p.glows.count >= 2 {
                    RadialGradient(colors: [Color(hex: p.glows[0]).opacity(0.38), .clear], center: UnitPoint(x: 0.15, y: 0.08), startRadius: 0, endRadius: 620)
                    RadialGradient(colors: [Color(hex: p.glows[1]).opacity(0.30), .clear], center: UnitPoint(x: 0.92, y: 0.95), startRadius: 0, endRadius: 700)
                }
                // a faint diagonal reflection across the whole window
                LinearGradient(stops: [.init(color: .clear, location: 0.0), .init(color: Color.white.opacity(0.045), location: 0.28), .init(color: .clear, location: 0.5), .init(color: .clear, location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            Color(hex: p.background)
        }
    }
}

/// Fill for a panel or card: opaque, or frosted glass tinted with the same colour on glassy themes.
struct SurfaceBackground: View {
    var radius: CGFloat
    var fill: Color
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if ColorTokens.nativeGlass {
            NativeGlass(shape: shape, tint: fill.opacity(0.22))
        } else if ColorTokens.glassy {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(fill.opacity(0.42)))
        } else {
            shape.fill(fill)
        }
    }
}


/// Apple's Liquid Glass on macOS 26 and later; a frosted material on earlier systems.
struct NativeGlass<S: Shape>: View {
    let shape: S
    var tint: Color = .clear
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(tint == .clear ? .regular : .regular.tint(tint), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
        }
    }
}
