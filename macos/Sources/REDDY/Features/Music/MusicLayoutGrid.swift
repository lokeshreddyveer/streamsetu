import SwiftUI

/// Music layout grid: breakpoints, region widths, page margins and the content width cap. Pure functions of the available width, so the
/// same numbers drive the shell, the pages and the tests.
///
/// Names (stable): `MusicLayoutClass` (`compact`, `medium`, `expanded`, `wide`), `MusicLayoutClass.resolve(width:)`,
/// `MusicLayoutGrid.breakpointMedium/Expanded/Wide`, `.navWidth(for:expanded:)`, `.contextPanelWidth(for:)`, `.contextPanelInline(for:)`,
/// `.pageMargin(for:)`, `.maxContentWidth`, `.contentWidth(available:)`, `.columns(for:)`.
enum MusicLayoutClass: Int, CaseIterable, Comparable, Sendable {
    /// Under 700 pt: one column, compact navigation, panels as overlay sheets.
    case compact
    /// 700 to under 1000 pt: compact navigation, panels as overlays.
    case medium
    /// 1000 to under 1400 pt: expanded navigation, panels as overlays.
    case expanded
    /// 1400 pt and up: expanded navigation and an inline context panel.
    case wide

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The layout class for a window (or region) width. Non-finite or negative widths count as compact.
    static func resolve(width: CGFloat) -> MusicLayoutClass {
        guard width.isFinite else { return .compact }
        if width >= MusicLayoutGrid.breakpointWide { return .wide }
        if width >= MusicLayoutGrid.breakpointExpanded { return .expanded }
        if width >= MusicLayoutGrid.breakpointMedium { return .medium }
        return .compact
    }
}

enum MusicLayoutGrid {
    static let breakpointMedium: CGFloat = 700
    static let breakpointExpanded: CGFloat = 1000
    static let breakpointWide: CGFloat = 1400

    // Region widths (ranges are the allowed span; the helpers pick a width inside them).
    static let navCompactRange: ClosedRange<CGFloat> = 64...76
    static let navExpandedRange: ClosedRange<CGFloat> = 220...260
    static let contextPanelRange: ClosedRange<CGFloat> = 300...380
    static let pageMarginRange: ClosedRange<CGFloat> = 24...36
    static let navCompactWidth: CGFloat = 68
    static let navExpandedWidth: CGFloat = 224
    static let contextPanelDefaultWidth: CGFloat = 340

    /// Content never grows wider than this (replaces the 1180 and 1000 literals); pages centre inside wider windows.
    static let maxContentWidth: CGFloat = 1180
    /// Narrow reading pages (settings, text-heavy detail) use this cap.
    static let maxReadingWidth: CGFloat = 1000

    /// The page never gets less than this much before the sidebar gives up its labels.
    static let comfortableContentWidth: CGFloat = 560
    /// Share of the window the context panel takes, inside `contextPanelRange`.
    static let contextPanelShare: CGFloat = 0.27

    /// Sidebar width. `expanded` is the person's choice; it is honoured only when the page still keeps `comfortableContentWidth` beside it
    /// (and the panel, when one is shown inline): otherwise the sidebar shrinks to icons so the page is not squeezed. The three regions share the width.
    static func navWidth(for cls: MusicLayoutClass, expanded: Bool, total: CGFloat? = nil, panel: CGFloat = 0) -> CGFloat {
        guard expanded else { return navCompactWidth }
        guard let total, total.isFinite else { return cls >= .expanded ? navExpandedWidth : navCompactWidth }
        return cls >= .medium && total - navExpandedWidth - panel >= comfortableContentWidth ? navExpandedWidth : navCompactWidth
    }

    /// Context panel width: it scales with the window (so a narrow window does not give half of itself to the panel) between the range's limits.
    static func contextPanelWidth(for cls: MusicLayoutClass) -> CGFloat { contextPanelDefaultWidth }
    static func contextPanelWidth(total: CGFloat) -> CGFloat {
        guard total.isFinite else { return contextPanelRange.lowerBound }
        return min(contextPanelRange.upperBound, max(contextPanelRange.lowerBound - 20, total * contextPanelShare))
    }

    /// The panel sits beside the page from the medium class up; only a window under 700 pt shows it as an overlay sheet.
    static func contextPanelInline(for cls: MusicLayoutClass) -> Bool { cls >= .medium }

    /// Horizontal page margin: 24 on compact, growing to 36 on wide.
    static func pageMargin(for cls: MusicLayoutClass) -> CGFloat {
        switch cls {
        case .compact: 24
        case .medium: 28
        case .expanded: 32
        case .wide: 36
        }
    }

    /// Width a page uses inside `available` points of content region, after margins and the cap.
    static func contentWidth(available: CGFloat, cap: CGFloat = maxContentWidth) -> CGFloat {
        let cls = MusicLayoutClass.resolve(width: available)
        return max(0, min(cap, available - pageMargin(for: cls) * 2))
    }

    /// Shelf and grid column counts by class (cards in a row of a typical shelf).
    static func columns(for cls: MusicLayoutClass) -> Int {
        switch cls {
        case .compact: 2
        case .medium: 3
        case .expanded: 5
        case .wide: 6
        }
    }
}
