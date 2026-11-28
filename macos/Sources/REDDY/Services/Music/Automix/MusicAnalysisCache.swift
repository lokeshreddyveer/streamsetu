import Foundation

/// One small JSON file per analysed song, so a song is analysed once. The name is a hash of the track id and its length: the same id
/// with a different length (a different copy) is a different entry. Old schema versions are deleted on sight and never migrated.
final class MusicAnalysisCache: @unchecked Sendable {
    /// Oldest files go first once there are more than this.
    static let maxEntries = 2_000
    /// Only the first this-many bytes of an audio file are needed to analyse a song's start, and this much of the audio cache's budget
    /// at most is held back for songs waiting to be analysed (see `MusicAudioCache.pinForAnalysis`).
    static let pinnedBudgetBytes: Int64 = 96 * 1_048_576
    /// A stored length that differs from the playing copy by more than this means a different recording.
    static let lengthTolerance = 1.0

    private let directory: URL
    private let lock = NSLock()
    private var memory: [String: MusicTrackAnalysis] = [:]
    private let limit: Int

    init(directory: URL, limit: Int = MusicAnalysisCache.maxEntries) {
        self.directory = directory
        self.limit = max(1, limit)
    }

    static func key(trackUID: String, duration: Double) -> String {
        MusicHash.sha256("\(trackUID)|\(Int(duration.rounded()))", prefix: 16)
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    /// The stored analysis for a track, or nil. A stale schema or a length mismatch removes the file and answers nil.
    func analysis(trackUID: String, duration: Double) -> MusicTrackAnalysis? {
        let k = Self.key(trackUID: trackUID, duration: duration)
        if let m = lock.withLock({ memory[k] }) { return m }
        guard let data = try? Data(contentsOf: url(k)), let a = try? JSONDecoder().decode(MusicTrackAnalysis.self, from: data) else { return nil }
        guard a.schema == MusicTrackAnalysis.schemaVersion, a.failed || abs(a.duration - duration) <= Self.lengthTolerance else {
            try? FileManager.default.removeItem(at: url(k))
            return nil
        }
        lock.withLock { memory[k] = a }
        return a
    }

    func store(_ a: MusicTrackAnalysis, trackUID: String, duration: Double) {
        let k = Self.key(trackUID: trackUID, duration: duration)
        lock.withLock { memory[k] = a }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(a).write(to: url(k), options: .atomic)
        } catch { return }
        prune()
    }

    /// Deletes the oldest files (by modification date) beyond the limit.
    func prune() {
        let files = entries()
        guard files.count > limit else { return }
        for f in files.sorted(by: { $0.date < $1.date }).prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: f.url)
            lock.withLock { memory[f.url.deletingPathExtension().lastPathComponent] = nil }
        }
    }

    var count: Int { entries().count }
    var totalBytes: Int64 { entries().reduce(0) { $0 + $1.size } }

    func clear() {
        lock.withLock { memory = [:] }
        for f in entries() { try? FileManager.default.removeItem(at: f.url) }
    }

    private func entries() -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
        }
    }
}
