import AVFoundation
import Foundation

/// The 15-minute rule and its three enforcement points. Memory is the reason: separation holds a song's worth of audio.
enum MusicKaraokeLimits {
    static let maxTrackSeconds: Double = 900
    /// The decoder stops here so a long track cannot fill the disk; the extra 5 s lets the length check tell "just over" from "exactly at".
    static let decodeStopSeconds: Double = 905
    static let cacheLimitMBRange = 512...20_480
    static let defaultCacheLimitMB = 2_048
    static let retryDelays: [Double] = [5, 15, 30, 60]
    static let swapMinReadySeconds: Double = 5
    static let swapMinRate: Double = 1.2
    static let fallBackMarginSeconds: Double = 0.5

    /// Point 1: a known duration over the cap is never queued.
    static func isQueueable(durationMs: Int64) -> Bool { durationMs <= 0 || Double(durationMs) / 1000 <= maxTrackSeconds }
    /// Point 3: the decoded length.
    static func decodedTooLong(frames: Int, sampleRate: Double) -> Bool { Double(frames) / sampleRate > maxTrackSeconds }
    /// A stream that ended early: expected over 20 s, decoded under 90 % of it and short by more than 5 s.
    static func looksIncomplete(decodedSeconds: Double, expectedSeconds: Double) -> Bool {
        expectedSeconds > 20 && decodedSeconds < expectedSeconds * 0.9 && expectedSeconds - decodedSeconds > 5
    }
    static func clampCacheLimitMB(_ mb: Int) -> Int { min(max(mb, cacheLimitMBRange.lowerBound), cacheLimitMBRange.upperBound) }
}

// MARK: Naming

enum MusicKaraokeNaming {
    /// 64-bit FNV-1a.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
    static func hex16(_ v: UInt64) -> String { String(format: "%016llx", v) }

    /// ASCII letters, digits, dash and underscore survive; the 8-hex suffix of the original id keeps "a/b" and "a_b" apart.
    static func sanitised(_ id: String) -> String {
        var s = String(id.unicodeScalars.map { c -> Character in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_")) ? Character(c) : "_"
        })
        if s.isEmpty || s.count > 100 { s = hex16(fnv1a(id)) }
        return s + "-" + String(hex16(fnv1a(id)).prefix(8))
    }
    static func fileStem(modelStem: String, trackID: String) -> String { sanitised(modelStem) + "__" + sanitised(trackID) }
}

// MARK: Coverage

/// Which stretches of a growing file hold real audio. Samples land in any order as chunks finish.
struct MusicFrameCoverage: Sendable, Equatable {
    private(set) var ranges: [Range<Int>] = []

    mutating func insert(_ r: Range<Int>) {
        guard !r.isEmpty else { return }
        var merged = r
        var out: [Range<Int>] = []
        var placed = false
        for e in ranges {
            if e.upperBound < merged.lowerBound { out.append(e) }
            else if e.lowerBound > merged.upperBound {
                if !placed { out.append(merged); placed = true }
                out.append(e)
            } else {
                merged = min(e.lowerBound, merged.lowerBound)..<max(e.upperBound, merged.upperBound)
            }
        }
        if !placed { out.append(merged) }
        ranges = out
    }

    /// Contiguous written frames from `frame` onwards.
    func contiguous(from frame: Int) -> Int {
        for r in ranges where r.contains(frame) { return r.upperBound - frame }
        return 0
    }
    var total: Int { ranges.reduce(0) { $0 + $1.count } }
    func isComplete(of frames: Int) -> Bool { frames > 0 && ranges.count == 1 && ranges[0] == 0..<frames }
}

// MARK: Growing file

/// Where the instrumental lands while a song is being separated: a 32-bit float stereo WAV that already declares its final length.
/// A player can open it and read any stretch that `readyAhead` says is written. Thread safe.
final class MusicGrowingInstrumental: @unchecked Sendable {
    let url: URL
    let totalFrames: Int
    let sampleRate: Double
    private let handle: FileHandle
    private let lock = NSLock()
    private var coverage = MusicFrameCoverage()
    private var peakValue: Float = 0
    private var firstOutputAt: Date?
    private var framesSinceFirst: Int = 0
    private var finished = false
    private var abandoned = false
    static let headerSize = 44

