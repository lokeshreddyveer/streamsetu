import AVFoundation
import Accelerate
import Foundation

/// Why a song did not get an instrumental. Only `failed` and `incompleteDownload` are retried.
enum MusicKaraokeFailure: Error, Sendable, Equatable, Hashable {
    case failed, incompleteDownload, tooLong, noModel, cancelled

    var isRetryable: Bool { self == .failed || self == .incompleteDownload }
    var message: String {
        switch self {
        case .failed: "Couldn't take the vocals out of this song."
        case .incompleteDownload: "The song's audio didn't finish downloading. Trying again shortly."
        case .tooLong: "Over 15 minutes, so this song keeps its vocals."
        case .noModel: "Karaoke is not set up."
        case .cancelled: "Cancelled."
        }
    }
}

// MARK: Chunk bookkeeping

/// Where the model's chunks sit over a song, and the order they are worked in.
struct MusicChunkPlan: Sendable, Equatable {
    let config: MusicSTFTConfig
    /// Song length in frames.
    let length: Int
    let chunks: [Range<Int>]

    /// The song sits after `trim` zeros and before enough zeros to fill the last generation step.
    var pad: Int { config.gen + config.trim - (length % config.gen) }
    var mixtureLength: Int { config.trim + length + pad }

    init(config: MusicSTFTConfig, length: Int) {
        self.config = config; self.length = length
        let total = config.trim + length + (config.gen + config.trim - (length % config.gen))
        var list: [Range<Int>] = []
        var start = 0
        while start < total, config.step > 0 {
            list.append(start..<min(start + config.chunk, total))
            start += config.step
        }
        chunks = list
    }

    /// Starts at the chunk holding the play position, runs to the end, then wraps to the beginning.
    func order(startingAt sample: Int) -> [Int] {
        guard !chunks.isEmpty else { return [] }
        let p = min(max(0, sample), max(0, length - 1)) + config.trim
        let first = chunks.firstIndex(where: { $0.contains(p) }) ?? 0
        return Array(first..<chunks.count) + Array(0..<first)
    }

    /// Hann blend over a chunk's real length; one sample gets weight 1.
    static func blendWindow(_ n: Int) -> [Float] {
        guard n > 1 else { return [Float](repeating: 1, count: max(n, 0)) }
        return (0..<n).map { Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(n - 1))) }
    }
}

// MARK: PCM sources

/// Decoded stereo audio the engine reads from.
protocol MusicPCMSource: Sendable {
    var frameCount: Int { get }
    func read(_ range: Range<Int>) -> (left: [Float], right: [Float])
}

struct MusicArrayPCMSource: MusicPCMSource {
    let left: [Float]
    let right: [Float]
    var frameCount: Int { min(left.count, right.count) }
    func read(_ range: Range<Int>) -> (left: [Float], right: [Float]) {
        let r = range.clamped(to: 0..<frameCount)
        return (Array(left[r]), Array(right[r]))
    }
}

/// Interleaved float32 stereo in a file, memory mapped so a 15-minute song does not sit in memory.
struct MusicFilePCMSource: MusicPCMSource {
    private let data: Data
    let frameCount: Int
    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        frameCount = data.count / 8
    }
    func read(_ range: Range<Int>) -> (left: [Float], right: [Float]) {
        let r = range.clamped(to: 0..<frameCount)
        var l = [Float](repeating: 0, count: r.count), rr = l
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<r.count { l[i] = p[2 * (r.lowerBound + i)]; rr[i] = p[2 * (r.lowerBound + i) + 1] }
        }
        return (l, rr)
    }
}

// MARK: Engine

/// Chunked separation: STFT, model, inverse STFT, Hann blend between chunks, compensation, and the vocals-to-instrumental step.
enum MusicSeparationEngine {
    private struct Part { var left: [Float]; var right: [Float]; var div: [Float] }

