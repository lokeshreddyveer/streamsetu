import Foundation

// An incremental mirror of a newest-first list (the play history, up to 50,000 rows). The recommender used to map the whole history on the main actor
// after every finished play. The mirror keeps the converted list and, when the source only gained rows at the front (and lost rows at the back once it is
// full), converts just the new rows; any other change rebuilds. Pure and generic; the app runs it on its own actor, off the main thread.

struct MusicHistoryMirror<Source: Equatable, Out> {
    private(set) var source: [Source] = []
    private(set) var out: [Out] = []
    /// Rows converted by the last `update`, for tests and diagnostics.
    private(set) var lastConverted = 0
    private(set) var rebuilds = 0

    /// How far from the front the old first row may have moved (new plays since the last read).
    static var probeWindow: Int { 512 }

    mutating func update(_ new: [Source], convert: (Source) -> Out) -> [Out] {
        if new == source { lastConverted = 0; return out }     // O(n) compare only when counts match; usually short-circuits at the first row
        if let k = Self.prependCount(old: source, new: new) {
            let fresh = new.prefix(k).map(convert)
            let keep = max(0, min(out.count, new.count - k))
            out = fresh + out.prefix(keep)
            lastConverted = k
        } else {
            out = new.map(convert); rebuilds += 1; lastConverted = new.count
        }
        source = new
        return out
    }

    /// k when `new` is `k` fresh rows followed by (a prefix of) `old`, else nil. Checks the boundary rows only, which is enough for an append-only log.
    static func prependCount(old: [Source], new: [Source]) -> Int? {
        guard let first = old.first, !new.isEmpty else { return nil }
        guard let k = new.prefix(probeWindow).firstIndex(of: first) else { return nil }
        let overlap = min(old.count, new.count - k)
        guard overlap > 0 else { return nil }
        for probe in Set([0, overlap / 2, overlap - 1]) where new[k + probe] != old[probe] { return nil }
        return k
    }
}

/// A one-value memo keyed by a signature string: Home keeps its derived plan, hero and top tracks here and recomputes only when the signature changes,
/// not on every `body` evaluation.
final class MusicMemo<Value>: @unchecked Sendable {
    private var key: String?
    private var stored: Value?
    init() {}
    func value(for signature: String, compute: () -> Value) -> Value {
        if key == signature, let stored { return stored }
        let v = compute()
        key = signature; stored = v
        return v
    }
    func reset() { key = nil; stored = nil }
}
