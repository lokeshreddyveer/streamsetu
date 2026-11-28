import Foundation
import AVFoundation

// Tempo, pitch and reverb for music. The values and the signal-path plan are plain data so they can be tested; the audio graph at the
// bottom is the only part that touches AVAudioEngine. Apple's time-pitch unit does the stretching: no third-party stretcher is linked.

// MARK: rooms

/// The six reverb rooms. Each has its own synthesised response (see `MusicReverbIR`) and, as a fallback, the Apple factory preset of the same name.
enum MusicReverbRoom: Int, CaseIterable, Codable, Sendable, Identifiable {
    case smallRoom = 1, mediumRoom, largeRoom, mediumHall, largeHall, plate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .smallRoom: "Small room"; case .mediumRoom: "Medium room"; case .largeRoom: "Large room"
        case .mediumHall: "Medium hall"; case .largeHall: "Large hall"; case .plate: "Plate"
        }
    }

    /// How long the room rings by itself, in seconds. Choosing a room sets the decay to this.
    var naturalDecay: Double {
        switch self {
        case .smallRoom: 0.4; case .mediumRoom: 0.7; case .largeRoom: 1.1
        case .mediumHall: 1.8; case .largeHall: 3.2; case .plate: 1.8
        }
    }

    var factoryPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom; case .mediumRoom: .mediumRoom; case .largeRoom: .largeRoom
        case .mediumHall: .mediumHall; case .largeHall: .largeHall; case .plate: .plate
        }
    }
}

// MARK: settings

enum MusicEffectError: Error, Equatable, LocalizedError, Sendable {
    case invalidValues
    case timePitchUnavailable
    case reverbUnavailable(String)
    case engineFailed(String)
    case tempoLockedInRoom

    var errorDescription: String? {
        switch self {
        case .tempoLockedInRoom: MusicEffectRoomRules.tempoLockedMessage
        case .invalidValues: "Invalid playback effect values"
        case .timePitchUnavailable: "Tempo and pitch adjustment aren't available in this build"
        case .reverbUnavailable(let why): "Reverb isn't available: \(why)"
        case .engineFailed(let why): "The audio effects could not start: \(why)"
        }
    }
}

struct MusicReverbSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// Room number 1...6.
    var preset = 3
    /// Level of the untouched signal, 0...100.
    var dry = 100.0
    /// Level of the reverberant signal ("Amount"), 0...100.
    var wet = 25.0
    /// Nominal decay in seconds, 0.1...10.
    var decay = 1.1
    /// Delay of the wet path only, 0...200 ms.
    var preDelay = 0.0
    /// High cut on the wet path, 500...20000 Hz.
    var damping = 8000.0
    /// Level of the first 80 ms relative to the tail, 0...100 percent.
    var reflections = 100.0

    static let dryRange = 0.0...100.0
    static let wetRange = 0.0...100.0
    static let decayRange = 0.1...10.0
    static let preDelayRange = 0.0...200.0
    static let dampingRange = 500.0...20_000.0
    static let reflectionsRange = 0.0...100.0

    init() {}

    init(enabled: Bool = false, preset: Int = 3, dry: Double = 100, wet: Double = 25, decay: Double = 1.1,
         preDelay: Double = 0, damping: Double = 8000, reflections: Double = 100) {
        self.enabled = enabled; self.preset = preset; self.dry = dry; self.wet = wet
        self.decay = decay; self.preDelay = preDelay; self.damping = damping; self.reflections = reflections
    }

    private enum CodingKeys: String, CodingKey { case enabled, preset, dry, wet, decay, preDelay, damping, reflections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MusicReverbSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        preset = try c.decodeIfPresent(Int.self, forKey: .preset) ?? d.preset
        dry = try c.decodeIfPresent(Double.self, forKey: .dry) ?? d.dry
        wet = try c.decodeIfPresent(Double.self, forKey: .wet) ?? d.wet
        decay = try c.decodeIfPresent(Double.self, forKey: .decay) ?? d.decay
        preDelay = try c.decodeIfPresent(Double.self, forKey: .preDelay) ?? d.preDelay
        damping = try c.decodeIfPresent(Double.self, forKey: .damping) ?? d.damping
        reflections = try c.decodeIfPresent(Double.self, forKey: .reflections) ?? d.reflections
    }

    var room: MusicReverbRoom { MusicReverbRoom(rawValue: preset) ?? .largeRoom }

    /// The reverb is heard only when it is on and the wet level is above zero.
    var isAudible: Bool { enabled && wet > 0 }

    var isValid: Bool {
        MusicReverbRoom(rawValue: preset) != nil
            && Self.dryRange.contains(dry) && Self.wetRange.contains(wet) && Self.decayRange.contains(decay)
            && Self.preDelayRange.contains(preDelay) && Self.dampingRange.contains(damping) && Self.reflectionsRange.contains(reflections)
    }

    /// Integer fields must be whole numbers when a preset is read from disk.
    var integersAreWhole: Bool {
        [Double(preset), dry, wet, preDelay, damping, reflections].allSatisfy { $0.rounded() == $0 }
    }
}

