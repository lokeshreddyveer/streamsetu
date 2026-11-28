import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// What Music lets the person drag, and how a list scrolls while something is being dragged near its edge.
enum MusicDragKind: String, CaseIterable, Sendable {
    /// Any card (album, playlist, artist, song). Only the Home shortcuts grid accepts it.
    case browseItem
    /// A queue row; carries its queue index.
    case queueRow
    /// A row of a local playlist.
    case playlistRow
    /// A Home section in the layout panel.
    case homeSection
    /// A lyrics source row in Settings.
    case lyricsSource

    /// Each kind has its own type so a drop zone can tell ours from foreign drags.
    var identifier: String { "app.streamsetu.music.drag." + rawValue }
    var contentType: UTType { UTType(exportedAs: identifier) }
}

enum MusicDragAndDrop {
    /// Within this distance of the top or bottom edge the list starts to scroll.
    static let edgeZone: CGFloat = 96
    /// Scroll speed at the edge, and past it, in points per second.
    static let maxSpeed: CGFloat = 1800
    static let tick: TimeInterval = 0.016
    /// A stalled frame never throws the page: the step is capped at this much elapsed time.
    static let maxCatchUp: TimeInterval = 0.1
    /// The timer stops by itself when no drag update arrives for this long.
    static let idleStop: TimeInterval = 3
    static let shortcutCapacity = 12

    /// The scroll velocity (negative is up) for a pointer at `y` inside a box of `height`. Zero away from the edges, ramping linearly to `maxSpeed`.
    static func scrollSpeed(pointerY y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        if y < edgeZone { return -maxSpeed * min(1, (edgeZone - y) / edgeZone) }
        if y > height - edgeZone { return maxSpeed * min(1, (y - (height - edgeZone)) / edgeZone) }
        return 0
    }

    /// How far to scroll for one timer step.
    static func step(speed: CGFloat, elapsed: TimeInterval) -> CGFloat { speed * CGFloat(min(max(0, elapsed), maxCatchUp)) }

    /// Where a dropped row lands: the upper half of a row means before it, the lower half after it.
    static func insertionIndex(overRow row: Int, pointerY y: CGFloat, rowHeight: CGFloat) -> Int { y < rowHeight / 2 ? row : row + 1 }

    /// A reorder is refused while the list is filtered, sorted away from its default order, descending, in selection mode, or still saving a move.
    static func canReorder(filtered: Bool, sortedAwayFromDefault: Bool, descending: Bool, selecting: Bool, saving: Bool, morePagesToLoad: Bool, targetBeyondLoaded: Bool) -> Bool {
        !(filtered || sortedAwayFromDefault || descending || selecting || saving || (morePagesToLoad && targetBeyondLoaded))
    }

    /// Dropping a card on the shortcuts grid: a duplicate is refused; over capacity the least recently used tile makes room.
    enum ShortcutDrop: Equatable, Sendable { case add, duplicate, addEvicting(oldestIndex: Int) }
    static func shortcutDrop(existing: [String], newID: String, capacity: Int = shortcutCapacity, leastRecent: Int? = nil) -> ShortcutDrop {
        if existing.contains(newID) { return .duplicate }
        if existing.count >= capacity { return .addEvicting(oldestIndex: leastRecent ?? 0) }
        return .add
    }
}