    init(url: URL, totalFrames: Int, sampleRate: Double = 44_100) throws {
        self.url = url; self.totalFrames = totalFrames; self.sampleRate = sampleRate
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let dataBytes = totalFrames * 8
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        h.append(contentsOf: Array("WAVE".utf8)); h.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3); u16(2); u32(Int(sampleRate)); u32(Int(sampleRate) * 8); u16(8); u16(32)
        h.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        try handle.write(contentsOf: h)
        try handle.truncate(atOffset: UInt64(Self.headerSize + dataBytes))
    }

    deinit { try? handle.close() }

    func write(startFrame: Int, left: [Float], right: [Float], now: Date = Date()) throws {
        let n = min(left.count, right.count)
        guard n > 0, startFrame >= 0, startFrame + n <= totalFrames else { return }
        var bytes = [Float](repeating: 0, count: n * 2)
        var peak: Float = 0
        for i in 0..<n {
            bytes[2 * i] = left[i]; bytes[2 * i + 1] = right[i]
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); defer { lock.unlock() }
        guard !abandoned else { return }
        try handle.seek(toOffset: UInt64(Self.headerSize + startFrame * 8))
        try handle.write(contentsOf: data)
        coverage.insert(startFrame..<(startFrame + n))
        peakValue = max(peakValue, peak)
        if firstOutputAt == nil { firstOutputAt = now } else { framesSinceFirst += n }
    }

    var peak: Float { lock.lock(); defer { lock.unlock() }; return peakValue }
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return coverage.isComplete(of: totalFrames) }
    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
    func abandon() { lock.lock(); abandoned = true; lock.unlock() }

    /// Seconds of written audio directly ahead of `position`.
    func readyAhead(of position: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(coverage.contiguous(from: max(0, Int(position * sampleRate)))) / sampleRate
    }

    /// Seconds of audio produced per second of wall time since the first output. Zero until half a second has passed, so one fast chunk cannot fake a rate.
    func productionRate(now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let t0 = firstOutputAt else { return 0 }
        let dt = now.timeIntervalSince(t0)
        guard dt >= 0.5 else { return 0 }
        return Double(framesSinceFirst) / sampleRate / dt
    }

    var fractionWritten: Double {
        lock.lock(); defer { lock.unlock() }
        return totalFrames == 0 ? 0 : Double(coverage.total) / Double(totalFrames)
    }

    /// Reads floats back (interleaved) for a stretch that is fully written; nil otherwise.
    func read(frames r: Range<Int>) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard r.lowerBound >= 0, r.upperBound <= totalFrames, coverage.contiguous(from: r.lowerBound) >= r.count else { return nil }
        guard let rh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? rh.close() }
        do {
            try rh.seek(toOffset: UInt64(Self.headerSize + r.lowerBound * 8))
            guard let d = try rh.read(upToCount: r.count * 8), d.count == r.count * 8 else { return nil }
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch { return nil }
    }

    /// Writes the finished song as 16-bit lossless (FLAC, or CAF when the system will not write FLAC) at `destination` without an extension.
    /// Audio louder than full scale is scaled down by its peak, never boosted. Returns the file written.
    func finalise(toStem destination: URL) throws -> URL {
        guard isComplete else { throw MusicKaraokeFailure.failed }
        let scale: Float = peak > 1 ? 1 / peak : 1
        let tmpFLAC = destination.appendingPathExtension("flac.tmp")
        let tmpCAF = destination.appendingPathExtension("caf.tmp")
        for u in [tmpFLAC, tmpCAF] { try? FileManager.default.removeItem(at: u) }
        func settings(_ id: AudioFormatID) -> [String: Any] {
            var s: [String: Any] = [AVFormatIDKey: id, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
            if id == kAudioFormatLinearPCM { s[AVLinearPCMIsFloatKey] = false; s[AVLinearPCMIsBigEndianKey] = false }
            return s
        }
        var outFile: AVAudioFile?
        var finalURL = destination.appendingPathExtension("flac")
        var tmpURL = tmpFLAC
        if let f = try? AVAudioFile(forWriting: tmpFLAC, settings: settings(kAudioFormatFLAC)) { outFile = f }
        else {
            finalURL = destination.appendingPathExtension("caf"); tmpURL = tmpCAF
            outFile = try AVAudioFile(forWriting: tmpCAF, settings: settings(kAudioFormatLinearPCM))
        }
        guard let file = outFile,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else { throw MusicKaraokeFailure.failed }
        let block = 32_768
        var frame = 0
        while frame < totalFrames {
            let n = min(block, totalFrames - frame)
            guard let inter = read(frames: frame..<(frame + n)),
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let l = buf.floatChannelData?[0], let r = buf.floatChannelData?[1] else { throw MusicKaraokeFailure.failed }
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                l[i] = max(-1, min(1, inter[2 * i] * scale))
                r[i] = max(-1, min(1, inter[2 * i + 1] * scale))
            }
            try file.write(from: buf)
            frame += n
        }
        outFile = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: tmpURL, to: finalURL)
        return finalURL
    }

    func remove() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: Disk cache