struct MusicEffectSettings: Codable, Equatable, Sendable {
    /// Tempo (speed) 0.5...2 on a 0.05 grid in the UI.
    var speed = 1.0
    /// Pitch in semitones, -12...12, independent of tempo.
    var semitones = 0
    var reverb = MusicReverbSettings()

    static let speedRange = 0.5...2.0
    static let semitoneRange = -12...12
    static let speedStep = 0.05
    static let original = MusicEffectSettings()
    /// The speed steps offered for podcast episodes, sharing the same session tempo.
    static let podcastSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    init() {}

    init(speed: Double = 1, semitones: Int = 0, reverb: MusicReverbSettings = MusicReverbSettings()) {
        self.speed = speed; self.semitones = semitones; self.reverb = reverb
    }

    private enum CodingKeys: String, CodingKey { case speed, semitones, reverb }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        semitones = try c.decodeIfPresent(Int.self, forKey: .semitones) ?? 0
        reverb = try c.decodeIfPresent(MusicReverbSettings.self, forKey: .reverb) ?? MusicReverbSettings()
    }

    /// Rejects the whole set when any value is outside its range, NaN or infinite.
    func validate() throws {
        guard speed.isFinite, Self.speedRange.contains(speed), Self.semitoneRange.contains(semitones) else { throw MusicEffectError.invalidValues }
        let r = reverb
        guard [r.dry, r.wet, r.decay, r.preDelay, r.damping, r.reflections].allSatisfy(\.isFinite), r.isValid else { throw MusicEffectError.invalidValues }
    }

    var isValid: Bool { (try? validate()) != nil }
    var isOriginal: Bool { self == .original }

    /// True whenever something is set, so the effects button can stay lit and a forgotten setting is noticeable.
    var isActive: Bool { speed != 1 || semitones != 0 || reverb.enabled }

    /// 2^(n/12).
    var pitchFactor: Double { pow(2, Double(semitones) / 12) }

    /// Pitch and reverb need the audio-engine path; tempo alone stays on the plain player.
    var needsEngine: Bool { semitones != 0 || reverb.isAudible }

    /// Whether two settings sound the same. Reverb details are ignored while reverb is off or silent.
    func sameSound(as o: MusicEffectSettings) -> Bool {
        guard speed == o.speed, semitones == o.semitones else { return false }
        if !reverb.enabled && !o.reverb.enabled { return true }
        return reverb == o.reverb
    }

    /// Picking a room turns reverb on and resets the decay to that room's own length; every other reverb value stays.
    mutating func chooseRoom(_ room: MusicReverbRoom) {
        reverb.enabled = true
        reverb.preset = room.rawValue
        reverb.decay = room.naturalDecay
    }

    /// The same settings with tempo forced to normal (a listening room refuses tempo changes).
    func inRoom() -> MusicEffectSettings { var s = self; s.speed = 1; return s }

    /// "1.20x" or "Normal".
    static func speedLabel(_ s: Double) -> String { abs(s - 1) < 0.001 ? "Normal" : String(format: "%.2fx", s) }

    /// "+3", "-3" or "0".
    static func pitchLabel(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

    /// Snaps a tempo to the 0.05 grid inside 0.5...2.
    static func snappedSpeed(_ v: Double) -> Double {
        guard v.isFinite else { return 1 }
        return min(2, max(0.5, (v / speedStep).rounded() * speedStep))
    }
}

// MARK: signal path

/// What the audio graph is told to do, in order. Built from plain data so the order and the "never two stretchers" rule are testable.
enum MusicEffectStage: Equatable, Sendable {
    /// Loudness gain in dB; a boost carries a full-scale peak limiter.
    case gain(db: Double, limiter: Bool)
    /// The one time-stretch / pitch stage. `rate` is the tempo, `cents` the pitch.
    case timePitch(rate: Double, cents: Double)
    /// The reverb with its wet-path pre-delay and high cut; dry and wet are independent gains.
    case reverb(room: MusicReverbRoom, dry: Double, wet: Double, preDelayMs: Double, dampingHz: Double)
    /// A last full-scale limiter after the dry and wet paths are summed.
    case outputLimiter
}

