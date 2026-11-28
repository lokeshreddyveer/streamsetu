import Foundation
import AVFoundation
import AudioToolbox
import os

// The reverb as a small audio unit of our own. It outputs only the wet signal (the engine's dry and wet mixers set the levels), so
// "Dry", "Amount", pre-delay, damping, decay and reflections are all real. The audio thread takes no locks it could wait on and never allocates:
// new responses are built on a background queue and handed over through a mailbox that the audio thread only ever tries.

// MARK: kernel

/// Two programs (one convolver per channel) for one response.
final class MusicReverbProgram: @unchecked Sendable {
    let spec: MusicReverbSpec
    let sampleRate: Double
    let left: MusicChannelConvolver
    let right: MusicChannelConvolver

    init(spec: MusicReverbSpec, sampleRate: Double) {
        self.spec = spec; self.sampleRate = sampleRate
        left = MusicChannelConvolver(ir: MusicReverbIR.synthesise(spec, channel: 0, sampleRate: sampleRate))
        right = MusicChannelConvolver(ir: MusicReverbIR.synthesise(spec, channel: 1, sampleRate: sampleRate))
    }

    func clear() { left.clear(); right.clear() }
}

/// The audio-thread half. Everything `process` touches is allocated by `allocate` beforehand.
final class MusicReverbKernel: @unchecked Sendable {
    private struct Mailbox {
        var program: MusicReverbProgram?
        var flushToken = 0
        var active = true
    }

    /// Length of the cross-fade between an old and a new response, in frames.
    static let fadeFrames = 256

    private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
    private let builder = DispatchQueue(label: "music.reverb.build", qos: .userInitiated)
    private let buildState = OSAllocatedUnfairLock(initialState: BuildState())
    private struct BuildState { var wanted: MusicReverbSpec?; var generation = 0; var published: MusicReverbSpec?; var retained: [MusicReverbProgram] = [] }

    // Audio thread only.
    private var current: MusicReverbProgram?
    private var outgoing: MusicReverbProgram?
    private var fadeLeft = 0
    private var seenFlush = 0
    private var wasActive = true
    private var maxFrames = 0
    private var tmpL: UnsafeMutablePointer<Float>?
    private var tmpR: UnsafeMutablePointer<Float>?

    private(set) var sampleRate: Double

    init(sampleRate: Double = 44_100) { self.sampleRate = sampleRate }

    deinit { tmpL?.deallocate(); tmpR?.deallocate() }

    /// Called before rendering starts, off the audio thread.
    func allocate(maxFrames: Int, sampleRate: Double) {
        tmpL?.deallocate(); tmpR?.deallocate()
        self.maxFrames = max(1, maxFrames)
        tmpL = UnsafeMutablePointer<Float>.allocate(capacity: self.maxFrames)
        tmpR = UnsafeMutablePointer<Float>.allocate(capacity: self.maxFrames)
        if sampleRate != self.sampleRate {
            self.sampleRate = sampleRate
            if let s = buildState.withLock({ $0.wanted }) { request(s, force: true) }
        }
    }

    // MARK: control (any thread except the audio thread)

    /// Builds the response for `spec` on a background queue and hands it to the audio thread. A newer request makes an older one stop early.
    func request(_ spec: MusicReverbSpec, force: Bool = false) {
        let (gen, rate): (Int, Double) = buildState.withLock { s in
            if !force, s.wanted == spec, s.published == spec { return (-1, 0) }
            s.wanted = spec; s.generation += 1
            return (s.generation, sampleRate)
        }
        guard gen >= 0 else { return }
        builder.async { [self] in
            guard buildState.withLock({ $0.generation == gen }) else { return }
            let program = MusicReverbProgram(spec: spec, sampleRate: rate)
            guard buildState.withLock({ $0.generation == gen }) else { return }
            publish(program)
        }
    }

    /// Builds and publishes on the calling thread. For tests and for the first response before playback starts.
    func requestNow(_ spec: MusicReverbSpec) {
        let rate = sampleRate
        let program = MusicReverbProgram(spec: spec, sampleRate: rate)
        buildState.withLock { $0.wanted = spec; $0.generation += 1 }
        publish(program)
    }

    private func publish(_ p: MusicReverbProgram) {
        // The strong list guarantees the audio thread is never the one to free a program.
        buildState.withLock { s in
            s.published = p.spec
            s.retained.append(p)
            if s.retained.count > 4 { s.retained.removeFirst(s.retained.count - 4) }
        }
        mailbox.withLock { $0.program = p }
    }

    /// Drops the sound held in the room (a new song, a seek). The next frames start from silence.
    func flush() { mailbox.withLock { $0.flushToken += 1 } }

    /// An inactive kernel outputs silence and does no work. It forgets the room when it wakes up again.
    func setActive(_ on: Bool) { mailbox.withLock { $0.active = on } }

    // MARK: audio thread

