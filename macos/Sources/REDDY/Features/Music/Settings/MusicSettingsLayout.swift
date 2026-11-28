import SwiftUI

// The measurements of the Music settings overlay, in one place, so every tab and every row follows the same rules and a test can pin them.
//
// Rules:
// - One row height scale: a row is `rowHeight` (44 pt) tall at least; a plain value line is `compactRowHeight` (32 pt). Rows grow with their text, never shrink.
// - One alignment rule: the label column is on the leading side and takes what is left; the control column is on the trailing side. Every picker, slider
//   and field is `controlWidth` wide, so controls share one left and one right edge from row to row. A toggle sits at the trailing edge with
//   `toggleGap` of room between it and the label. The (i) button sits after the label, never before the control, so switches never shift.
// - A row whose label column would be narrower than `labelIdealWidth` puts its control under the label instead of squeezing it.
// - Groups: heading, `headingGap`, rows `rowSpacing` apart, an optional footer, then `MusicTokens.settingsGroupSpacing` to the next group.
// - The page scrolls inside `topInset` and `bottomInset`: the last row and a group footer always clear the window edge.
// - Rail: the full rail from `railCollapseWidth` up; below it the rail shows icons only and search moves above the content.
// - Content: the margin comes from `MusicLayoutGrid.pageMargin`, the column is capped at `MusicLayoutGrid.maxReadingWidth`.

extension MusicTokens {
    /// The one width of every menu, slider and field in a settings row (a slider's value text is inside it).
    static let settingsRowControlWidth: CGFloat = 184
}

enum MusicSettingsLayout {
    enum Rail: Equatable, Sendable { case full, icons }

    // Overlay size (a sheet may be resized between these).
    static let minWidth: CGFloat = 520
    static let minHeight: CGFloat = 480
    static let idealWidth: CGFloat = MusicTokens.settingsWidth
    static let idealHeight: CGFloat = MusicTokens.settingsHeight
    static let maxWidth: CGFloat = MusicLayoutGrid.maxReadingWidth
    static let maxHeight: CGFloat = 900

    /// Below this overlay width the rail shows icons only.
    static let railCollapseWidth: CGFloat = 600

    // Rows.
    static let rowHeight: CGFloat = MusicTokens.settingsRowMinHeight
    static let compactRowHeight: CGFloat = MusicSpace.xxl
    static let rowHeights: [CGFloat] = [compactRowHeight, rowHeight]
    static let rowSpacing: CGFloat = MusicSpace.xs
    static let headingGap: CGFloat = MusicSpace.sm
    static let labelGap: CGFloat = MusicSpace.md
    static let toggleGap: CGFloat = MusicSpace.sm
    static let controlWidth: CGFloat = MusicTokens.settingsRowControlWidth
    static let valueWidth: CGFloat = MusicTokens.settingsValueWidth
    /// The width a label column is offered before its control drops under it.
    static let labelIdealWidth: CGFloat = 140

    // Page.
    static let topInset: CGFloat = MusicSpace.xl
    static let bottomInset: CGFloat = MusicSpace.huge + MusicSpace.xl
    static let groupSpacing: CGFloat = MusicTokens.settingsGroupSpacing

    // Rail.
    static let accentBarWidth: CGFloat = MusicSpace.xxs
    static let railRowHeight: CGFloat = MusicTokens.settingsRowMinHeight

    static func rail(forWidth width: CGFloat) -> Rail { width < railCollapseWidth ? .icons : .full }

    static func railWidth(_ rail: Rail) -> CGFloat { rail == .full ? MusicTokens.settingsRailWidth : MusicLayoutGrid.navCompactWidth }

    /// The width left for the page next to the rail (and its one-point divider).
    static func regionWidth(total: CGFloat) -> CGFloat { max(0, total - railWidth(rail(forWidth: total)) - 1) }

    /// The side margin of the page, from the shared grid.
    static func margin(forRegion width: CGFloat) -> CGFloat { MusicLayoutGrid.pageMargin(for: MusicLayoutClass.resolve(width: width)) }

    /// The width of the column of groups inside a region.
    static func columnWidth(region: CGFloat) -> CGFloat { min(maxWidth, max(0, region - margin(forRegion: region) * 2)) }

    /// Whether a row of this label need and control width fits on one line inside `rowWidth`.
    static func fitsOnOneLine(rowWidth: CGFloat, labelNeed: CGFloat = labelIdealWidth, control: CGFloat = controlWidth) -> Bool {
        rowWidth >= labelNeed + labelGap + control
    }

    /// The room under the last row: at least the page inset, and more when the window has its own bottom safe area.
    static func footerInset(safeBottom: CGFloat = 0) -> CGFloat { max(bottomInset, safeBottom + topInset) }

    /// The tallest the scroll content ever needs to be scrolled: content plus both insets minus the viewport; the last row's bottom edge is then
    /// `footerInset` above the window edge.
    static func clearanceBelowLastRow(contentHeight: CGFloat, viewport: CGFloat, scrolledTo offset: CGFloat) -> CGFloat {
        (contentHeight + topInset + footerInset()) - (offset + viewport)
    }

    /// A step on the row height scale for a given text step: rows grow with the text and stay on the grid.
    static func rowHeight(forTextScale scale: CGFloat) -> CGFloat {
        let raw = rowHeight * max(1, scale)
        return (raw / MusicSpace.xxs).rounded(.up) * MusicSpace.xxs
    }
}

/// The settings formats for a value and its unit, so every slider reads the same way.
enum MusicSettingsFormat {
    static func seconds(_ value: Double) -> String { "\(Int(value.rounded())) s" }
    static func minutes(_ value: Int) -> String { value == 0 ? Localized.string("Off") : Localized.string("%d min", value) }
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

/// A ring that shows for the keyboard only: focused and not hovered by the pointer.
private struct MusicSettingsKeyRing: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.reddyAccent) private var accent
    @State private var hovering = false
    @State private var keyboard = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if MusicButtonLogic.showsFocusRing(focused: focused, keyboard: keyboard) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(accent, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .onHover { hovering = $0 }
            .onChange(of: focused) { _, now in keyboard = now && !hovering }
    }
}

/// A rail row: the chosen tab has a fill, a bold label and an accent bar at its leading edge; a hovered row has a lighter fill; the keyboard ring
/// shows for the keyboard only. The icon-only rail uses the same style.
struct MusicRailRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        MusicRailRowBody(configuration: configuration, selected: selected)
    }
}

private struct MusicRailRowBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous) }

    var body: some View {
        configuration.label
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(ColorTokens.textPrimary)
            .background(selected ? ColorTokens.elevated : (hovering || configuration.isPressed ? ColorTokens.elevated.opacity(0.6) : Color.clear), in: shape)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(accent).frame(width: MusicSettingsLayout.accentBarWidth, height: MusicSpace.lg)
                        .padding(.leading, MusicSpace.xxs / 2).accessibilityHidden(true)
                }
            }
            .modifier(MusicSettingsKeyRing(cornerRadius: MusicTokens.radiusRow))
            .musicContrastBorder(cornerRadius: MusicTokens.radiusRow, always: false)
            .contentShape(shape)
            .animation(MusicMotion.animation(.hover, reduce: BrandMotion.reduced(systemReduceMotion)), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The header button of a disclosure: a chevron and the title, with the same keyboard ring.
struct MusicDisclosureStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ColorTokens.textPrimary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .modifier(MusicSettingsKeyRing(cornerRadius: MusicTokens.radiusRow))
            .contentShape(Rectangle())
    }
}