enum MusicEffectsChain {
    /// Order: loudness gain, then tempo and pitch (only when not both neutral), then the reverb (only when audible), then a limiter.
    /// Tempo and pitch come before the room so its tail and pre-delay stay in listening seconds. Exactly one time-pitch stage ever exists.
    static func plan(_ s: MusicEffectSettings, gainDB: Double) -> [MusicEffectStage] {
        var out: [MusicEffectStage] = []
        if MusicLoudnessMath.isAudible(change: gainDB) { out.append(.gain(db: gainDB, limiter: MusicLoudnessMath.needsLimiter(gainDB: gainDB))) }
        if s.speed != 1 || s.semitones != 0 { out.append(.timePitch(rate: s.speed, cents: Double(s.semitones) * 100)) }
        if s.reverb.isAudible {
            let r = s.reverb
            out.append(.reverb(room: r.room, dry: r.dry, wet: r.wet, preDelayMs: r.preDelay, dampingHz: r.damping))
            out.append(.outputLimiter)
        }
        return out
    }
}

/// The settings that outlive a track: tempo, pitch and reverb are global to the player and last for the session only.
enum MusicEffectRoomRules {
    static let tempoLockedMessage = "Tempo cannot be changed during shared listening"
}

// MARK: the audio graph

/// An AVAudioEngine chain: player node, gain, time-pitch, dry and wet reverb paths, a limiter and the volume. It decodes the media itself
/// and schedules about two seconds of audio ahead. Used only while pitch or reverb is on; plain playback and tempo-only listening stay on
/// AVPlayer. Main-actor owned; the decode loop runs on its own queue and talks back through a locked token.
@MainActor
final class MusicEffectsEngine {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let gainMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private let preDelay = AVAudioUnitDelay()
    /// Our own convolution reverb. When the system refuses to create it, Apple's reverb and delay take its place.
    private let custom: (node: AVAudioUnitEffect, unit: MusicReverbAudioUnit)?
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let sumMixer = AVAudioMixerNode()
    private let limiter: AVAudioUnitEffect
    /// Equalizer between the loudness gain and the tempo stage, and the widener that runs on the decoded buffers.
    private let eq = MusicEqualizerUnit()
    private let widener = MusicSpatialWidener()
    private(set) var equalizer = MusicEqualizerSettings()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
    private var built = false
    private var customPrimed = false
    private var feeder: PCMFeeder?
    private var baseSeconds: TimeInterval = 0
    private var paused = false
    private(set) var settings = MusicEffectSettings.original
    private(set) var gainDB = 0.0
    private let decodeQueue = DispatchQueue(label: "music.effects.decode", qos: .userInitiated)

    /// Called on the main actor when every scheduled buffer has been played, with the token of the load that produced it.
    var onFinished: (@MainActor (Int) -> Void)?
    /// Called when decoding fails; the player falls back to its plain path.
    var onFailed: (@MainActor (Int, String) -> Void)?
    private var token = 0

    init() {
        var d = AudioComponentDescription()
        d.componentType = kAudioUnitType_Effect
        d.componentSubType = kAudioUnitSubType_PeakLimiter
        d.componentManufacturer = kAudioUnitManufacturer_Apple
        limiter = AVAudioUnitEffect(audioComponentDescription: d)
        custom = MusicReverbAudioUnit.makeNode()
    }

    /// True when decay, pre-delay, damping and early reflections are applied; false on the Apple fallback, which can only pick a room.
    var hasFullReverb: Bool { custom != nil }

    var isRunning: Bool { engine.isRunning }

    #if os(macOS)
    /// Points this engine's output at the device with this uid (nil is the system output). False when it would not open.
    @discardableResult func setOutputDevice(uid: String?) -> Bool { MusicCoreAudioOutputs.assign(uid: uid, to: engine) }
    #endif

    /// Seconds into the file that the listener is at now.
    var position: TimeInterval {
        guard let t = node.lastRenderTime, t.isSampleTimeValid, let p = node.playerTime(forNodeTime: t), p.sampleRate > 0 else { return baseSeconds }
        return baseSeconds + max(0, Double(p.sampleTime) / p.sampleRate)
    }

