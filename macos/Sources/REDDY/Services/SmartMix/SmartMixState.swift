import Foundation

/// One displayed row remembered for repeat suppression. Ids and keys only: no titles, no URLs.
struct SMShownRow: Sendable, Equatable {
    var key: String
    var year: Int?
    var itemId: String
    var seq: Int
}

/// Per-profile engine state (refresh counters and shown-history). The real store maps to `smartmix_state` and `smartmix_shown`
/// (device-local, keyed by profile id); the in-memory fake is what the tests use.
protocol SmartMixStateStore: Sendable {
    func refreshCounter(profile: String, shelf: String) -> Int
    /// Reshuffle: counter += 1 for the shelves on screen. Never starts a sync.
    func bumpRefresh(profile: String, shelves: [String])
    /// identityKey -> loads ago (>= 1). Rows of the load being built are ignored, so rebuilds in a session are stable.
    func loadsAgo(profile: String, shelf: String, loadKey: String) -> [String: Int]
    /// First successful render of a new load key: seq += 1, remember `rows`, keep the newest 48. Same load key again: no-op.
    func recordShown(profile: String, shelf: String, loadKey: String, rows: [SMShownRow])
    /// Drops shown rows for these identity keys on every shelf of the profile (a lock or hide happened).
    func forget(profile: String, keys: Set<String>)
    func clear(profile: String)
}

final class InMemorySmartMixStateStore: SmartMixStateStore, @unchecked Sendable {
    private struct Entry { var refresh = 0; var loadKey = ""; var seq = 0; var rows: [SMShownRow] = [] }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    static let keepRows = 48
    private func k(_ p: String, _ s: String) -> String { p + "\u{1}" + s }

    func refreshCounter(profile: String, shelf: String) -> Int { lock.withLock { entries[k(profile, shelf)]?.refresh ?? 0 } }

    func bumpRefresh(profile: String, shelves: [String]) {
        lock.withLock { for s in shelves { entries[k(profile, s), default: Entry()].refresh += 1 } }
    }

    func loadsAgo(profile: String, shelf: String, loadKey: String) -> [String: Int] {
        lock.withLock {
            guard let e = entries[k(profile, shelf)] else { return [:] }
            let eff = e.loadKey == loadKey ? e.seq : e.seq + 1
            var out: [String: Int] = [:]
            for r in e.rows {
                let ago = eff - r.seq
                if ago >= 1 { out[r.key] = min(out[r.key] ?? ago, ago) }
            }
            return out
        }
    }

    func recordShown(profile: String, shelf: String, loadKey: String, rows: [SMShownRow]) {
        lock.withLock {
            var e = entries[k(profile, shelf)] ?? Entry()
            if e.loadKey == loadKey { return }
            e.loadKey = loadKey
            e.seq += 1
            e.rows.append(contentsOf: rows.map { SMShownRow(key: $0.key, year: $0.year, itemId: $0.itemId, seq: e.seq) })
            // Stable sort by seq descending (newest first), keep 48.
            let indexed = e.rows.enumerated().sorted { $0.element.seq != $1.element.seq ? $0.element.seq > $1.element.seq : $0.offset < $1.offset }
            e.rows = indexed.prefix(Self.keepRows).map(\.element)
            entries[k(profile, shelf)] = e
        }
    }

    func forget(profile: String, keys: Set<String>) {
        lock.withLock {
            let prefix = profile + "\u{1}"
            for name in entries.keys where name.hasPrefix(prefix) { entries[name]?.rows.removeAll { keys.contains($0.key) } }
        }
    }

    func clear(profile: String) {
        lock.withLock { let prefix = profile + "\u{1}"; for name in entries.keys where name.hasPrefix(prefix) { entries[name] = nil } }
    }
}
