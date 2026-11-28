import SwiftUI

/// Back and forward depth inside Music, as the shell's `MusicNavHistory` reports it (`history.depth`). Entering Music starts both at 0; a step moves by its sign; any other navigation adds 1 to the depth and
/// forgets what was ahead.
struct MusicNavDepth: Equatable, Sendable {
    private(set) var depth = 0
    private(set) var deepest = 0

    init(depth: Int = 0, deepest: Int = 0) {
        let top = max(0, deepest)
        self.deepest = top
        self.depth = min(max(0, depth), top)
    }

    var canGoBack: Bool { depth > 0 }
    var canGoForward: Bool { depth < deepest }

    mutating func reset() { depth = 0; deepest = 0 }
    mutating func navigated() { depth += 1; deepest = depth }
    mutating func step(_ delta: Int) { depth = min(max(0, depth + delta), deepest) }
}

/// The slim header above every Music page. Two glass capsules and a search pill on a translucent bar: back, forward and refresh in one capsule on the left; a wide
/// "Search Music" pill, then open-link and details-panel buttons in a capsule on the right. Fine symbols, a soft pill under the pointer, a hairline under the bar.
struct MusicHeaderBar: View {
    let hub: MusicHub
    let canBack: Bool
    let canForward: Bool
    let back: () -> Void
    let forward: () -> Void
    let refresh: () -> Void
    /// The context panel's open state and its toggle (the shell shows the button once a song is playing).
    var panelOpen = false
    var showsPanelToggle = false
    var togglePanel: () -> Void = {}
    @Environment(\.reddyDensity) private var density

    var body: some View {
        HStack(spacing: Spacing.sm) {
            capsule {
                bar("chevron.left", "Back", "Back", disabled: !canBack, action: back)
                bar("chevron.right", "Forward", "Forward", disabled: !canForward, action: forward)
                Rectangle().fill(ColorTokens.line.opacity(0.8)).frame(width: 0.5, height: 14).padding(.horizontal, 2)
                bar("arrow.clockwise", "Refresh", "Refresh this page", disabled: false, action: refresh).keyboardShortcut("r", modifiers: .command).atlas("control.music.musicMusicheaderbarbarButton")
            }
            Spacer(minLength: Spacing.md)
            searchPill
            capsule {
                bar("link", "Open Link", "Open a link", disabled: false) { MusicChromeState.shared.showOpenLink = true }.atlas("control.music.openLink")
                if showsPanelToggle {
                    bar(panelOpen ? "sidebar.right" : "sidebar.right", panelOpen ? "Hide details panel" : "Show details panel", panelOpen ? "Hide the details panel" : "Show the details panel", disabled: false, selected: panelOpen, action: togglePanel)
                        .accessibilityAddTraits(panelOpen ? .isSelected : []).atlas("control.music.contextToggle")
                }
            }
        }
        .padding(.horizontal, Spacing.md).frame(height: MusicTokens.headerHeight - (density == .comfortable ? 0 : 6))
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(ColorTokens.line.opacity(0.55)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    /// A rounded glass container for a group of header buttons.
    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(3)
            .background(Capsule().fill(ColorTokens.elevated.opacity(0.55)))
            .overlay(Capsule().strokeBorder(ColorTokens.line.opacity(0.7), lineWidth: 0.5))
    }

    /// The search entry: a pill that looks like a field and opens the palette.
    private var searchPill: some View {
        Button { MusicChromeState.shared.showPalette = true } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary)
                Text("Search Music").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm).frame(width: 210, height: 30)
            .background(Capsule().fill(ColorTokens.elevated.opacity(0.55)))
            .overlay(Capsule().strokeBorder(ColorTokens.line.opacity(0.7), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).hoverHighlight(radius: 15)
        .accessibilityLabel("Search Music").musicTooltip("Search Music").atlas("control.music.palette")
    }

    private func bar(_ symbol: String, _ label: String, _ help: String, glyph: MusicNavGlyph? = nil, disabled: Bool, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let glyph { MusicNavIcon(glyph: glyph, tint: disabled ? .tertiary : .primary) } else { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(selected ? ColorTokens.accent.opacity(0.22) : Color.clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: 15)
        .foregroundStyle(disabled ? ColorTokens.textTertiary : (selected ? ColorTokens.accent : ColorTokens.textPrimary))
        .disabled(disabled).accessibilityLabel(LocalizedStringKey(label)).musicTooltip(LocalizedStringKey(help)).atlas("control.music.musicMusicheaderbarbarButton")
    }
}