    /// Starts `asset` at `start` file seconds. Throws when the graph cannot be built or started.
    func start(asset: AVURLAsset, at start: TimeInterval, settings s: MusicEffectSettings, equalizer eqSettings: MusicEqualizerSettings = MusicEqualizerSettings(), gainDB: Double, volume: Float, playing: Bool, token: Int) throws {
        try s.validate()
        try eqSettings.validate()
        self.token = token
        stopFeeding()
        try build()
        try configure(s, gainDB: gainDB)
        try configureEqualizer(eqSettings)
        engine.mainMixerNode.outputVolume = volume
        baseSeconds = max(0, start)
        paused = !playing
        node.stop()
        node.reset()
        // Whatever the room was still ringing with belongs to the previous song or position.
        custom?.unit.kernel.flush()
        let f = PCMFeeder(asset: asset, start: baseSeconds, format: format, node: node, queue: decodeQueue, token: token, widener: widener)
        f.onDrained = { [weak self] t in Task { @MainActor in self?.drained(t) } }
        f.onFailed = { [weak self] t, why in Task { @MainActor in self?.failed(t, why) } }
        feeder = f
        if !engine.isRunning { engine.prepare(); do { try engine.start() } catch { throw MusicEffectError.engineFailed(error.localizedDescription) } }
        f.begin()
        if playing { node.play() }
    }

    func pause() { paused = true; if node.isPlaying { node.pause() } }

    func resume() {
        paused = false
        if !engine.isRunning { try? engine.start() }
        node.play()
    }

    func stop() {
        stopFeeding()
        node.stop()
        if engine.isRunning { engine.pause() }
    }

    func setVolume(_ v: Float) { engine.mainMixerNode.outputVolume = v }
    /// The visualizer copy of the output (see MusicAudioTap).
    func setVisualizerTap(_ on: Bool) { MusicAudioTap.setEngineTap(engine, on: on) }

    /// Changes the loudness gain live. Anything under 0.05 dB is no change at all.
    func setGain(db: Double) {
        guard MusicLoudnessMath.isAudible(change: db - gainDB) || (db == 0) != (gainDB == 0) else { return }
        gainDB = db
        applyGain()
    }

    /// Applies new settings as one unit. When anything fails, the previous settings are put back and the error is thrown, so a rejected
    /// change never leaves a half-applied chain.
    func apply(_ s: MusicEffectSettings) throws {
        try s.validate()
        guard built else { settings = s; return }
        let previous = settings
        do { try configure(s, gainDB: gainDB) } catch {
            try? configure(previous, gainDB: gainDB)
            throw error
        }
    }

    /// Applies a new equalizer curve and widening as one unit. A failure puts the previous curve back and throws.
    func applyEqualizer(_ e: MusicEqualizerSettings) throws {
        try e.validate()
        let previous = equalizer
        do { try configureEqualizer(e) } catch {
            try? configureEqualizer(previous)
            throw error
        }
    }

    // MARK: private

    private func configureEqualizer(_ e: MusicEqualizerSettings) throws {
        try eq.apply(e)
        widener.set(e)
        equalizer = e
        if built { applyGain() }
    }

    private func drained(_ t: Int) { if t == token, feeder != nil { onFinished?(t) } }
    private func failed(_ t: Int, _ why: String) { if t == token { onFailed?(t, why) } }

    private func stopFeeding() {
        feeder?.cancel()
        feeder = nil
    }

