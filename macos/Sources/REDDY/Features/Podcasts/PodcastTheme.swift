import SwiftUI

// Themed building blocks for the Podcasts screens. Everything here is drawn from the theme tokens (ColorTokens, Typography, the accent) and the same
// materials as the library's bars and sidebar, so every theme, glass or solid, looks the same as Movies, Series and Settings.

/// The bottom bar's backdrop: the same material, tint and sheen as the library player bar.
struct PodcastBarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency { Rectangle().fill(ColorTokens.elevated) }
            else if ColorTokens.nativeGlass { NativeGlass(shape: Rectangle(), tint: ColorTokens.barFill.opacity(0.2)) }
            else { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(ColorTokens.barFill.opacity(ColorTokens.glassy ? 0.58 : 0.90)) }
            GlossSheen(streak: false)
        }
        .overlay(alignment: .top) { Rectangle().fill(ColorTokens.glassEdge).frame(height: 1) }
    }
}

/// The sidebar's backdrop, as in the library sidebar.
struct PodcastSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency { Rectangle().fill(ColorTokens.panel) }
            else if ColorTokens.nativeGlass { NativeGlass(shape: Rectangle(), tint: ColorTokens.panel.opacity(0.25)) }
            else if ColorTokens.glassy { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(ColorTokens.panel.opacity(0.5)) }
            else { Rectangle().fill(ColorTokens.panel) }
            GlossSheen()
        }
    }
}

/// A thin draggable bar (the scrubber and the volume): accent fill over a track from the text colour.
struct PodcastScrubber: View {
    var fraction: Double
    var onChange: (Double) -> Void
    var thickness: CGFloat = 4
    @State private var dragging: Double?
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        GeometryReader { g in
            let f = min(1, max(0, dragging ?? fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(ColorTokens.textPrimary.opacity(0.18)).frame(height: hovering || dragging != nil ? thickness + 2 : thickness)
                Capsule().fill(accent).frame(width: g.size.width * f, height: hovering || dragging != nil ? thickness + 2 : thickness)
                Circle().fill(ColorTokens.textPrimary).frame(width: 11, height: 11).offset(x: max(0, g.size.width * f - 5.5)).opacity(hovering || dragging != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = min(1, max(0, v.location.x / max(1, g.size.width))) }
                .onEnded { v in let r = min(1, max(0, v.location.x / max(1, g.size.width))); dragging = nil; onChange(r) })
            .onHover { hovering = $0 }
            .animation(AnimationTokens.hover, value: hovering)
        }
        .accessibilityElement().accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { d in onChange(min(1, max(0, fraction + (d == .increment ? 0.05 : -0.05)))) }
    }
}

/// A row of choices as themed chips (the system segmented control ignores the theme).
struct PodcastSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> LocalizedStringKey
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(title(o)).font(Typography.bodyMedium).padding(.horizontal, 14).padding(.vertical, 6)
                        .foregroundStyle(on ? accent : ColorTokens.textSecondary)
                        .background(on ? accent.opacity(0.14) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                .atlas("control.podcasts.nowPlaying")
            }
        }
        .padding(3).background(ColorTokens.elevated, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.line))
    }
}

extension View {
    /// The capsule field of the top bar's search box: a hairline, the accent ring while focused.
    func podcastFieldStyle(focused: Bool, accent: Color) -> some View {
        self.background(ColorTokens.elevated.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(accent.opacity(0.7)) : AnyShapeStyle(ColorTokens.lineStrong), lineWidth: focused ? 1.5 : 0.75))
    }
}