    /// `emit(startFrame, left, right)` receives final instrumental samples once, in any order. `progress(done, total)` follows every chunk.
    static func run(source: MusicPCMSource, model: MusicStemModel, startingAt startSample: Int = 0,
                    progress: (Int, Int) -> Void = { _, _ in },
                    isCancelled: () -> Bool = { false },
                    emit: (Int, [Float], [Float]) throws -> Void) throws {
        let layout = model.layout, cfg = layout.stft
        guard let stft = MusicSTFT(config: cfg) else { throw MusicKaraokeFailure.failed }
        let length = source.frameCount
        guard length > 0 else { return }
        let plan = MusicChunkPlan(config: cfg, length: length)
        let order = plan.order(startingAt: startSample)
        var pending: [Int: Part] = [:]   // overlap between chunk b and b+1, held until its partner finishes
        let trim = cfg.trim

        func finalise(range m: Range<Int>, _ part: Part) throws {
            let lo = max(m.lowerBound, trim), hi = min(m.upperBound, trim + length)
            guard hi > lo else { return }
            let mix = source.read((lo - trim)..<(hi - trim))
            var l = [Float](repeating: 0, count: hi - lo), r = l
            for k in 0..<(hi - lo) {
                let j = lo - m.lowerBound + k
                let d = part.div[j]
                let vl = d >= 1e-6 ? part.left[j] / d * cfg.compensate : 0
                let vr = d >= 1e-6 ? part.right[j] / d * cfg.compensate : 0
                if layout.stem == .vocals { l[k] = mix.left[k] - vl; r[k] = mix.right[k] - vr } else { l[k] = vl; r[k] = vr }
            }
            try emit(lo - trim, l, r)
        }
        func slice(_ p: Part, _ r: Range<Int>) -> Part { Part(left: Array(p.left[r]), right: Array(p.right[r]), div: Array(p.div[r])) }

        for (done, i) in order.enumerated() {
            if isCancelled() { throw MusicKaraokeFailure.cancelled }
            let rng = plan.chunks[i], n = rng.count
            // Mixture chunk, zero filled outside the song and past the end.
            var inL = [Float](repeating: 0, count: cfg.chunk), inR = inL
            let songLo = rng.lowerBound - trim
            let lo = max(0, songLo), hi = min(length, rng.upperBound - trim)
            if hi > lo {
                let m = source.read(lo..<hi)
                for k in 0..<(hi - lo) { inL[lo - songLo + k] = m.left[k]; inR[lo - songLo + k] = m.right[k] }
            }
            var outL: [Float], outR: [Float]
            if let direct = model as? MusicWaveformStemModel {
                do { (outL, outR) = try direct.estimateVocals(left: inL, right: inR, stft: stft) } catch { throw MusicKaraokeFailure.failed }
            } else {
                let tensor = stft.tensor(left: stft.forward(inL), right: stft.forward(inR))
                let out: [Float]
                do { out = try model.separate(tensor) } catch { throw MusicKaraokeFailure.failed }
                guard out.count == cfg.tensorCount else { throw MusicKaraokeFailure.failed }
                let sp = stft.spectra(from: out)
                outL = stft.inverse(re: sp.left.re, im: sp.left.im)
                outR = stft.inverse(re: sp.right.re, im: sp.right.im)
            }
            let w = MusicChunkPlan.blendWindow(n)
            outL = Array(outL.prefix(n)); outR = Array(outR.prefix(n))
            outL = vDSP.multiply(outL, w); outR = vDSP.multiply(outR, w)
            let part = Part(left: outL, right: outR, div: w)

            let prevEnd = i > 0 ? plan.chunks[i - 1].upperBound : rng.lowerBound
            let nextStart = i < plan.chunks.count - 1 ? plan.chunks[i + 1].lowerBound : rng.upperBound
            let interior = max(rng.lowerBound, prevEnd)..<min(rng.upperBound, nextStart)
            if !interior.isEmpty {
                try finalise(range: interior, slice(part, (interior.lowerBound - rng.lowerBound)..<(interior.upperBound - rng.lowerBound)))
            }
            func overlap(_ key: Int, _ r: Range<Int>) throws {
                guard !r.isEmpty else { return }
                let mine = slice(part, (r.lowerBound - rng.lowerBound)..<(r.upperBound - rng.lowerBound))
                if let other = pending.removeValue(forKey: key), other.div.count == mine.div.count {
                    var sum = mine
                    for k in 0..<sum.div.count {
                        sum.left[k] += other.left[k]; sum.right[k] += other.right[k]; sum.div[k] += other.div[k]
                    }
                    try finalise(range: r, sum)
                } else { pending[key] = mine }
            }
            try overlap(i - 1, rng.lowerBound..<max(rng.lowerBound, prevEnd))   // with the chunk before
            try overlap(i, min(nextStart, rng.upperBound)..<rng.upperBound)     // with the chunk after
            progress(done + 1, order.count)
        }
        // A boundary whose partner never ran can only happen on a cancelled run; nothing is emitted for it.
    }
}

// MARK: Decode and fetch

