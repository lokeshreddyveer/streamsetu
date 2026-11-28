import Foundation

// A small seam so the page the person is on goes first on a shared, rate-limited lane (MusicBrainz: one request per 1.1 seconds). Person completeness
// can queue about thirteen requests; an album page's enrichment waited behind them for about fifteen seconds. The governor orders its waiters by this
// priority (highest first, then first come first served); the lane's spacing and the one-at-a-time rule are unchanged, so the limit is still respected.
// Callers: the album and film enrichers use `.foreground` (the default for a request not marked background); the person-completeness writer marks its
// requests `.background` unless the person is on that very page (`MusicRequestPriority.forEntity`).

enum MusicRequestPriority: Int, Comparable, Sendable, Hashable {
    case background = 0, normal = 1, foreground = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The priority of a request made for `entity` while the person is looking at `focus` (the open page's entity, or nil).
    static func forEntity(_ entity: MusicEntityID, focus: MusicEntityID?, background: Bool = false) -> MusicRequestPriority {
        if let focus, focus == entity { return .foreground }
        return background ? .background : .normal
    }
}

/// The entity the person is looking at, set by the entity model center when a page opens (a seam: the governor knows nothing about pages).
final class MusicRequestFocus: @unchecked Sendable {
    static let shared = MusicRequestFocus()
    private let lock = NSLock()
    private var value: MusicEntityID?
    var entity: MusicEntityID? { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

enum MusicWaiterOrder {
    struct Item: Hashable, Sendable { var id: UInt64; var priority: MusicRequestPriority }
    /// Highest priority first; inside one priority, the longest waiting (lowest id) first.
    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }
}
