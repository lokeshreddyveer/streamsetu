import Foundation
import Accelerate
import AVFoundation

// Turns a plan into sound. The maths (faders, filter sweeps, headroom, envelope baking) is plain and tested; the engine part runs two
// decks on one AVAudioEngine so both start on the same sample.
//
// Faders are baked into the decoded audio before it is scheduled, so they are sample-exact and cannot stutter. Only the filter sweeps
// (which need a live filter) are driven by a small timer that follows the decks' own render clock.

// MARK: curves

enum MusicAutomixCurves {
    static let openLowPass = 20_000.0
    static let openHighPass = 20.0
    /// Where the bass lives: below this, only one deck is allowed to be heard at a time once the swap has happened.
    static let bassCorner = 220.0

    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smoothstep(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }

    /// Equal-power faders: out^2 + in^2 is 1 everywhere, so the blend has no dip in the middle. `shape` below 1 raises the middle of both
    /// curves (both songs a little louder at the crossing), and `headroomTrim` then takes the excess back off.
    static func faders(progress p: Double, shape: Double = 1) -> (out: Double, in: Double) {
        let t = clamp01(p) * Double.pi / 2
        let s = max(0.5, min(1, shape))
        return (pow(max(0, cos(t)), s), pow(max(0, sin(t)), s))
    }

    /// 1 / sqrt(power), never above 1: when two faders add up to more than unit power the sum is scaled back so it cannot clip.
    static func headroomTrim(out: Double, in i: Double) -> Double {
        1 / max(1, (out * out + i * i).squareRoot())
    }

    /// Interpolation between two frequencies in equal ratios (pitch is logarithmic, so a sweep in Hz would sound lopsided).
    static func geometric(_ a: Double, _ b: Double, _ t: Double) -> Double {
        guard a > 0, b > 0 else { return a }
        return a * pow(b / a, clamp01(t))
    }

    /// 0 before the swap window, 1 after it, smooth between. The window is `width` of the overlap long and ends at `swapAt`.
    static func handover(progress p: Double, swapAt: Double, width: Double) -> Double {
        let w = max(0.001, width)
        return smoothstep((p - (swapAt - w)) / w)
    }

    struct Frame: Equatable, Sendable {
        var outGain = 1.0, inGain = 0.0
        var outHighPass = MusicAutomixCurves.openHighPass, inHighPass = MusicAutomixCurves.openHighPass
        var outLowPass = MusicAutomixCurves.openLowPass, inLowPass = MusicAutomixCurves.openLowPass
    }

    /// The faders and filters at `progress` (0...1 through the overlap).
    static func frame(plan: MusicMixPlan, style: MusicAutomixStyle, progress p: Double) -> Frame {
        let shape = style == .club ? 0.8 : 1.0
        let f = faders(progress: p, shape: shape)
        let trim = headroomTrim(out: f.out, in: f.in)
        var fr = Frame()
        fr.outGain = f.out * trim
        fr.inGain = f.in * trim
        let h = handover(progress: p, swapAt: plan.bassSwapAt, width: plan.bassSwapWidth)
        fr.outHighPass = geometric(openHighPass, bassCorner, h)
        switch plan.kind {
        case .beatMatched:
            fr.inHighPass = geometric(bassCorner, openHighPass, h)
            // The outgoing song stays fully open for the first 40% and then closes gently to 3 kHz: shallow on purpose.
            fr.outLowPass = p < 0.4 ? openLowPass : geometric(openLowPass, 3_000, (p - 0.4) / 0.6)
        case .filterRide:
            // Tempos that cannot be matched are hidden by filtering instead: the outgoing song closes toward 500 Hz early (front-loaded) while
            // the incoming one opens from a 1.2 kHz high-pass, and the bass still changes hands once.
            fr.outLowPass = geometric(openLowPass, 500, pow(clamp01(p), 0.75))
            let entry = geometric(1_200, openHighPass, smoothstep(p / 0.7))
            fr.inHighPass = max(entry, geometric(bassCorner, openHighPass, h))
        }
        return fr
    }