enum MusicKaraokeDecoder {
    /// Decodes any file AVFoundation can read to interleaved float32 stereo at `sampleRate`, at most `maxSeconds` long. Mono becomes two channels.
    /// Returns the number of frames written to `output`.
    static func decode(file: URL, sampleRate: Double, maxSeconds: Double, output: URL, isCancelled: () -> Bool) async throws -> Int {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MusicKaraokeFailure.failed }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw MusicKaraokeFailure.failed }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 1000))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw MusicKaraokeFailure.failed }
        reader.add(out)
        guard reader.startReading() else { throw MusicKaraokeFailure.failed }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let h = try FileHandle(forWritingTo: output)
        defer { try? h.close() }
        var bytes = 0
        while let sample = out.copyNextSampleBuffer() {
            if isCancelled() { reader.cancelReading(); throw MusicKaraokeFailure.cancelled }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var data = Data(count: len)
            let ok = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            guard ok == kCMBlockBufferNoErr else { throw MusicKaraokeFailure.failed }
            try h.write(contentsOf: data)
            bytes += len
        }
        if reader.status == .failed { throw MusicKaraokeFailure.failed }
        return bytes / 8
    }
}

/// Where a track's audio can be fetched from.
struct MusicKaraokeAudioLocation: Sendable {
    var url: URL
    var headers: [String: String] = [:]
    /// False for an adaptive stream (HLS/DASH) that cannot be saved as one file.
    var isDownloadable: Bool = true
}

protocol MusicKaraokeAudioFetching: Sendable {
    /// A local file holding the song's audio. `isTemporary` files are deleted by the caller afterwards.
    func localAudio(for track: MusicTrack, into directory: URL, isCancelled: @Sendable () -> Bool) async throws -> (url: URL, isTemporary: Bool)
}

/// Saves the audio the player would stream, so the decoder reads a plain file. This is the "downloads its audio once more" step.
struct MusicKaraokeStreamFetcher: MusicKaraokeAudioFetching {
    let locate: @Sendable (MusicTrack) async throws -> MusicKaraokeAudioLocation
    var maxBytes: Int64 = 250 * 1_048_576

    func localAudio(for track: MusicTrack, into directory: URL, isCancelled: @Sendable () -> Bool) async throws -> (url: URL, isTemporary: Bool) {
        let loc: MusicKaraokeAudioLocation
        do { loc = try await locate(track) } catch { throw MusicKaraokeFailure.failed }
        if loc.url.isFileURL { return (loc.url, false) }
        guard loc.isDownloadable, loc.url.scheme?.lowercased() == "https" else { throw MusicKaraokeFailure.failed }
        var req = URLRequest(url: loc.url, timeoutInterval: 30)
        for (k, v) in loc.headers { req.setValue(v, forHTTPHeaderField: k) }
        let dest = directory.appendingPathComponent(UUID().uuidString + ".audio")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        do {
            let h = try FileHandle(forWritingTo: dest)
            defer { try? h.close() }
            let (bytes, response) = try await MusicTransfer.bytes(for: req)
            guard (200..<300).contains(response.statusCode) else { throw MusicKaraokeFailure.failed }
            var buf = Data(); var total: Int64 = 0
            for try await b in bytes {
                buf.append(b); total += 1
                if buf.count >= 65_536 { try h.write(contentsOf: buf); buf.removeAll(keepingCapacity: true) }
                if total > maxBytes { throw MusicKaraokeFailure.failed }
                if total % 65_536 == 0, isCancelled() { throw MusicKaraokeFailure.cancelled }
            }
            if !buf.isEmpty { try h.write(contentsOf: buf) }
        } catch let f as MusicKaraokeFailure {
            try? FileManager.default.removeItem(at: dest); throw f
        } catch {
            try? FileManager.default.removeItem(at: dest)
            if error is CancellationError { throw MusicKaraokeFailure.cancelled }
            if case MusicError.cancelled = error { throw MusicKaraokeFailure.cancelled }
            throw MusicKaraokeFailure.incompleteDownload
        }
        return (dest, true)
    }
}

/// The stream last handed out for each song, so a failed fetch can drop exactly that address.
final class MusicKaraokeLocatedStreams: @unchecked Sendable {
    private let lock = NSLock(); private var streams: [String: MusicStream] = [:]
    func set(_ s: MusicStream, for uid: String) { lock.lock(); streams[uid] = s; lock.unlock() }
    func take(_ uid: String) -> MusicStream? { lock.lock(); defer { lock.unlock() }; return streams.removeValue(forKey: uid) }
}

