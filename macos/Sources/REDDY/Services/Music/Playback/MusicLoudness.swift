import Foundation
import AVFoundation

// MARK: pure math

/// Loudness maths with no audio or disk in it, so it can be tested directly.
enum MusicLoudnessMath {
    /// Where tracks are brought to. -7 LUFS matches what the big streaming services play at; -14 would sound about 6 dB quieter.
    static let targetLUFS: Double = -7
    /// A reported loudness is measured against -14 LUFS: the absolute value is the report minus 14.
    static let reportedOffsetLUFS: Double = -14
    static let minGainDB: Double = -24
    /// Boosting more than this flattened dynamic masters in listening tests, and +3 still closes most of the gap to quiet old masters.
    static let maxGainDB: Double = 3
    /// A correction smaller than this is not applied at all (no 0 dB filter is inserted).
    static let deadZoneDB: Double = 0.05
    /// Fixed attenuation applied to every track on the player path that cannot exceed full scale, so a boost of up to `maxGainDB` is
    /// possible by starting this far below it. The engine path boosts for real and has a limiter instead.
    static let headroomDB: Double = 3
    /// ReplayGain 2 aims at -18 LUFS; iTunes Sound Check at about -16.
    static let replayGainReferenceLUFS: Double = -18
    static let soundCheckReferenceLUFS: Double = -16

    /// The correction that brings a track of the given absolute loudness to the target, clamped to -24...+3 dB. Zero (no filter) when
    /// the correction is under 0.05 dB or the loudness is unknown.
    static func gainDB(loudness: Double, target: Double = targetLUFS) -> Double {
        guard loudness.isFinite else { return 0 }
        let g = min(maxGainDB, max(minGainDB, target - loudness))
        return abs(g) < deadZoneDB ? 0 : g
    }

    /// Same rule for a loudness a service reported (measured against -14 LUFS).
    static func gainDB(reported: Double) -> Double {
        guard reported.isFinite else { return 0 }
        return gainDB(loudness: reported + reportedOffsetLUFS)
    }

    /// Any boost carries a peak limiter whose threshold is full scale; cuts never need one.
    static func needsLimiter(gainDB: Double) -> Bool { gainDB > 0 }

    /// True when the change is big enough to touch the audio at all.
    static func isAudible(change db: Double) -> Bool { abs(db) >= deadZoneDB }

    /// The AVPlayer volume factor for a gain: always 1.0 or lower.
    static func volumeFactor(gainDB: Double) -> Float {
        let total = min(maxGainDB, max(minGainDB, gainDB)) - headroomDB
        return Float(min(1, max(0, pow(10, total / 20))))
    }

    /// The linear amplitude for a gain on the engine path (no headroom: the limiter catches peaks).
    static func engineAmplitude(gainDB: Double) -> Float {
        Float(pow(10, min(maxGainDB, max(minGainDB, gainDB)) / 20))
    }

    /// The factor used while normalising with a track whose loudness is not known yet: the baseline alone.
    static var baselineFactor: Float { volumeFactor(gainDB: 0) }

    /// "-6.54 dB", "+3.2 dB" or "-6.54" give the number; anything else is nil.
    static func parseReplayGain(_ text: String) -> Double? {
        let cleaned = text.lowercased().replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite, abs(v) < 60 else { return nil }
        return v
    }

    /// The iTunNORM tag is ten hex words. The first two are the Sound Check adjustments for the left and right channel, as
    /// `1000 * 10^(-gain/10)`. The larger word (the smaller gain) is used so the result never clips. Returns the gain in dB.
    static func parseITunNorm(_ text: String) -> Double? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard words.count >= 2, let a = UInt32(words[0], radix: 16), let b = UInt32(words[1], radix: 16) else { return nil }
        let w = Double(max(a, b))
        guard w > 0 else { return nil }
        let gain = -10 * log10(w / 1000)
        return gain.isFinite && abs(gain) < 60 ? gain : nil
    }

    static func loudness(replayGainDB: Double) -> Double { replayGainReferenceLUFS - replayGainDB }
    static func loudness(soundCheckGainDB: Double) -> Double { soundCheckReferenceLUFS - soundCheckGainDB }
}

// MARK: K-weighted meter