    /// Wet output for `frames` stereo input frames. `outR` may alias nothing; mono callers pass the same pointer for both inputs.
    func process(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        var take = Mailbox()
        var got = false
        // Try only: if the control side holds the lock this render simply uses what it already has.
        if let m = mailbox.withLockIfAvailable({ $0 }) { take = m; got = true }
        if got {
            if let p = take.program, p !== current {
                outgoing = (wasActive && take.active) ? current : nil
                fadeLeft = outgoing == nil ? 0 : Self.fadeFrames
                current = p
                if outgoing == nil { p.clear() }
            }
            if take.flushToken != seenFlush {
                seenFlush = take.flushToken
                current?.clear(); outgoing = nil; fadeLeft = 0
            }
            if take.active != wasActive {
                wasActive = take.active
                if take.active { current?.clear(); outgoing = nil; fadeLeft = 0 }
            }
        }
        guard wasActive, let cur = current, let tl = tmpL, let tr = tmpR, frames <= maxFrames else {
            for i in 0..<frames { outL[i] = 0; outR[i] = 0 }
            return
        }
        cur.left.process(inL, outL, frames: frames)
        cur.right.process(inR, outR, frames: frames)
        if let og = outgoing, fadeLeft > 0 {
            let n = min(frames, fadeLeft)
            og.left.process(inL, tl, frames: n)
            og.right.process(inR, tr, frames: n)
            for i in 0..<n {
                let w = Float(fadeLeft - i) / Float(Self.fadeFrames)
                outL[i] = outL[i] * (1 - w) + tl[i] * w
                outR[i] = outR[i] * (1 - w) + tr[i] * w
            }
            fadeLeft -= n
            if fadeLeft == 0 { outgoing = nil }
        }
    }
}

// MARK: audio unit

/// Hands the unit that the framework just created back to the code that asked for it, without reading the deprecated node accessor.
private let handoff = OSAllocatedUnfairLock<MusicReverbAudioUnit?>(initialState: nil)

final class MusicReverbAudioUnit: AUAudioUnit, @unchecked Sendable {
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x4D52_5642, componentManufacturer: 0x5354_5355,
        componentFlags: 0, componentFlagsMask: 0)

    static let registered: Bool = {
        AUAudioUnit.registerSubclass(MusicReverbAudioUnit.self, as: description, name: "StreamSetu: Convolution reverb", version: 1)
        return true
    }()

    let kernel = MusicReverbKernel()
    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let inputList: UnsafeMutablePointer<AudioBufferList>
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private let outScratchL: UnsafeMutablePointer<Float>
    private let outScratchR: UnsafeMutablePointer<Float>
    private static let scratchFrames = 8192

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false) else {
            throw MusicEffectError.reverbUnavailable("no audio format")
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        let n = Self.scratchFrames
        inL = .allocate(capacity: n); inR = .allocate(capacity: n)
        outScratchL = .allocate(capacity: n); outScratchR = .allocate(capacity: n)
        for p in [inL, inR, outScratchL, outScratchR] { p.initialize(repeating: 0, count: n) }
        let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        inputList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        try super.init(componentDescription: componentDescription, options: options)
        inputBus.maximumChannelCount = 2; outputBus.maximumChannelCount = 2
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
        handoff.withLock { $0 = self }
    }

    deinit {
        for p in [inL, inR, outScratchL, outScratchR] { p.deallocate() }
        UnsafeMutableRawPointer(inputList).deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.allocate(maxFrames: min(Int(maximumFramesToRender), Self.scratchFrames), sampleRate: outputBus.format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let k = kernel, list = inputList
        let l = inL, r = inR, sl = outScratchL, sr = outScratchR
        let cap = Self.scratchFrames
        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= cap else { return kAudioUnitErr_TooManyFramesToProcess }
            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            list.pointee.mNumberBuffers = 2
            withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
                let buffers = UnsafeMutableBufferPointer(start: first, count: 2)
                buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: l)
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: r)
            }
            let status = pull(actionFlags, timestamp, frameCount, 0, list)
            guard status == noErr else { return status }
            // The pull may have pointed the buffers at the source's own memory.
            var srcL: UnsafePointer<Float> = UnsafePointer(l), srcR: UnsafePointer<Float> = UnsafePointer(r)
            withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
                let buffers = UnsafeMutableBufferPointer(start: first, count: 2)
                if let d = buffers[0].mData { srcL = UnsafePointer(d.assumingMemoryBound(to: Float.self)) }
                if let d = buffers[1].mData { srcR = UnsafePointer(d.assumingMemoryBound(to: Float.self)) }
            }
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            guard out.count > 0 else { return noErr }
            var dstL = sl, dstR = sr
            if let d = out[0].mData { dstL = d.assumingMemoryBound(to: Float.self) } else { out[0].mData = UnsafeMutableRawPointer(sl) }
            if out.count > 1 { if let d = out[1].mData { dstR = d.assumingMemoryBound(to: Float.self) } else { out[1].mData = UnsafeMutableRawPointer(sr) } }
            k.process(inL: srcL, inR: out.count > 1 ? srcR : srcL, outL: dstL, outR: dstR, frames: frames)
            for i in 0..<out.count { out[i].mDataByteSize = bytes }
            return noErr
        }
    }

    /// Creates the effect node, or nil when the system refuses the unit (the engine then keeps Apple's reverb).
    static func makeNode() -> (node: AVAudioUnitEffect, unit: MusicReverbAudioUnit)? {
        _ = registered
        handoff.withLock { $0 = nil }
        let node = AVAudioUnitEffect(audioComponentDescription: description)
        guard let unit = handoff.withLock({ $0 }) else { return nil }
        return (node, unit)
    }
}
