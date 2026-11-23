import Foundation

/// How many web views stay alive. Hidden ones keep their website data when released; only in-page state is lost.
struct MemoryBudget: Equatable, Sendable {
    var maxLiveWebViews = 2
    var hiddenTTL: Duration = .seconds(30 * 60)
    var warningMaxLive = 1
    static let standard = MemoryBudget()
}

enum RetentionPlan {
    /// Least recently used first; never the visible one. `budget` counts the visible web view too.
    static func releaseList(live: [ProviderID], lastUsed: [ProviderID: Date], visible: ProviderID?, budget: Int) -> [ProviderID] {
        let ordered = live.sorted { (lastUsed[$0] ?? .distantPast) > (lastUsed[$1] ?? .distantPast) }          // newest first
        var keep = Set<ProviderID>()
        if let visible { keep.insert(visible) }          // it holds a slot even while its web view is still being made
        for id in ordered where keep.count < max(0, budget) { keep.insert(id) }
        return Array(ordered.filter { !keep.contains($0) }.reversed())
    }
}