/// A simplified BS.1770 meter: K-weighting filters, 400 ms blocks with 75 percent overlap, an absolute gate at -70 LUFS and a relative
/// gate 10 LU below the average. Feed it interleaved or per-channel float samples, then read `integratedLoudness`.
struct MusicLoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    let sampleRate: Double
    let channels: Int
    private var shelf: [Biquad]
    private var highPass: [Biquad]
    private var blockSquares: [Double]
    private let blockSize: Int
    private let hop: Int
    private var energies: [Double] = []

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        let (s, h) = Self.coefficients(sampleRate: sampleRate)
        shelf = Array(repeating: s, count: max(1, channels))
        highPass = Array(repeating: h, count: max(1, channels))
        blockSize = max(1, Int(sampleRate * 0.4))
        hop = max(1, Int(sampleRate * 0.1))
        blockSquares = []
    }

    /// The two filter stages of K-weighting for a sample rate (the ITU shelf and the 38 Hz high-pass), by the standard analog prototype.
    private static func coefficients(sampleRate fs: Double) -> (shelf: Biquad, highPass: Biquad) {
        let g = 3.999843853973347, q1 = 0.7071752369554196, f1 = 1681.9744509555319
        var k = tan(Double.pi * f1 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q1 + k * k
        let shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        let q2 = 0.5003270373238773, f2 = 38.13547087613982
        k = tan(Double.pi * f2 / fs)
        a0 = 1 + k / q2 + k * k
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        return (shelf, hp)
    }

    /// Adds interleaved samples (frames of `channels` values).
    mutating func add(interleaved samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        for f in 0..<frames {
            var sum = 0.0
            for c in 0..<channels {
                let x = Double(samples[f * channels + c])
                let y = highPass[c].process(shelf[c].process(x))
                sum += y * y
            }
            blockSquares.append(sum)
            if blockSquares.count >= blockSize {
                energies.append(blockSquares.reduce(0, +) / Double(blockSize))
                blockSquares.removeFirst(min(hop, blockSquares.count))
            }
        }
    }

    /// Integrated loudness in LUFS, or nil when there was nothing above the absolute gate (silence or too little audio).
    var integratedLoudness: Double? {
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
        let above = energies.filter { $0 > 0 && lufs($0) > -70 }
        guard !above.isEmpty else { return nil }
        let relative = lufs(above.reduce(0, +) / Double(above.count)) - 10
        let kept = above.filter { lufs($0) > relative }
        guard !kept.isEmpty else { return nil }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }
}

// MARK: service

/// Finds how loud a track is and remembers it. A tag in the file wins; otherwise the first 30 seconds are decoded and measured.
/// Results are kept per track uid in one small JSON file.
actor MusicLoudnessService {
    struct Record: Codable, Equatable, Sendable {
        var lufs: Double
        var source: String
        var at: Date
    }

    private static let maxRecords = 5000
    private static let measureSeconds = 30.0
    private let file: URL
    private var records: [String: Record] = [:]
    private var loaded = false
    private var inflight: [String: Task<Double?, Never>] = [:]

    init(directory: URL) { file = directory.appendingPathComponent("loudness.json") }

    /// What is already known about a track, without doing any work.
    func known(_ uid: String) -> Double? {
        loadIfNeeded()
        return records[uid]?.lufs
    }

    /// Loudness of the media at `asset`, from its tags or by measuring, remembered under `uid`. Nil when it cannot be read.
    func loudness(uid: String, asset: AVURLAsset) async -> Double? {
        loadIfNeeded()
        if let r = records[uid] { return r.lufs }
        if let running = inflight[uid] { return await running.value }
        let task = Task<Double?, Never> { [weak self] in
            if let tagged = await Self.tagLoudness(asset) { await self?.store(uid, tagged, "tag"); return tagged }
            if Task.isCancelled { return nil }
            guard let measured = await Self.measure(asset) else { return nil }
            await self?.store(uid, measured, "measured")
            return measured
        }
        inflight[uid] = task
        let v = await task.value
        inflight[uid] = nil
        return v
    }

    func forgetAll() {
        records = [:]; loaded = true
        try? FileManager.default.removeItem(at: file)
    }

    private func store(_ uid: String, _ lufs: Double, _ source: String) {
        records[uid] = Record(lufs: lufs, source: source, at: Date())
        if records.count > Self.maxRecords {
            for k in records.sorted(by: { $0.value.at < $1.value.at }).prefix(records.count - Self.maxRecords).map(\.key) { records[k] = nil }
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = r
    }

    // MARK: reading the file (off the actor)

    private static func tagLoudness(_ asset: AVURLAsset) async -> Double? {
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
                let info = (item.extraAttributes?[AVMetadataExtraAttributeKey(rawValue: "info")] as? String) ?? ""
                let label = (key + " " + info).uppercased()
                guard let text = try? await item.load(.stringValue) else { continue }
                if label.contains("REPLAYGAIN_TRACK_GAIN"), let g = MusicLoudnessMath.parseReplayGain(text) {
                    return MusicLoudnessMath.loudness(replayGainDB: g)
                }
                if label.contains("ITUNNORM"), let g = MusicLoudnessMath.parseITunNorm(text) {
                    return MusicLoudnessMath.loudness(soundCheckGainDB: g)
                }
            }
        }
        return nil
    }

    private static func measure(_ asset: AVURLAsset) async -> Double? {
        await Task.detached(priority: .utility) { () -> Double? in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let rate = 44_100.0, channels = 2
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: channels
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            var meter = MusicLoudnessMeter(sampleRate: rate, channels: channels)
            var frames = 0.0
            while frames < rate * measureSeconds, !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer else { continue }
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { p in
                    meter.add(interleaved: UnsafeBufferPointer(start: p, count: count))
                }
                frames += Double(count / channels)
            }
            reader.cancelReading()
            return meter.integratedLoudness
        }.value
    }
}
