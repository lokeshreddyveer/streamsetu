import Foundation

/// Keeps the arbiter's decisions (field, candidate values, sources, witnesses, confidence, status, winner, reason) next to the graph, in one small file, so a
/// screen can show why a value was chosen and a refresh does not have to decide again. Capped, oldest first out. Nothing here is a source of truth: it can be
/// deleted at any time and is rebuilt from the graph's claims.
final class MusicFieldDecisionStore: @unchecked Sendable {
    static let shared = MusicFieldDecisionStore(url: MusicStorage.subfolder("Arbitration").appendingPathComponent("decisions.json"))
    static let capacity = 3_000

    private let lock = NSLock()
    private var decisions: [String: MusicFieldDecision] = [:]
    private let url: URL?
    private var loaded = false
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "StreamSetu.Music.Arbitration", qos: .utility)

    init(url: URL?) { self.url = url }

    static func key(_ entity: MusicEntityID, _ field: MusicArbitratedField) -> String { entity.rawValue + "|" + field.rawValue }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let url, let d = try? Data(contentsOf: url), let m = try? MusicJSONCoding.makeDecoder().decode([String: MusicFieldDecision].self, from: d) { decisions = m }
    }

    /// Writes the file a couple of seconds after the last change, off the caller's thread. Caller holds the lock.
    private func scheduleSave() {
        guard let url else { return }
        pending?.cancel()
        let snapshot = decisions
        let work = DispatchWorkItem { if let d = try? MusicJSONCoding.makeEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) } }
        pending = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func record(_ entity: MusicEntityID, _ d: MusicFieldDecision) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        decisions[Self.key(entity, d.field)] = d
        if decisions.count > Self.capacity {
            for k in decisions.sorted(by: { $0.value.decidedAt < $1.value.decidedAt }).prefix(decisions.count - Self.capacity).map(\.key) { decisions[k] = nil }
        }
        scheduleSave()
    }

    func decision(_ entity: MusicEntityID, _ field: MusicArbitratedField) -> MusicFieldDecision? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return decisions[Self.key(entity, field)]
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel(); pending = nil
        if let url, let d = try? MusicJSONCoding.makeEncoder().encode(decisions) { try? d.write(to: url, options: .atomic) }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel(); pending = nil
        decisions = [:]; loaded = true
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
