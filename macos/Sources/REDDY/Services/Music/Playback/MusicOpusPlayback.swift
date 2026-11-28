import Foundation
import AVFoundation
import os

// The second playback backend. It plays WebM and Ogg Opus, which the system player cannot open: bytes come in through ranged reads, are
// demuxed (MusicOpusPipeline), decoded with the system Opus decoder (MusicOpusDecoder) and handed to an AVAudioSourceNode through a ring
// buffer. The position is counted from the frames the audio device actually pulled, so it is exact and it stands still while the
// network starves the buffer. Tempo, pitch, reverb and the equalizer are not applied on this path; volume and loudness gain are.

// MARK: ring buffer

/// Decoded audio between the decoding task (writer) and the audio render thread (reader). A short lock-protected copy on each side.
final class MusicOpusRing: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private var channels = 2
    private var data: [UnsafeMutablePointer<Float>] = []
    private var readIndex = 0
    private var writeIndex = 0
    private var playing = false
    private var played: Int64 = 0
    private var baseSeconds = 0.0
    private var eof = false
    private var starving = false
    private var wroteSinceFlush = false

    init(seconds: Double = 12) {
        capacity = Int(seconds * Self.sampleRate)
        for _ in 0..<2 {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            data.append(p)
        }
    }

    deinit { for p in data { p.deallocate() } }

    func configure(channels c: Int) { lock.withLock { channels = min(2, max(1, c)) } }

    /// Empties the buffer and sets the time the next written frame stands for.
    func flush(base: Double) {
        lock.withLock {
            readIndex = 0; writeIndex = 0; played = 0; baseSeconds = base; eof = false; starving = false; wroteSinceFlush = false
        }
    }

    func setPlaying(_ p: Bool) { lock.withLock { playing = p } }
    func markEnd() { lock.withLock { eof = true } }

    var freeFrames: Int { lock.withLock { capacity - (writeIndex - readIndex) } }
    var bufferedFrames: Int { lock.withLock { writeIndex - readIndex } }
    var position: Double { lock.withLock { baseSeconds + Double(played) / Self.sampleRate } }
    var isStarving: Bool { lock.withLock { starving } }
    /// The end of the stream was written and every frame has been played.
    var isDrained: Bool { lock.withLock { eof && writeIndex == readIndex } }
    var hasWritten: Bool { lock.withLock { wroteSinceFlush } }

    /// If nothing has been written since the last flush, the stream's real first time replaces the requested one.
    func rebaseIfEmpty(_ t: Double) { lock.withLock { if !wroteSinceFlush { baseSeconds = t } } }

    /// Appends frames. Returns false, writing nothing, when there is no room.
    @discardableResult
    func write(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let src = buf.floatChannelData else { return true }
        let n = Int(buf.frameLength)
        let srcChannels = Int(buf.format.channelCount)
        return lock.withLockUnchecked {
            guard capacity - (writeIndex - readIndex) >= n else { return false }
            for c in 0..<min(srcChannels, 2) {
                var w = writeIndex % capacity
                var left = n
                var from = 0
                while left > 0 {
                    let run = min(left, capacity - w)
                    (data[c] + w).update(from: src[c] + from, count: run)
                    w = (w + run) % capacity; from += run; left -= run
                }
            }
            writeIndex += n
            wroteSinceFlush = true
            starving = false
            return true
        }
    }

    /// Fills the device buffers. Runs on the audio thread, so it only copies.
    func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        lock.withLockUnchecked {
            let avail = writeIndex - readIndex
            let n = playing ? min(frames, avail) : 0
            for ch in 0..<buffers.count {
                guard let out = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let source = data[min(ch, channels - 1)]
                var r = readIndex % capacity
                var left = n
                var at = 0
                while left > 0 {
                    let run = min(left, capacity - r)
                    (out + at).update(from: source + r, count: run)
                    r = (r + run) % capacity; at += run; left -= run
                }
                if n < frames { (out + n).update(repeating: 0, count: frames - n) }
            }
            readIndex += n
            played += Int64(n)
            if playing { starving = n < frames && !eof }
        }
    }
}

// MARK: backend

/// Callbacks run on the main actor. `token` is the one given to `start`, so a late callback from a replaced track can be ignored.
@MainActor
final class MusicOpusPlayback {
    /// The system can decode Opus.
    static var isAvailable: Bool { MusicOpusDecoder.isAvailable }