/// Wraps a fetcher: when the fetch fails (not when it is cancelled) the address that was tried is evicted from the stream resolver.
struct MusicKaraokeEvictingFetcher: MusicKaraokeAudioFetching {
    let base: MusicKaraokeAudioFetching
    let located: MusicKaraokeLocatedStreams
    let evict: @Sendable (MusicTrack, MusicStream?) async -> Void

    func localAudio(for track: MusicTrack, into directory: URL, isCancelled: @Sendable () -> Bool) async throws -> (url: URL, isTemporary: Bool) {
        do {
            let r = try await base.localAudio(for: track, into: directory, isCancelled: isCancelled)
            _ = located.take(track.uid)
            return r
        } catch {
            let stream = located.take(track.uid)
            if let f = error as? MusicKaraokeFailure, f == .cancelled {} else if !(error is CancellationError) { await evict(track, stream) }
            throw error
        }
    }
}

// MARK: Separator

struct MusicKaraokeJobRequest: Sendable, Equatable {
    var track: MusicTrack
    var startingAt: TimeInterval
    /// File stem of the model, part of the cache key so a model swap never plays an old model's output.
    var modelStem: String
}

/// Does one song from start to finish. The jobs queue owns scheduling; this owns the pipeline.
protocol MusicKaraokeWorking: Sendable {
    func run(_ job: MusicKaraokeJobRequest,
             onGrowing: @escaping @Sendable (MusicGrowingInstrumental) -> Void,
             progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

struct MusicKaraokeSeparator: MusicKaraokeWorking {
    let fetcher: MusicKaraokeAudioFetching
    let cache: MusicKaraokeCache
    /// Loads (or reuses) the model. Throws `.noModel` when none is installed.
    let loadModel: @Sendable () async throws -> MusicStemModel

    func run(_ job: MusicKaraokeJobRequest,
             onGrowing: @escaping @Sendable (MusicGrowingInstrumental) -> Void,
             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let track = job.track
        guard MusicKaraokeLimits.isQueueable(durationMs: track.durationMs) else { throw MusicKaraokeFailure.tooLong }
        if let hit = cache.lookup(modelStem: job.modelStem, trackID: track.uid) { return hit }
        let model: MusicStemModel
        do { model = try await loadModel() } catch let f as MusicKaraokeFailure { throw f } catch { throw MusicKaraokeFailure.noModel }
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            let work = cache.tempDirectory
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let audio = try await fetcher.localAudio(for: track, into: work, isCancelled: { cancel.isSet })
            defer { if audio.isTemporary { try? FileManager.default.removeItem(at: audio.url) } }
            let rate = model.layout.sampleRate
            let pcm = work.appendingPathComponent(UUID().uuidString + ".pcm")
            defer { try? FileManager.default.removeItem(at: pcm) }
            let frames = try await MusicKaraokeDecoder.decode(file: audio.url, sampleRate: rate, maxSeconds: MusicKaraokeLimits.decodeStopSeconds,
                                                              output: pcm, isCancelled: { cancel.isSet })
            if MusicKaraokeLimits.decodedTooLong(frames: frames, sampleRate: rate) { throw MusicKaraokeFailure.tooLong }
            if MusicKaraokeLimits.looksIncomplete(decodedSeconds: Double(frames) / rate, expectedSeconds: Double(track.durationMs) / 1000) {
                throw MusicKaraokeFailure.incompleteDownload
            }
            guard frames > 0 else { throw MusicKaraokeFailure.failed }
            let source = try MusicFilePCMSource(url: pcm)
            let growing = try MusicGrowingInstrumental(url: work.appendingPathComponent(UUID().uuidString + ".wav"), totalFrames: frames, sampleRate: rate)
            onGrowing(growing)
            let start = Int(max(0, job.startingAt) * rate)
            do {
                try await Task.detached(priority: .utility) {
                    try MusicSeparationEngine.run(source: source, model: model, startingAt: start,
                                                  progress: { done, total in progress(Double(done) / Double(max(total, 1))) },
                                                  isCancelled: { cancel.isSet },
                                                  emit: { try growing.write(startFrame: $0, left: $1, right: $2) })
                }.value
                let url = try growing.finalise(toStem: cache.stem(modelStem: job.modelStem, trackID: track.uid))
                growing.remove()
                return url
            } catch {
                growing.abandon(); growing.remove()
                throw error
            }
        } onCancel: { cancel.set() }
    }
}