    /// Outgoing fade-in at the join with the player's own sound, so the two never add up to a click (about 30 ms).
    static let joinSeconds = 0.03
    /// The incoming deck fades out over this long as the player takes over (the player fades in over the same time).
    static let handoverSeconds = 0.04
}

// MARK: baking

enum MusicAutomixBake {
    /// A per-sample gain curve built from `value` evaluated every 64 samples and joined by straight lines.
    static func envelope(frameCount: Int, sampleRate: Double, startTime: Double = 0, value: (Double) -> Double) -> [Float] {
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount)
        let step = 64
        var i = 0
        var prev = Float(value(startTime))
        while i < frameCount {
            let end = min(frameCount, i + step)
            let next = Float(value(startTime + Double(end) / sampleRate))
            let len = end - i
            for k in 0..<len { out[i + k] = prev + (next - prev) * Float(k) / Float(len) }
            prev = next
            i = end
        }
        return out
    }

    /// Multiplies every channel of `channels` by `gain`, in place.
    static func apply(_ gain: [Float], to channels: inout [[Float]]) {
        for c in channels.indices {
            let n = min(gain.count, channels[c].count)
            guard n > 0 else { continue }
            channels[c].withUnsafeMutableBufferPointer { dst in
                gain.withUnsafeBufferPointer { g in
                    guard let d = dst.baseAddress, let gp = g.baseAddress else { return }
                    vDSP_vmul(d, 1, gp, 1, d, 1, vDSP_Length(n))
                }
            }
            if channels[c].count > n { for k in n..<channels[c].count { channels[c][k] = 0 } }
        }
    }

    /// Gain of the outgoing deck at `t` real seconds into the overlap: its fader, then silence after the overlap.
    static func outgoingGain(plan: MusicMixPlan, style: MusicAutomixStyle, at t: Double) -> Double {
        guard t < plan.overlap else { return 0 }
        return MusicAutomixCurves.frame(plan: plan, style: style, progress: t / plan.overlap).outGain
    }

    /// A short rise from silence over the first `joinSeconds` of whatever a deck plays first, so joining the player's own sound never clicks.
    static func joinFade(_ t: Double) -> Double { min(1, max(0, t / MusicAutomixCurves.joinSeconds)) }

    /// Gain of the incoming deck at `m` incoming-file seconds after its cue: its fader while the overlap lasts, 1 after, and a short fade-out
    /// over the last `handoverSeconds` before `endMedia`.
    static func incomingGain(plan: MusicMixPlan, style: MusicAutomixStyle, atMedia m: Double, endMedia: Double) -> Double {
        let mediaOverlap = plan.overlap * plan.inRate
        var g = 1.0
        if m < mediaOverlap {
            g = MusicAutomixCurves.frame(plan: plan, style: style, progress: m / max(0.001, mediaOverlap)).inGain
        }
        // The deck keeps playing for one handover length past `endMedia` while the player's own sound fades in over the same stretch.
        let tail = endMedia + MusicAutomixCurves.handoverSeconds - m
        if tail < MusicAutomixCurves.handoverSeconds {
            let t = MusicAutomixCurves.clamp01(tail / MusicAutomixCurves.handoverSeconds)
            g *= sin(t * Double.pi / 2)
        }
        return g
    }
}

// MARK: decoding a short region

