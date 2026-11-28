import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The drag handle on the side panel's left edge. Dragging it left makes the panel wider and right narrower (280 to 500 points, the page keeps its room); a double click
/// goes back to the automatic width; the width is remembered next to the panel's tab choice. VoiceOver can adjust it in steps. Nothing here touches playback or the artwork:
/// only the panel's frame changes.
struct MusicPanelResizeHandle: View {
    /// The width the person chose, or nil for the automatic one.
    @Binding var width: CGFloat?
    /// The width on screen now, and the width of the area the panel sits in.
    let shown: CGFloat
    let total: CGFloat
    @State private var startWidth: CGFloat?
    @State private var hovering = false
    @State private var cursorPushed = false
    @Environment(\.reddyAccent) private var accent

    private static let step: CGFloat = 20

    var body: some View {
        Color.clear.frame(width: 9).contentShape(Rectangle())
            .overlay { Rectangle().fill(accent.opacity(hovering || startWidth != nil ? 0.55 : 0)).frame(width: 2) }
            .onHover { inside in hovering = inside; setCursor(inside) }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = startWidth ?? shown
                    startWidth = start
                    width = MusicPanelWidth.afterDrag(start: start, translation: v.translation.width, total: total)
                }
                .onEnded { _ in startWidth = nil; Self.save(width) })
            .onTapGesture(count: 2) { width = nil; Self.save(nil) }
            .onDisappear { setCursor(false) }
            .accessibilityElement()
            .accessibilityLabel(Localized.string("Resize the details panel"))
            .accessibilityValue(Localized.string("%@ points wide", Int(shown).formatted()))
            .accessibilityHint(Localized.string("Double-click to go back to the automatic width"))
            .accessibilityAdjustableAction { d in
                let next = (width ?? shown) + (d == .increment ? Self.step : -Self.step)
                width = MusicPanelWidth.clamped(next, total: total)
                Self.save(width)
            }
            .musicTooltip("Drag to resize. Double-click to reset.")
            .atlas("control.music.panelResize")
    }

    private func setCursor(_ inside: Bool) {
        #if os(macOS)
        if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
        #endif
    }

    static func save(_ w: CGFloat?) {
        if let w { UserDefaults.standard.set(Double(w), forKey: MusicShellKeys.panelWidth) }
        else { UserDefaults.standard.removeObject(forKey: MusicShellKeys.panelWidth) }
    }

    /// The saved width, if any.
    static func saved() -> CGFloat? { MusicPanelWidth.decode(UserDefaults.standard.object(forKey: MusicShellKeys.panelWidth) as? Double) }
}
