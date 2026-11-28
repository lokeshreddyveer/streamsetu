import Foundation

/// How a file is cut into blocks for read-ahead: a small first block (so the first bytes reach the player fast), then equal blocks.
struct MusicBlockGrid: Equatable, Sendable {
    var first: Int64 = 128 * 1024
    var block: Int64 = 512 * 1024
    var total: Int64 = 0

    var count: Int { total <= 0 ? 0 : (total <= first ? 1 : 1 + Int((total - first + block - 1) / block)) }

    func index(of offset: Int64) -> Int {
        let o = min(max(0, offset), max(0, total - 1))
        return o < first ? 0 : 1 + Int((o - first) / block)
    }

    func range(of index: Int) -> ClosedRange<Int64> {
        let start: Int64 = index == 0 ? 0 : first + Int64(index - 1) * block
        let end = min(total - 1, index == 0 ? first - 1 : start + block - 1)
        return start...max(start, end)
    }
}

/// Fetches the blocks a player will want next, while it is still reading the current one. A player that opens a new request every few hundred
/// kilobytes (AVPlayer scanning a fragmented file) otherwise pays one round trip to the host each time. Blocks are kept in memory, bounded.
final class MusicReadAhead: @unchecked Sendable {
    typealias Fetch = @Sendable (ClosedRange<Int64>) async -> Data?

    let grid: MusicBlockGrid
    /// How many blocks beyond the one being read are fetched ahead.
    let depth: Int
    let maxBlocks: Int
    private let fetch: Fetch
    private let lock = NSLock()
    private var slots: [Int: Task<Data?, Never>] = [:]
    private var stopped = false

    init(grid: MusicBlockGrid, depth: Int = 3, maxBlocks: Int = 24, fetch: @escaping Fetch) {
        self.grid = grid; self.depth = depth; self.maxBlocks = maxBlocks; self.fetch = fetch
    }

    /// The block's bytes, from memory when already fetched, else after its fetch finishes. Blocks after it are started. Nil when the fetch failed.
    func block(_ index: Int) async -> Data? {
        guard index >= 0, index < grid.count else { return nil }
        let task: Task<Data?, Never>? = lock.withLock {
            if stopped { return nil }
            for i in index...min(grid.count - 1, index + depth) where slots[i] == nil {
                let range = grid.range(of: i)
                let fetch = self.fetch
                slots[i] = Task { await fetch(range) }
            }
            trim(around: index)
            return slots[index]
        }
        guard let task else { return nil }
        let data = await task.value
        if data == nil { lock.withLock { if slots[index] == task { slots[index] = nil } } }
        return data
    }

    /// Drops the blocks farthest from the read position once more than `maxBlocks` are held (a block still being fetched is cancelled).
    private func trim(around index: Int) {
        while slots.count > maxBlocks, let far = slots.keys.max(by: { abs($0 - index) < abs($1 - index) }), abs(far - index) > depth {
            slots[far]?.cancel(); slots[far] = nil
        }
    }

    var heldBlocks: Int { lock.withLock { slots.count } }

    func stop() {
        let all: [Task<Data?, Never>] = lock.withLock { stopped = true; let t = Array(slots.values); slots = [:]; return t }
        all.forEach { $0.cancel() }
    }
}