struct MusicRegionAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum MusicRegionDecoder {
    static let sampleRate = 44_100.0
    static var format: AVAudioFormat? { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) }

    enum DecodeError: Error { case noAudio, failed(String) }

    /// Decodes `duration` seconds from `start` as 44.1 kHz stereo float. The reader converts any source format and rate.
    static func decode(_ url: URL, start: Double, duration: Double) async throws -> MusicRegionAudio {
        guard let format, duration > 0 else { throw DecodeError.failed("bad region") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DecodeError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(output) else { throw DecodeError.failed("unsupported audio") }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.failed(reader.error?.localizedDescription ?? "cannot start reading") }
        let capacity = AVAudioFrameCount(duration * sampleRate) + 4_096
        guard let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity), let wholeData = whole.floatChannelData else { throw DecodeError.failed("no memory") }
        var written: AVAudioFrameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, written + frames <= capacity, let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let pieceData = piece.floatChannelData else { continue }
            piece.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: piece.mutableAudioBufferList) == noErr else { continue }
            for c in 0..<2 { memcpy(wholeData[c] + Int(written), pieceData[c], Int(frames) * MemoryLayout<Float>.size) }
            written += frames
        }
        if reader.status == .failed { throw DecodeError.failed(reader.error?.localizedDescription ?? "read failed") }
        guard written > 0 else { throw DecodeError.failed("empty region") }
        whole.frameLength = written
        return MusicRegionAudio(buffer: whole)
    }
}

// MARK: the two-deck engine

@MainActor
final class MusicAutomixRenderer {
    struct Started: Sendable {
        /// Host time at which both decks sound their first sample.
        var startHost: UInt64
        /// Real seconds of the overlap that were skipped because the start was late.
        var skipped: Double
        /// Host time at which the incoming deck has played up to its hand-over point.
        var handoverHost: UInt64
    }

    enum RenderError: Error { case notPrepared, engine(String) }

    private final class Deck {
        let node = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let mixer = AVAudioMixerNode()
    }

    private let engine = AVAudioEngine()
    private let out = Deck()
    private let inc = Deck()
    private let limiter: AVAudioUnitEffect
    private var built = false
    private var plan: MusicMixPlan?
    private var style: MusicAutomixStyle = .smooth
    private var outAudio: MusicRegionAudio?
    private var inAudio: MusicRegionAudio?
    private var started: Started?
    private var skippedMedia = 0.0
    private var control: Task<Void, Never>?
    private var lastEaseUnit = -1

    /// Called on the main actor when the incoming deck reaches its hand-over point.
    var onHandover: (@MainActor () -> Void)?

    init() {
        var d = AudioComponentDescription()
        d.componentType = kAudioUnitType_Effect
        d.componentSubType = kAudioUnitSubType_PeakLimiter
        d.componentManufacturer = kAudioUnitManufacturer_Apple
        limiter = AVAudioUnitEffect(audioComponentDescription: d)
    }

    var isRunning: Bool { started != nil }

    /// Real seconds of audio that must be decoded before the incoming deck can run to its hand-over point.
    static func incomingRegion(_ plan: MusicMixPlan) -> (start: Double, duration: Double) {
        (plan.inCue, (plan.handoverMedia - plan.inCue) + 0.5)
    }

    // MARK: prepare

    /// Decodes both regions and builds the graph. Nothing is audible yet.
    func prepare(plan: MusicMixPlan, style: MusicAutomixStyle, outgoingURL: URL, incomingURL: URL) async throws {
        stop(immediately: true)
        let o = try await MusicRegionDecoder.decode(outgoingURL, start: plan.outStart, duration: plan.overlap + 0.2)
        let region = Self.incomingRegion(plan)
        let i = try await MusicRegionDecoder.decode(incomingURL, start: region.start, duration: region.duration)
        try Task.checkCancellation()
        guard let format = MusicRegionDecoder.format else { throw RenderError.engine("no format") }
        try build(format: format)
        self.plan = plan; self.style = style; outAudio = o; inAudio = i
        inc.pitch.rate = Float(plan.inRate)
        out.pitch.rate = 1
        for d in [out, inc] { Self.openFilters(d.eq) }
        engine.prepare()
    }