    #if os(macOS)
    /// Points this backend's output at the device with this uid (nil is the system output). False when it would not open.
    @discardableResult func setOutputDevice(uid: String?) -> Bool { MusicCoreAudioOutputs.assign(uid: uid, to: engine) }
    #endif

    var onFinished: ((Int) -> Void)?
    var onFailed: ((Int, String) -> Void)?
    var onBufferingChanged: ((Int, Bool) -> Void)?
    var onDuration: ((Int, Double) -> Void)?

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let ring = MusicOpusRing()
    private var sourceNode: AVAudioSourceNode?
    private var attached = false
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var session: Session?
    private var token = 0
    private var playing = false
    private var volume: Float = 1
    private var gain: Float = 1
    private var announcedBuffering = false
    private var finishedSent = false
    private(set) var duration: Double?
    /// First moment sound was queued after `start`, for the latency report.
    private(set) var startedAt: Date?
    private(set) var firstSoundAt: Date?

    private struct WeakBackend: Sendable {
        weak var backend: MusicOpusPlayback?
        init(_ b: MusicOpusPlayback) { backend = b }
    }

    private final class Session: @unchecked Sendable {
        let pipeline: MusicOpusPipeline
        var decoder: MusicOpusDecoder?
        var opened = false
        var started = false
        init(source: MusicOpusByteSource) { pipeline = MusicOpusPipeline(source: source) }
    }

    init() {}

    /// Seconds into the track, from the frames the device has played.
    var position: TimeInterval { ring.position }
    var isBuffering: Bool { announcedBuffering }
    var isActive: Bool { session != nil }

    // MARK: control

    func start(source: MusicOpusByteSource, at start: TimeInterval, volume: Float, gainDB: Double, playing: Bool, token: Int) {
        stop()
        self.token = token
        self.volume = volume
        self.gain = Self.linear(gainDB)
        self.playing = playing
        finishedSent = false
        announcedBuffering = false
        duration = nil
        startedAt = Date(); firstSoundAt = nil
        let s = Session(source: source)
        session = s
        applyVolume()
        ring.flush(base: start)
        ring.setPlaying(playing)
        launch(s, at: start, token: token)
        startMonitor(token: token)
    }

    func pause() {
        playing = false
        ring.setPlaying(false)
        engine.pause()
    }

    func resume() {
        guard session != nil else { return }
        playing = true
        ring.setPlaying(true)
        startEngineIfNeeded()
    }

    func seek(to t: TimeInterval) {
        guard let s = session else { return }
        finishedSent = false
        ring.flush(base: t)
        ring.setPlaying(playing)
        launch(s, at: t, token: token)
    }

    /// The visualizer copy of the output (see MusicAudioTap).
    func setVisualizerTap(_ on: Bool) { MusicAudioTap.setEngineTap(engine, on: on) }

    func stop() {
        task?.cancel(); task = nil
        monitor?.cancel(); monitor = nil
        session?.pipeline.cancel()
        session = nil
        ring.setPlaying(false)
        ring.flush(base: 0)
        if engine.isRunning { engine.stop() }
        playing = false
        announcedBuffering = false
    }

    func setVolume(_ v: Float) { volume = v; applyVolume() }
    func setGain(db: Double) { gain = Self.linear(db); applyVolume() }

    private static func linear(_ db: Double) -> Float { abs(db) < 0.05 ? 1 : Float(pow(10.0, db / 20.0)) }
    private func applyVolume() { mixer.outputVolume = max(0, volume * gain) }

    // MARK: engine

