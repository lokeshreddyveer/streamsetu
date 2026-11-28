import Foundation

/// What the resolver remembers: the chosen picture per subject (30 days), "looked, found nothing" per subject, and per (subject, source) so one source's
/// miss is not asked again while the next source is tried. Thread-safe (a lock, no awaits inside), bounded, optionally kept in one JSON file.
/// Negative answers are short on purpose: a network failure is not a "no" and must not stick.
final class MusicArtworkResolutionCache: @unchecked Sendable {
    static let positiveTTL: TimeInterval = 30 * 86_400
    /// A clean "this source has nothing": a day.
    static let missTTL: TimeInterval = 86_400
    /// A network or server failure: ten minutes.
    static let transientTTL: TimeInterval = 1_800
    static let capacity = 4_000

    private struct Stored: Codable {
        var positives: [String: Positive] = [:]
        var misses: [String: Date] = [:]
    }
    private struct Positive: Codable { var value: MusicResolvedArtwork; var expires: Date }

    private let lock = NSLock()
    private var data = Stored()
    private var transientMisses: [String: Date] = [:]
    private let file: URL?
    private let now: @Sendable () -> Date
    private var dirty = false
    private var saving = false

    init(file: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file; self.now = now
        if let file, let raw = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: raw) { data = s }
    }

    // MARK: positive

    func positive(_ key: String) -> MusicResolvedArtwork? {
        lock.lock(); defer { lock.unlock() }
        guard let p = data.positives[key] else { return nil }
        if p.expires <= now() { data.positives[key] = nil; return nil }
        return p.value
    }

    func store(_ value: MusicResolvedArtwork, for key: String) {
        lock.lock()
        data.positives[key] = Positive(value: value, expires: now().addingTimeInterval(Self.positiveTTL))
        data.misses[key] = nil
        trim()
        dirty = true
        lock.unlock()
        scheduleSave()
    }

    /// A picture that no longer loads: forget it so the next ask resolves again.
    func forgetPositive(_ key: String, ifAddress address: String? = nil) {
        lock.lock()
        if let p = data.positives[key], address == nil || p.value.address == address { data.positives[key] = nil; dirty = true }
        lock.unlock()
        scheduleSave()
    }

    // MARK: negative

    /// Is `key` (a subject key, or `subject|source`) in a remembered miss?
    func isMiss(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if let u = transientMisses[key] { if u > t { return true }; transientMisses[key] = nil }
        if let u = data.misses[key] { if u > t { return true }; data.misses[key] = nil }
        return false
    }

    func recordMiss(_ key: String, transient: Bool) {
        lock.lock()
        if transient { transientMisses[key] = now().addingTimeInterval(Self.transientTTL) }
        else { data.misses[key] = now().addingTimeInterval(Self.missTTL); dirty = true }
        trim()
        lock.unlock()
        if !transient { scheduleSave() }
    }

    func clear() {
        lock.lock(); data = Stored(); transientMisses.removeAll(); dirty = false; lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    var counts: (positives: Int, misses: Int) { lock.lock(); defer { lock.unlock() }; return (data.positives.count, data.misses.count + transientMisses.count) }

    // MARK: bounds and disk

    private func trim() {
        let t = now()
        if data.positives.count > Self.capacity {
            for (k, v) in data.positives where v.expires <= t { data.positives[k] = nil }
            if data.positives.count > Self.capacity {
                for (k, _) in data.positives.sorted(by: { $0.value.expires < $1.value.expires }).prefix(data.positives.count - Self.capacity) { data.positives[k] = nil }
            }
        }
        if data.misses.count > Self.capacity * 2 {
            for (k, u) in data.misses where u <= t { data.misses[k] = nil }
            if data.misses.count > Self.capacity * 2 {
                for (k, _) in data.misses.sorted(by: { $0.value < $1.value }).prefix(data.misses.count - Self.capacity * 2) { data.misses[k] = nil }
            }
        }
    }

    /// One write at most every few seconds, off the caller's thread.
    private func scheduleSave() {
        guard file != nil else { return }
        lock.lock()
        if saving { lock.unlock(); return }
        saving = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in flush() }
    }

    /// Writes now (also called by tests). Does nothing without a file or without changes.
    func flush() {
        lock.lock()
        saving = false
        guard dirty, let file, let raw = try? JSONEncoder().encode(data) else { lock.unlock(); return }
        dirty = false
        lock.unlock()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? raw.write(to: file, options: .atomic)
    }
}
