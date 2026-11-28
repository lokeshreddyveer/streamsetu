import Foundation

/// One rule for every shelf in Music that is a pick, not a ranking: it is drawn again on each new visit, favouring the front of the list but never fixed to it.
/// Charts keep their order (a chart is a ranking), and a visit within a short time keeps the same draw so nothing moves under the cursor.
@MainActor
enum MusicShelfVariety {
    private static var visits: [String: HomeSeedPolicy.Previous] = [:]

    /// The seed for this page right now: the same for a short while and on a return with Back or Forward, new after that or when `refresh` is true.
    static func seed(_ page: String, refresh: Bool = false, returning: Bool = false, now: Date = Date()) -> UInt64 {
        let d = HomeSeedPolicy.seed(now: now, previous: visits[page], refresh: refresh, returning: returning)
        // A return keeps the draw alive, so what runs next on the same page does not draw again under the restored scroll position.
        if !d.reused || returning { visits[page] = .init(seed: d.seed, at: now) }
        return d.seed
    }

    /// The seed the page was last drawn with (0 before its first draw), without drawing: for the first frame of a page that is built again.
    static func last(_ page: String) -> UInt64 { visits[page]?.seed ?? 0 }

    /// `items` in a fresh order: the first `keep` stay where they are, the rest are drawn with a chance that falls with their place in the list.
    nonisolated static func varied<T>(_ items: [T], seed: UInt64, name: String, keep: Int = 0) -> [T] {
        guard items.count > keep + 1 else { return items }
        var rng = HomeRandom.child(of: seed, name)
        let head = Array(items.prefix(keep)), tail = Array(items.dropFirst(keep))
        let indexed = Array(tail.enumerated())
        let drawn = HomeRandom.sample(indexed, count: indexed.count, weight: { 1 / (1 + Double($0.offset) / 6) }, using: &rng).map(\.element)
        return head + drawn
    }

    /// A different order of shelves for each draw, the first `keep` fixed.
    nonisolated static func shelfOrder<T>(_ shelves: [T], seed: UInt64, keep: Int = 0) -> [T] { varied(shelves, seed: seed, name: "shelf-order", keep: keep) }
}