    private func buildGraphIfNeeded(channels: Int) {
        ring.configure(channels: channels)
        guard !attached else { return }
        let format = MusicOpusDecoder.pcmFormat(channels: 2)
        let node = Self.makeNode(ring: ring, format: format)
        engine.attach(node)
        engine.attach(mixer)
        engine.connect(node, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        sourceNode = node
        attached = true
        applyVolume()
    }

    /// Built outside the main actor on purpose: the render block runs on the audio thread and must not inherit main-actor isolation.
    nonisolated private static func makeNode(ring: MusicOpusRing, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, abl in
            ring.render(frames: Int(frames), buffers: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
    }

    private func startEngineIfNeeded() {
        guard playing, !engine.isRunning else { return }
        do { try engine.start() } catch { fail("the audio output could not start (\(error.localizedDescription))") }
    }

    private func fail(_ why: String) {
        let t = token
        stop()
        onFailed?(t, why)
    }

    // MARK: driving

    private func launch(_ s: Session, at start: Double, token t: Int) {
        let previous = task
        previous?.cancel()
        let ring = self.ring
        let box = WeakBackend(self)
        task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await Self.drive(session: s, ring: ring, startAt: start, openedHook: { channels, duration in
                    await MainActor.run {
                        guard let self = box.backend, self.token == t else { return }
                        self.duration = duration
                        self.buildGraphIfNeeded(channels: channels)
                        self.startEngineIfNeeded()
                        if let d = duration { self.onDuration?(t, d) }
                    }
                }, firstSoundHook: {
                    await MainActor.run {
                        guard let self = box.backend, self.token == t, self.firstSoundAt == nil else { return }
                        self.firstSoundAt = Date()
                    }
                })
                ring.markEnd()
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard let self = box.backend, self.token == t else { return }
                    self.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    private func startMonitor(token t: Int) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, self.token == t else { return }
                let starving = self.playing && self.session != nil && self.ring.isStarving
                if starving != self.announcedBuffering { self.announcedBuffering = starving; self.onBufferingChanged?(t, starving) }
                if self.ring.isDrained, !self.finishedSent, self.playing {
                    self.finishedSent = true
                    self.onFinished?(t)
                }
            }
        }
    }

    /// Opens the stream if needed, positions it, then decodes and queues audio until the end, waiting whenever the buffer is full.
    nonisolated private static func drive(session s: Session, ring: MusicOpusRing, startAt: Double,
                              openedHook: @escaping @Sendable (Int, Double?) async -> Void,
                              firstSoundHook: @escaping @Sendable () async -> Void) async throws {
        if !s.opened {
            let info = try await s.pipeline.open()
            s.decoder = try MusicOpusDecoder(head: info.head)
            s.opened = true
            await openedHook(info.head.channels, info.duration)
        }
        guard let decoder = s.decoder else { throw MusicOpusError.unavailable }
        var discardBefore = 0.0
        if startAt > 0.05 {
            try await s.pipeline.seek(to: startAt)
            decoder.reset(applyPreSkip: false)
            discardBefore = startAt
        } else if s.started {
            try await s.pipeline.seek(to: 0)
            decoder.reset(applyPreSkip: true)
        }
        s.started = true
        var expected: Double?
        var failures = 0
        var announced = false
        while let packets = try await s.pipeline.nextPackets() {
            for p in packets {
                try Task.checkCancellation()
                let end = p.time + Double(p.samples) / 48_000
                if end <= discardBefore {
                    // Before the target: only the last stretch is decoded, to bring the decoder's state up to date.
                    if p.time >= discardBefore - 0.12 { _ = try? decoder.decode(p, keep: false) }
                    continue
                }
                // A hole in the timeline is concealed by the decoder (a short one) or skipped over (a long one).
                if let e = expected, p.time - e > 0.025 {
                    let missing = Int(((p.time - e) * 48_000 / Double(p.samples)).rounded())
                    if missing >= 1, missing <= 25 {
                        for _ in 0..<missing { if let c = try? decoder.conceal(samples: p.samples) { try await queue(c, ring) } }
                    }
                }
                var buffer: AVAudioPCMBuffer?
                do { buffer = try decoder.decode(p); failures = 0 } catch {
                    failures += 1
                    if failures > 25 { throw error }
                    buffer = try? decoder.conceal(samples: p.samples)
                }
                expected = end
                guard var b = buffer else { continue }
                var time = p.time
                if time < discardBefore, discardBefore > 0 {
                    let drop = min(Int(b.frameLength), Int(((discardBefore - time) * 48_000).rounded()))
                    if let t = trimmed(b, dropping: drop) { b = t; time = discardBefore } else { continue }
                }
                if !announced {
                    announced = true
                    ring.rebaseIfEmpty(time)
                    await firstSoundHook()
                }
                try await queue(b, ring)
            }
        }
    }

    nonisolated private static func queue(_ b: AVAudioPCMBuffer, _ ring: MusicOpusRing) async throws {
        while !ring.write(b) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    nonisolated private static func trimmed(_ b: AVAudioPCMBuffer, dropping n: Int) -> AVAudioPCMBuffer? {
        let left = Int(b.frameLength) - n
        guard left > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(left)),
              let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
        for c in 0..<Int(b.format.channelCount) { dst[c].update(from: src[c] + n, count: left) }
        out.frameLength = AVAudioFrameCount(left)
        return out
    }
}