    private func build(format: AVAudioFormat) throws {
        if !built {
            for d in [out, inc] {
                engine.attach(d.node); engine.attach(d.pitch); engine.attach(d.eq); engine.attach(d.mixer)
                engine.connect(d.node, to: d.pitch, format: format)
                engine.connect(d.pitch, to: d.eq, format: format)
                engine.connect(d.eq, to: d.mixer, format: format)
                engine.connect(d.mixer, to: engine.mainMixerNode, format: format)
                for (n, band) in d.eq.bands.enumerated() { band.filterType = n < 2 ? .highPass : .lowPass; band.bypass = true }
            }
            // The two decks meet at the main mixer; the limiter sits after it so a hot sum cannot clip.
            engine.attach(limiter)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: limiter, format: format)
            engine.connect(limiter, to: engine.outputNode, format: format)
            built = true
        }
        engine.mainMixerNode.outputVolume = 1
    }

    private static func openFilters(_ eq: AVAudioUnitEQ) {
        for b in eq.bands { b.bypass = true }
    }

    private static func set(_ eq: AVAudioUnitEQ, highPass hp: Double, lowPass lp: Double, sampleRate: Double) {
        // Two cascaded 12 dB/octave bands per filter make 24 dB/octave. A filter at its open end is bypassed outright.
        let hpOn = hp > MusicAutomixCurves.openHighPass * 1.2
        let lpTop = min(MusicAutomixCurves.openLowPass, sampleRate * 0.45)
        let lpOn = lp < lpTop * 0.95
        for n in 0..<2 { eq.bands[n].bypass = !hpOn; if hpOn { eq.bands[n].frequency = Float(hp) } }
        for n in 2..<4 { eq.bands[n].bypass = !lpOn; if lpOn { eq.bands[n].frequency = Float(max(200, lp)) } }
    }

    /// The volume slider or mute moved while a mix is playing: both decks follow at once.
    func setLevel(_ level: Float) { out.mixer.outputVolume = level; inc.mixer.outputVolume = level }

    // MARK: begin

    /// Starts both decks together. `outgoingPosition` is where the player's own sound is now; the decks begin where it will be a moment later,
    /// and when the start is already late the first part of the overlap is skipped on both decks (the incoming one by the same stretch).
    func begin(outgoingPosition: Double, level: Float = 1) throws -> Started {
        guard let plan, let outAudio, let inAudio, let format = MusicRegionDecoder.format else { throw RenderError.notPrepared }
        let lead = 0.1
        let wait = plan.outStart - outgoingPosition
        let skip = max(0, lead - wait)               // the player is already inside the overlap by this much when the decks begin
        let startDelay = max(lead, wait)
        let sr = MusicRegionDecoder.sampleRate
        let outSkipFrames = Int(skip * sr)
        let inSkipFrames = Int(skip * plan.inRate * sr)
        guard let o = Self.prepared(outAudio.buffer, skipFrames: outSkipFrames, gain: { t in MusicAutomixBake.outgoingGain(plan: plan, style: self.style, at: t + skip) * MusicAutomixBake.joinFade(t) }, sampleRate: sr, format: format),
              let i = Self.prepared(inAudio.buffer, skipFrames: inSkipFrames, gain: { m in
                  MusicAutomixBake.incomingGain(plan: plan, style: self.style, atMedia: m + skip * plan.inRate, endMedia: plan.handoverMedia - plan.inCue) * MusicAutomixBake.joinFade(m)
              }, sampleRate: sr, format: format) else { throw RenderError.engine("no audio to play") }
        out.mixer.outputVolume = level; inc.mixer.outputVolume = level
        do { if !engine.isRunning { try engine.start() } } catch { throw RenderError.engine(error.localizedDescription) }
        out.node.scheduleBuffer(o, at: nil, options: [], completionHandler: nil)
        inc.node.scheduleBuffer(i, at: nil, options: [], completionHandler: nil)
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay)
        let when = AVAudioTime(hostTime: startHost)
        out.node.play(at: when)
        inc.node.play(at: when)
        let handoverWall = (plan.overlap - skip) + plan.easeSeconds
        let s = Started(startHost: startHost, skipped: skip, handoverHost: startHost + AVAudioTime.hostTime(forSeconds: max(0, handoverWall)))
        started = s
        skippedMedia = skip * plan.inRate
        lastEaseUnit = -1
        runControl(s)
        return s
    }

    /// A copy of `source` from `skipFrames` on, with `gain` (a function of seconds since the copy's start) baked in.
    private static func prepared(_ source: AVAudioPCMBuffer, skipFrames: Int, gain: (Double) -> Double, sampleRate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = Int(source.frameLength)
        let n = total - skipFrames
        guard n > 0, let data = source.floatChannelData, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let dst = copy.floatChannelData else { return nil }
        copy.frameLength = AVAudioFrameCount(n)
        var channels: [[Float]] = (0..<2).map { c in Array(UnsafeBufferPointer(start: data[c] + skipFrames, count: n)) }
        let env = MusicAutomixBake.envelope(frameCount: n, sampleRate: sampleRate, value: gain)
        MusicAutomixBake.apply(env, to: &channels)
        for c in 0..<2 { channels[c].withUnsafeBufferPointer { if let b = $0.baseAddress { memcpy(dst[c], b, n * MemoryLayout<Float>.size) } } }
        return copy
    }

    // MARK: control loop

    /// Follows the incoming deck's own render clock: sweeps the filters during the overlap, eases the tempo back afterwards and announces
    /// the hand-over. Twenty-five updates a second; nothing runs when no mix does.
    private func runControl(_ s: Started) {
        control?.cancel()
        control = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self, !Task.isCancelled, let plan = self.plan else { return }
                if mach_absolute_time() >= s.handoverHost {
                    self.finish()
                    return
                }
                guard let t = self.inc.node.lastRenderTime, let pt = self.inc.node.playerTime(forNodeTime: t), pt.sampleRate > 0 else { continue }
                let media = max(0, Double(pt.sampleTime) / pt.sampleRate) + self.skippedMedia
                let mediaOverlap = plan.overlap * plan.inRate
                if media < mediaOverlap {
                    let fr = MusicAutomixCurves.frame(plan: plan, style: self.style, progress: media / max(0.001, mediaOverlap))
                    Self.set(self.out.eq, highPass: fr.outHighPass, lowPass: fr.outLowPass, sampleRate: MusicRegionDecoder.sampleRate)
                    Self.set(self.inc.eq, highPass: fr.inHighPass, lowPass: fr.inLowPass, sampleRate: MusicRegionDecoder.sampleRate)
                } else {
                    Self.openFilters(self.out.eq); Self.openFilters(self.inc.eq)
                    if plan.easeUnits > 0, plan.inUnit > 0 {
                        let unit = Int((media - mediaOverlap) / plan.inUnit)
                        if unit != self.lastEaseUnit {
                            self.lastEaseUnit = unit
                            self.inc.pitch.rate = Float(MusicRateEase.rate(startRate: plan.inRate, unit: unit))
                        }
                    }
                }
            }
        }
    }

    private func finish() {
        // The incoming deck's own last 40 ms fade out as the player's fade in, so it is left running a moment before it is stopped.
        let handler = onHandover
        control?.cancel(); control = nil
        started = nil
        handler?()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.started == nil else { return }
            self.plan = nil; self.outAudio = nil; self.inAudio = nil
            self.halt()
        }
    }

    // MARK: stop

    /// Stops both decks. A stop that is not immediate waits a few milliseconds behind a volume drop so it never clicks.
    func stop(immediately: Bool) {
        control?.cancel(); control = nil
        let wasRunning = started != nil
        started = nil
        plan = nil; outAudio = nil; inAudio = nil
        guard built else { return }
        if wasRunning, !immediately {
            engine.mainMixerNode.outputVolume = 0
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000)
                self?.halt()
            }
        } else {
            halt()
        }
    }

    private func halt() {
        out.node.stop(); inc.node.stop()
        out.node.reset(); inc.node.reset()
        inc.pitch.rate = 1
        if engine.isRunning { engine.pause() }
        engine.mainMixerNode.outputVolume = 1
    }
}
