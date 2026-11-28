import SwiftUI

/// The one page frame of Music. Every page (Home, Explore, Search, Library, detail, Devices, Room, Downloads, Statistics, Import, Never Play)
/// uses the same margin and the same content cap from `MusicLayoutGrid`, so the left edge of the column is the same on every page at a given
/// window width. Wider windows centre the column; the edge still agrees across pages because the numbers do.
struct MusicPageFrame: Equatable, Sendable {
    /// The horizontal page margin for the window's layout class.
    let margin: CGFloat
    /// The width of the content column.
    let contentWidth: CGFloat
    /// The distance from the region's left edge to the column's left edge.
    let leadingEdge: CGFloat

    /// Room kept under the last content of every page so nothing rests under the app-wide floating assistant button (bottom right): the
    /// page scrolls past it. The button is at most `MusicTokens.assistantReserve` points square.
    static let bottomInset: CGFloat = MusicTokens.assistantReserve + MusicSpace.md
    /// The right edge of running text: notes and footnotes wrap inside this, never run to the column's edge or under the assistant button.
    static func noteWidth(contentWidth: CGFloat) -> CGFloat { max(0, min(contentWidth, MusicTokens.noteMaxWidth)) }

    /// The frame for a region `available` points wide. Non-finite or negative widths give an empty column.
    static func resolve(available: CGFloat, cap: CGFloat = MusicLayoutGrid.maxContentWidth) -> MusicPageFrame {
        guard available.isFinite, available > 0 else { return MusicPageFrame(margin: 0, contentWidth: 0, leadingEdge: 0) }
        let margin = MusicLayoutGrid.pageMargin(for: MusicLayoutClass.resolve(width: available))
        let room = max(0, available - margin * 2)
        let width = min(cap, room)
        return MusicPageFrame(margin: margin, contentWidth: width, leadingEdge: margin + (room - width) / 2)
    }
}

/// A scrolling page body in the shared frame: the column is `MusicPageFrame.contentWidth` wide, starts at the same x on every page, and has
/// the same top and bottom room. `MusicScreen` and the pages that draw their own header (Library, detail, Import) are built on it.
/// Room a page leaves for what floats over it: the player bar at the bottom and, on a nested page, the Back pill at the top. Set once by the shell and read by every page column.
/// (A scroll view's own `contentMargins` is not used: with it the page's buttons stopped answering clicks.)
private struct MusicBottomReserveKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct MusicTopReserveKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var musicBottomReserve: CGFloat { get { self[MusicBottomReserveKey.self] } set { self[MusicBottomReserveKey.self] = newValue } }
    var musicTopReserve: CGFloat { get { self[MusicTopReserveKey.self] } set { self[MusicTopReserveKey.self] = newValue } }
}

struct MusicPageColumn<Content: View>: View {
    var spacing: CGFloat = MusicSpace.xl
    /// Remembers the scroll position under this key when set.
    var memoryKey: String?
    @ViewBuilder var content: Content

    /// The width the column has to share out. Read beside the scroll view (never around it): a GeometryReader that wraps a ScrollView rebuilds the
    /// scroll view's layout whenever the proposal changes, which can reset what the person has scrolled.
    @State private var available: CGFloat = 1_000
    @Environment(\.musicBottomReserve) private var bottomReserve
    @Environment(\.musicTopReserve) private var topReserve

    var body: some View {
        let frame = MusicPageFrame.resolve(available: available)
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.top, MusicSpace.sm + topReserve).padding(.bottom, MusicPageFrame.bottomInset + bottomReserve)
                // The column takes the width it is offered (up to the cap) every layout pass; the measured `available` only picks the margin. A fixed width
                // taken from the last measurement trailed a resize by a frame, so a panel opening or the window shrinking left the page wider than its room.
                .padding(.horizontal, frame.margin)
                .frame(maxWidth: MusicLayoutGrid.maxContentWidth + frame.margin * 2, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        // In 8 pt steps: `available` only picks the margin, and a live resize would otherwise redraw the whole page for every half point the window moves.
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 8).rounded() * 8 } action: { w in if abs(w - available) > 0.5 { available = w } }
        if let memoryKey { scroll.musicScrollMemory(key: memoryKey) } else { scroll }
    }
}
