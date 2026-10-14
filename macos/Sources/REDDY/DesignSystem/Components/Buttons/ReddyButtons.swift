import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.reddyAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.bodyMedium)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Spacing.xl).padding(.vertical, 10)
            .background(accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
            .overlay(Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
            .foregroundStyle(.white)
            .shadow(color: accent.opacity(enabled ? 0.28 : 0), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(AnimationTokens.press, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.bodyMedium)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Spacing.lg).padding(.vertical, 9)
            .background(ColorTokens.elevated.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(ColorTokens.borderStrong))
            .foregroundStyle(ColorTokens.textPrimary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(AnimationTokens.press, value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let symbol { Image(systemName: symbol) }; Text(title.loc) }
        }.buttonStyle(PrimaryButtonStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let symbol { Image(systemName: symbol) }; Text(title.loc) }
        }.buttonStyle(SecondaryButtonStyle())
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var active = false
    var size: CGFloat = 32
    let action: () -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(active ? accent : ColorTokens.textPrimary)
                .frame(width: size, height: size)
                .background(hovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
    }
}

struct WatchLaterButton: View {
    let isSaved: Bool
    let toggle: () -> Void
    var body: some View {
        IconButton(symbol: isSaved ? "bookmark.fill" : "bookmark", help: isSaved ? "Remove from Watch Later" : "Add to Watch Later", active: isSaved, action: toggle)
    }
}

struct FavoriteButton: View {
    let isFavorite: Bool
    let toggle: () -> Void
    var body: some View {
        IconButton(symbol: isFavorite ? "heart.fill" : "heart", help: isFavorite ? "Remove from Favorites" : "Add to Favorites", active: isFavorite, action: toggle)
    }
}
