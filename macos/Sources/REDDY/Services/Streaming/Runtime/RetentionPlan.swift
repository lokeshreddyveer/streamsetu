import Foundation

/// How many web views stay alive. Hidden ones keep their website data when released; only in-page state is lost.
struct MemoryBudget: Equatable, Sendable {
    var maxLiveWebViews = 2
    var hiddenTTL: Duration = .seconds(30 * 60)
    var warningMaxLive = 1
    /// Hard cap on web views that are playing (or may be playing) in the background plus the visible one: beyond it the least recently used is paused.
    var maxPlayingViews = 4
    static let standard = MemoryBudget()
}

enum RetentionPlan {
    /// Least recently used first; never the visible one. `budget` counts the visible web view too. A view in `held` (playing, or possibly
    /// playing) is exempt: it is neither released nor counted against the budget (the playing cap bounds those instead).
    static func releaseList(live: [ProviderID], lastUsed: [ProviderID: Date], visible: ProviderID?, budget: Int, held: Set<ProviderID> = []) -> [ProviderID] {
        let live = live.filter { !held.contains($0) || $0 == visible }
        let ordered = live.sorted { (lastUsed[$0] ?? .distantPast) > (lastUsed[$1] ?? .distantPast) }          // newest first
        var keep = Set<ProviderID>()
        if let visible { keep.insert(visible) }          // it holds a slot even while its web view is still being made
        for id in ordered where keep.count < max(0, budget) { keep.insert(id) }
        return Array(ordered.filter { !keep.contains($0) }.reversed())
    }

    /// Playing views beyond the cap, least recently used first; the visible one is never listed. `playing` includes the visible one when it plays.
    static func pauseOverCap(playing: Set<ProviderID>, lastUsed: [ProviderID: Date], visible: ProviderID?, cap: Int) -> [ProviderID] {
        let excess = playing.count - max(1, cap)
        guard excess > 0 else { return [] }
        let hidden = playing.filter { $0 != visible }.sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }
        return Array(hidden.prefix(excess))
    }

    /// Under critical memory pressure the playing view that started first goes first (first in, first out); never the visible one.
    static func pressureVictim(playing: Set<ProviderID>, playingSince: [ProviderID: Date], visible: ProviderID?) -> ProviderID? {
        playing.filter { $0 != visible }.min { (playingSince[$0] ?? .distantPast) < (playingSince[$1] ?? .distantPast) }
    }
}
