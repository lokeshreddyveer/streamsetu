import SwiftUI

/// Applies the dark theme, accent colour, base font and hidden scroll indicators to everything below it.
struct ReddyThemeModifier: ViewModifier {
    let settings: AppSettings
    func body(content: Content) -> some View {
        content
            .environment(\.reddyAccent, settings.accent.color)
            .environment(\.reddyDensity, settings.density)
            .transaction { t in if settings.reduceMotion { t.disablesAnimations = true; t.animation = nil } }
            .tint(settings.accent.color)
            .preferredColorScheme(.dark)
            .font(Typography.body)
            .foregroundStyle(ColorTokens.textPrimary)
            .scrollIndicators(.hidden)          // scrolling stays available by wheel, trackpad and keyboard
    }
}

extension View {
    func reddyTheme(_ settings: AppSettings) -> some View { modifier(ReddyThemeModifier(settings: settings)) }
}