/// Prepared instrumentals on disk, least recently used first out. Thread safe.
final class MusicKaraokeCache: @unchecked Sendable {
    struct Entry: Equatable, Sendable { var url: URL; var size: Int64; var modified: Date }

    let directory: URL
    private let lock = NSLock()
    private var pinned: [URL: Int] = [:]
    private var limitBytes: Int64

    init(directory: URL, limitMB: Int = MusicKaraokeLimits.defaultCacheLimitMB) {
        self.directory = directory
        limitBytes = Int64(MusicKaraokeLimits.clampCacheLimitMB(limitMB)) * 1_048_576
        let fm = FileManager.default
        try? fm.createDirectory(at: directory.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
        // Leftovers of a crash never look like a finished song.
        for sub in [directory, directory.appendingPathComponent("tmp", isDirectory: true)] {
            for u in (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            where u.pathExtension == "tmp" || sub.lastPathComponent == "tmp" { try? fm.removeItem(at: u) }
        }
    }

    var tempDirectory: URL { directory.appendingPathComponent("tmp", isDirectory: true) }
    var limitMB: Int { Int(limitBytes / 1_048_576) }

    func setLimitMB(_ mb: Int) {
        lock.lock(); limitBytes = Int64(MusicKaraokeLimits.clampCacheLimitMB(mb)) * 1_048_576; lock.unlock()
    }

    func stem(modelStem: String, trackID: String) -> URL {
        directory.appendingPathComponent(MusicKaraokeNaming.fileStem(modelStem: modelStem, trackID: trackID))
    }

    /// The finished file for a track, or nil. A hit touches the modification time so the file counts as recently used.
    func lookup(modelStem: String, trackID: String) -> URL? {
        let base = stem(modelStem: modelStem, trackID: trackID)
        for ext in ["flac", "caf"] {
            let u = base.appendingPathExtension(ext)
            if let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
                return u
            }
        }
        return nil
    }

    func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).compactMap { u in
            guard ["flac", "caf"].contains(u.pathExtension), let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
    }

    var usedBytes: Int64 { entries().reduce(0) { $0 + $1.size } }

    // Pinning: a file handed to the player cannot be evicted or cleared.
    /// Pins are keyed by the resolved path, so /var and /private/var spellings of one file count as the same file.
    private static func key(_ u: URL) -> URL { u.resolvingSymlinksInPath().standardizedFileURL }
    func pin(_ u: URL) { let k = Self.key(u); lock.lock(); pinned[k, default: 0] += 1; lock.unlock() }
    func unpin(_ u: URL) {
        let u = Self.key(u)
        lock.lock(); defer { lock.unlock() }
        guard let c = pinned[u] else { return }
        if c <= 1 { pinned[u] = nil } else { pinned[u] = c - 1 }
    }
    func isPinned(_ u: URL) -> Bool { let k = Self.key(u); lock.lock(); defer { lock.unlock() }; return pinned[k] != nil }

    /// Oldest first, never the protected files, until the total is under the limit.
    static func evictionPlan(entries: [Entry], limitBytes: Int64, protected: Set<URL>) -> [URL] {
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        var out: [URL] = []
        let keep = Set(protected.map(key))
        for e in entries.sorted(by: { $0.modified < $1.modified }) {
            if total <= limitBytes { break }
            if keep.contains(key(e.url)) { continue }
            out.append(e.url); total -= e.size
        }
        return out
    }

    /// `wanted` are file URLs of the current track and the next two.
    @discardableResult
    func evict(wanted: Set<URL> = []) -> Int {
        lock.lock(); let limit = limitBytes; let pins = Set(pinned.keys); lock.unlock()
        let plan = Self.evictionPlan(entries: entries(), limitBytes: limit, protected: wanted.union(pins))
        var removed = 0
        for u in plan where (try? FileManager.default.removeItem(at: u)) != nil { removed += 1 }
        return removed
    }

    /// Removes every file that is not pinned.
    @discardableResult
    func clear() -> Int {
        lock.lock(); let pins = Set(pinned.keys); lock.unlock()
        var removed = 0
        for e in entries() where !pins.contains(Self.key(e.url)) {
            if (try? FileManager.default.removeItem(at: e.url)) != nil { removed += 1 }
        }
        for u in (try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: u) }
        return removed
    }
}
