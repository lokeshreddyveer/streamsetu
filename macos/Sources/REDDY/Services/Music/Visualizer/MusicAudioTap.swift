import Foundation
import AVFoundation
import MediaToolbox
import os

// A read-only copy of the audio that is playing, for the visualizers. It exists only while a visualizer is on screen: with none visible nothing is attached, nothing is copied
// and no work is done. The copy never changes the sound and never leaves the app. Three sources feed it (AVPlayer items, the effects engine, the Opus engine); each pushes
// the latest stereo samples into one small ring.

final class MusicAudioTap: @unchecked Sendable {
    static let shared = MusicAudioTap()
    static let capacity = 8192

    private var lock = os_unfair_lock_s()
    private var left = [Float](repeating: 0, count: capacity)
    private var right = [Float](repeating: 0, count: capacity)
    private var write = 0
    private var rate = 44100.0
    private var active = false

    var isActive: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return active }
    func setActive(_ on: Bool) {
        os_unfair_lock_lock(&lock); active = on
        if !on { for i in 0..<Self.capacity { left[i] = 0; right[i] = 0 } }
        os_unfair_lock_unlock(&lock)
    }

    /// Called from audio threads. Non-interleaved or mono input is fine; returns at once when no visualizer is on.
    func push(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>?, frames: Int, sampleRate: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard active, frames > 0 else { return }
        rate = sampleRate
        for i in 0..<min(frames, Self.capacity) {
            left[write] = l[i]; right[write] = (r ?? l)[i]
            write = (write + 1) % Self.capacity
        }
    }

    /// The most recent `count` frames, oldest first.
    func latest(_ count: Int) -> (left: [Float], right: [Float], sampleRate: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(count, Self.capacity)
        var l = [Float](repeating: 0, count: n), r = l
        var idx = (write - n + Self.capacity) % Self.capacity
        for i in 0..<n { l[i] = left[idx]; r[i] = right[idx]; idx = (idx + 1) % Self.capacity }
        return (l, r, rate)
    }

    // MARK: AVPlayer items

    /// The format the tap was prepared with. One lives in each tap's storage pointer.
    private final class Storage { var sampleRate = 44100.0; var interleaved = true; var channels = 2; var isFloat = true }

    /// An audio mix that copies the item's audio into the ring. The sound passes through untouched.
    @MainActor
    static func mix(for item: AVPlayerItem) async -> AVAudioMix? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return nil }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: { _, _, out in out.pointee = Unmanaged.passRetained(Storage()).toOpaque() },
            finalize: { tap in Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let st = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                st.sampleRate = format.pointee.mSampleRate
                st.interleaved = format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                st.channels = Int(format.pointee.mChannelsPerFrame)
                st.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                guard MusicAudioTap.shared.isActive else { return }
                let f = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard f.isFloat else { return }
                let list = UnsafeMutableAudioBufferListPointer(bufferList)
                let n = Int(framesOut.pointee)
                if f.interleaved, let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self), f.channels >= 1 {
                    var l = [Float](repeating: 0, count: n), r = l
                    for i in 0..<n { l[i] = p[i * f.channels]; r[i] = p[i * f.channels + (f.channels > 1 ? 1 : 0)] }
                    l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in MusicAudioTap.shared.push(left: lp.baseAddress!, right: rp.baseAddress, frames: n, sampleRate: f.sampleRate) } }
                } else if let a = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                    let b = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
                    MusicAudioTap.shared.push(left: a, right: b, frames: n, sampleRate: f.sampleRate)
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let t = tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = t
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: engines

    /// Puts or removes a tap on an engine's main mixer. Safe to call repeatedly.
    static func setEngineTap(_ engine: AVAudioEngine, on: Bool) {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        guard on else { return }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard MusicAudioTap.shared.isActive, let ch = buffer.floatChannelData else { return }
            MusicAudioTap.shared.push(left: ch[0], right: buffer.format.channelCount > 1 ? ch[1] : nil, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        }
    }
}
