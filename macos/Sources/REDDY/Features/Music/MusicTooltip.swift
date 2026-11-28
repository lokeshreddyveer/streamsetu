import SwiftUI

// One tooltip rule for Music. `musicTooltip` is the system help tag on the Mac and nothing on iPhone and iPad (where a long press already
// opens the control's own menu). `musicTooltipCard` is a small custom card for the few places the system tag does not show (a control inside
// an overlay or a disabled control); it appears after a short pause and fades with the tooltip motion.

enum MusicTooltipText {
    /// "Play" or "Play (Space)".
    static func compose(_ label: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else { return label }
        return label + " (" + shortcut + ")"
    }
}

enum MusicTooltipMetrics {
    /// Pause before the custom card appears.
    static let showDelayMilliseconds = 500
    static let gap: CGFloat = 6
    static let padding: CGFloat = 8
    static let corner: CGFloat = 6
}

extension View {
    /// A tooltip from a localized key (a string literal), with an optional shortcut shown in brackets.
    @ViewBuilder func musicTooltip(_ key: LocalizedStringKey, shortcut: String? = nil) -> some View {
        #if os(macOS)
        if let shortcut, !shortcut.isEmpty { help(Text(key) + Text(verbatim: " (" + shortcut + ")")) } else { help(key) }
        #else
        self
        #endif
    }

    /// A tooltip from text that is already localized or user data.
    @ViewBuilder func musicTooltip(verbatim text: String, shortcut: String? = nil) -> some View {
        #if os(macOS)
        help(Text(verbatim: MusicTooltipText.compose(text, shortcut: shortcut)))
        #else
        self
        #endif
    }

    /// The custom card variant, placed above the control. Mac only; elsewhere the view is unchanged.
    @ViewBuilder func musicTooltipCard(_ text: String, shortcut: String? = nil) -> some View {
        #if os(macOS)
        modifier(MusicTooltipCardModifier(text: MusicTooltipText.compose(text, shortcut: shortcut)))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MusicTooltipCardModifier: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(MusicTooltipMetrics.showDelayMilliseconds))
                        if !Task.isCancelled { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .overlay(alignment: .top) {
                if shown {
                    Text(verbatim: text)
                        .font(Typography.caption).foregroundStyle(ColorTokens.textPrimary)
                        .padding(MusicTooltipMetrics.padding)
                        .fixedSize()
                        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicTooltipMetrics.corner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: MusicTooltipMetrics.corner, style: .continuous).strokeBorder(ColorTokens.lineStrong, lineWidth: 0.75))
                        .alignmentGuide(.top) { $0[.bottom] + MusicTooltipMetrics.gap }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(MusicMotion.animation(.tooltip, reduce: reduceMotion), value: shown)
            .onDisappear { pending?.cancel(); shown = false }
    }
}
#endif