    private func build() throws {
        guard !built else { return }
        let wetNodes: [AVAudioNode] = custom.map { [$0.node] } ?? [reverb, preDelay]
        for n in ([node, gainMixer, eq.unit, timePitch, dryMixer, wetMixer, sumMixer, limiter] as [AVAudioNode]) + wetNodes { engine.attach(n) }
        engine.connect(node, to: gainMixer, format: format)
        engine.connect(gainMixer, to: eq.unit, format: format)
        engine.connect(eq.unit, to: timePitch, format: format)
        let wetHead: AVAudioNode = custom?.node ?? reverb
        engine.connect(timePitch, to: [AVAudioConnectionPoint(node: dryMixer, bus: 0), AVAudioConnectionPoint(node: wetHead, bus: 0)], fromBus: 0, format: format)
        if let custom {
            engine.connect(custom.node, to: wetMixer, format: format)
        } else {
            engine.connect(reverb, to: preDelay, format: format)
            engine.connect(preDelay, to: wetMixer, format: format)
        }
        engine.connect(dryMixer, to: sumMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(wetMixer, to: sumMixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(sumMixer, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        reverb.wetDryMix = 100
        preDelay.wetDryMix = 100
        preDelay.feedback = 0
        built = true
    }

    private func configure(_ s: MusicEffectSettings, gainDB g: Double) throws {
        guard built else { settings = s; return }
        // Tempo and pitch: one Apple time-pitch unit. Bypassed outright when both are neutral.
        timePitch.rate = Float(s.speed)
        timePitch.pitch = Float(Double(s.semitones) * 100)
        timePitch.bypass = s.speed == 1 && s.semitones == 0
        // Reverb. Ours convolves with a response built from every setting (room, decay, pre-delay, damping, reflections); the wet mixer
        // sets the Amount and the dry mixer the Dry level. The fallback is Apple's room preset plus a delay for pre-delay and high cut.
        let r = s.reverb
        if let custom {
            custom.unit.kernel.setActive(r.isAudible)
            if r.isAudible {
                // The first response is built here so the room is there from the first frame; later changes build in the background.
                if customPrimed { custom.unit.kernel.request(MusicReverbSpec(r)) } else { custom.unit.kernel.requestNow(MusicReverbSpec(r)); customPrimed = true }
            }
        } else {
            reverb.loadFactoryPreset(r.room.factoryPreset)
            reverb.bypass = !r.isAudible
            preDelay.delayTime = r.preDelay / 1000
            preDelay.lowPassCutoff = Float(r.damping)
            preDelay.bypass = !r.isAudible
        }
        dryMixer.outputVolume = r.isAudible ? Float(r.dry / 100) : 1
        wetMixer.outputVolume = r.isAudible ? Float(r.wet / 100) : 0
        settings = s
        gainDB = g
        applyGain()
    }

    private func applyGain() {
        gainMixer.outputVolume = MusicLoudnessMath.isAudible(change: gainDB) ? MusicLoudnessMath.engineAmplitude(gainDB: gainDB) : 1
        // The limiter sits in the chain only when something can exceed full scale: a boost, or dry plus wet summed.
        limiter.bypass = !(MusicLoudnessMath.needsLimiter(gainDB: gainDB) || settings.reverb.isAudible || equalizer.needsEngine)
    }
}

// MARK: decode loop

/// Reads PCM from the media and keeps about two seconds scheduled on the player node. Runs on its own queue; the lock-protected flag is how
/// the main actor cancels it.
private final class PCMFeeder: @unchecked Sendable {
    private let asset: AVURLAsset
    private let start: TimeInterval
    private let format: AVAudioFormat
    private let node: AVAudioPlayerNode
    private let queue: DispatchQueue
    private let token: Int
    private let lock = NSLock()
    private var cancelled = false
    private let slots = DispatchSemaphore(value: 4)
    private let widener: MusicSpatialWidener
    var onDrained: (@Sendable (Int) -> Void)?
    var onFailed: (@Sendable (Int, String) -> Void)?

    init(asset: AVURLAsset, start: TimeInterval, format: AVAudioFormat, node: AVAudioPlayerNode, queue: DispatchQueue, token: Int, widener: MusicSpatialWidener) {
        self.widener = widener
        self.asset = asset; self.start = start; self.format = format; self.node = node; self.queue = queue; self.token = token
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        // Free the loop if it is waiting for a slot.
        for _ in 0..<8 { slots.signal() }
    }

    func begin() {
        queue.async { [self] in
            do { try run() } catch { if !isCancelled { onFailed?(token, error.localizedDescription) } }
        }
    }

    private func run() throws {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [AVAssetTrack] = []
        let asset = self.asset
        Task.detached { tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []; sem.signal() }
        sem.wait()
        guard let track = tracks.first else { throw MusicEffectError.engineFailed("no audio track") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: Int(format.channelCount),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicEffectError.engineFailed("cannot read this media") }
        reader.add(output)
        guard reader.startReading() else { throw MusicEffectError.engineFailed(reader.error?.localizedDescription ?? "cannot start reading") }
        while !isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            if buffer.format.channelCount == 2, let ch = buffer.floatChannelData { widener.process(left: ch[0], right: ch[1], frames: Int(frames)) }
            slots.wait()
            if isCancelled { break }
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [slots] _ in slots.signal() }
        }
        if isCancelled { reader.cancelReading(); return }
        if reader.status == .failed { throw MusicEffectError.engineFailed(reader.error?.localizedDescription ?? "read failed") }
        // A short silent tail marks the end: when it has played, everything before it has too.
        if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) {
            tail.frameLength = 64
            let t = token, done = onDrained
            node.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in done?(t) }
        }
    }
}
