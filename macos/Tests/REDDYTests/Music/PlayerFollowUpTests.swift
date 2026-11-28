import Testing
import Foundation
import AVFoundation
@testable import REDDY

// Everything here runs without audio hardware: the reverb is checked against a direct reference and through an offline engine render.

private func direct(_ ir: [Float], _ x: [Float], delay: Int) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    for n in 0..<x.count {
        let m = n - delay
        guard m >= 0 else { continue }
        var acc: Float = 0
        for k in 0..<min(ir.count, m + 1) { acc += ir[k] * x[m - k] }
        y[n] = acc
    }
    return y
}

private func runConvolver(_ c: MusicChannelConvolver, _ x: [Float], chunks: [Int]) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    var done = 0, i = 0
    while done < x.count {
        let n = min(chunks[i % chunks.count], x.count - done); i += 1
        x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { yp in c.process(xp.baseAddress! + done, yp.baseAddress! + done, frames: n) } }
        done += n
    }
    return y
}

/// Time for the response to fall 60 dB, read from the backward-integrated energy between -5 and -25 dB (a T20 measurement, times three).
private func measuredRT60(_ h: [Float], sampleRate: Double) -> Double {
    var edc = [Double](repeating: 0, count: h.count)
    var sum = 0.0
    for i in stride(from: h.count - 1, through: 0, by: -1) { sum += Double(h[i]) * Double(h[i]); edc[i] = sum }
    let total = edc[0]
    func db(_ i: Int) -> Double { 10 * log10(max(1e-30, edc[i] / total)) }
    guard let a = (0..<h.count).first(where: { db($0) <= -5 }), let b = (0..<h.count).first(where: { db($0) <= -25 }), b > a else { return 0 }
    return Double(b - a) / sampleRate * 3
}

@Suite("Reverb impulse responses")
struct ReverbIRTests {
    @Test(arguments: MusicReverbRoom.allCases) func lengthAndDecayMatchTheRequest(_ room: MusicReverbRoom) {
        for decay in [room.naturalDecay, 0.5, 2.5] {
            let spec = MusicReverbSpec(room: room, decay: decay)
            let h = MusicReverbIR.synthesise(spec, channel: 0, sampleRate: 48_000)
            let expected = (room.profile.firstReflectionMs / 1000 + 1.5 * decay) * 48_000
            #expect(Double(h.count) <= expected + 1 && Double(h.count) > expected * 0.5)
            let t60 = measuredRT60(h, sampleRate: 48_000)
            #expect(abs(t60 - decay) / decay < 0.25, "room \(room) decay \(decay) measured \(t60)")
        }
    }

    @Test func eachChannelHasUnitEnergyAndNoNaN() {
        for room in MusicReverbRoom.allCases {
            for ch in 0..<2 {
                let h = MusicReverbIR.synthesise(MusicReverbSpec(room: room, decay: room.naturalDecay, dampingHz: 20_000), channel: ch, sampleRate: 44_100)
                #expect(h.allSatisfy { $0.isFinite })
                let e = h.reduce(0.0) { $0 + Double($1) * Double($1) }
                #expect(abs(e - 1) < 0.01)
            }
        }
    }

    @Test func discreteReflectionsLandAtTheirDelays() {
        let spec = MusicReverbSpec(room: .largeRoom, decay: 1.1)
        let taps = MusicReverbIR.discreteReflections(spec, channel: 0, sampleRate: 48_000)
        let multiples: [Double] = [1.0, 1.6, 2.4, 3.7]
        let wanted: [Int] = multiples.map { (m: Double) -> Int in Int((22.0 * m / 1000.0 * 48_000.0).rounded()) }
        let got: [Int] = taps.map { $0.frame }
        #expect(got == wanted)
        #expect(taps.map(\.gain) == [0.7, -0.5, 0.35, -0.25])
        let right = MusicReverbIR.discreteReflections(spec, channel: 1, sampleRate: 48_000)
        #expect(right[0].frame - taps[0].frame == 48)
        #expect(MusicReverbIR.discreteReflections(MusicReverbSpec(room: .plate, decay: 1.8), channel: 0, sampleRate: 48_000).isEmpty)
        // In the response itself the first two taps keep their sign and stand out from their neighbours.
        let h = MusicReverbIR.synthesise(MusicReverbSpec(room: .smallRoom, decay: 0.4, dampingHz: 20_000), channel: 0, sampleRate: 48_000)
        let t = MusicReverbIR.discreteReflections(MusicReverbSpec(room: .smallRoom, decay: 0.4, dampingHz: 20_000), channel: 0, sampleRate: 48_000)
        #expect(h[t[0].frame] > 0 && h[t[1].frame] < 0)
        // Nothing sounds before the first reflection.
        #expect(h[0..<t[0].frame].allSatisfy { $0 == 0 })
    }

    @Test func preDelayReflectionsAndDampingShapeTheResponse() {
        let base = MusicReverbIR.synthesise(MusicReverbSpec(room: .mediumHall, decay: 1.8, dampingHz: 20_000), channel: 0, sampleRate: 48_000)
        let late = MusicReverbIR.synthesise(MusicReverbSpec(room: .mediumHall, decay: 1.8, preDelayMs: 50, dampingHz: 20_000), channel: 0, sampleRate: 48_000)
        #expect(MusicReverbIR.leadingSilence(late) - MusicReverbIR.leadingSilence(base) == 2400)
        let none = MusicReverbIR.synthesise(MusicReverbSpec(room: .mediumHall, decay: 1.8, dampingHz: 20_000, reflections: 0), channel: 0, sampleRate: 48_000)
        #expect(none[0..<3840].allSatisfy { $0 == 0 })
        #expect(none[4000..<4800] == base[4000..<4800])
        let dark = MusicReverbIR.synthesise(MusicReverbSpec(room: .mediumHall, decay: 1.8, dampingHz: 800), channel: 0, sampleRate: 48_000)
        func roughness(_ h: [Float]) -> Double { zip(h.dropFirst(), h).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(h.reduce(0.0) { $0 + Double(abs($1)) }) }
        #expect(roughness(dark) < roughness(base) * 0.6)
    }

    @Test func settingsMapToASpec() {
        var r = MusicReverbSettings(); r.preset = 5; r.decay = 3.2; r.preDelay = 12; r.damping = 4000; r.reflections = 40
        #expect(MusicReverbSpec(r) == MusicReverbSpec(room: .largeHall, decay: 3.2, preDelayMs: 12, dampingHz: 4000, reflections: 40))
    }
}

@Suite("Partitioned convolution")
struct ConvolverTests {
    private func noise(_ n: Int, seed: UInt64, scale: Float = 1) -> [Float] {
        var r = SplitMix(seed: seed)
        return (0..<n).map { _ in Float(r.nextUniform()) * scale }
    }

    @Test func matchesADirectReferenceWithHeadAndTail() {
        var ir = [Float](repeating: 0, count: 20_000)
        let tail = noise(19_700, seed: 5, scale: 0.1)
        for i in 0..<tail.count { ir[300 + i] = tail[i] }
        let c = MusicChannelConvolver(ir: ir)
        #expect(c.advance == 256)
        let x = noise(30_000, seed: 9)
        let y = runConvolver(c, x, chunks: [100, 256, 513, 1000, 77])
        let ref = direct(ir, x, delay: 256 - c.advance)
        let worst = zip(y, ref).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 5e-4, "max error \(worst)")
    }

    @Test func aResponseThatStartsEarlyIsOnlyLateByTheMissingFrames() {
        var ir = [Float](repeating: 0, count: 5000)
        let body = noise(4900, seed: 3, scale: 0.2)
        for i in 0..<body.count { ir[100 + i] = body[i] }
        let c = MusicChannelConvolver(ir: ir)
        #expect(c.advance == 100)
        let x = noise(9000, seed: 4)
        let y = runConvolver(c, x, chunks: [64, 300])
        let ref = direct(ir, x, delay: 256 - c.advance)
        #expect((zip(y, ref).map { abs($0 - $1) }.max() ?? 1) < 5e-4)
    }

    @Test func clearForgetsTheTail() {
        let ir = noise(8000, seed: 1, scale: 0.1).enumerated().map { $0.offset < 300 ? 0 : $0.element }
        let c = MusicChannelConvolver(ir: ir)
        var x = [Float](repeating: 0, count: 4096); x[0] = 1
        _ = runConvolver(c, x, chunks: [256])
        c.clear()
        let silent = runConvolver(c, [Float](repeating: 0, count: 4096), chunks: [256])
        #expect(silent.allSatisfy { $0 == 0 })
    }
}

@Suite("Reverb kernel")
struct ReverbKernelTests {
    private func render(_ k: MusicReverbKernel, seconds: Double, rate: Double, frames: Int = 512, input: (Int) -> Float) -> (l: [Float], r: [Float]) {
        let total = Int(seconds * rate)
        var inL = [Float](repeating: 0, count: total), outL = inL, outR = inL
        for i in 0..<total { inL[i] = input(i) }
        var done = 0
        while done < total {
            let n = min(frames, total - done)
            inL.withUnsafeBufferPointer { ip in outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
                k.process(inL: ip.baseAddress! + done, inR: ip.baseAddress! + done, outL: lp.baseAddress! + done, outR: rp.baseAddress! + done, frames: n)
            } } }
            done += n
        }
        return (outL, outR)
    }

    private func kernel(_ spec: MusicReverbSpec, rate: Double) -> MusicReverbKernel {
        let k = MusicReverbKernel(sampleRate: rate)
        k.allocate(maxFrames: 4096, sampleRate: rate)
        k.requestNow(spec)
        return k
    }

    @Test func tenSecondsOfStereoRunsFarFasterThanRealTime() {
        for decay in [3.2, 10.0] {
            let k = kernel(MusicReverbSpec(room: .largeHall, decay: decay), rate: 48_000)
            var rng = SplitMix(seed: 77)
            let start = ContinuousClock.now
            let out = render(k, seconds: 10, rate: 48_000) { _ in Float(rng.nextUniform()) * 0.3 }
            let elapsed = start.duration(to: .now)
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            #expect(out.l.allSatisfy { $0.isFinite } && out.r.allSatisfy { $0.isFinite })
            #expect(secs < 4, "decay \(decay): \(secs) s for 10 s of audio")
        }
    }

    @Test func impulseComesBackAsTheResponseAtTheRightTime() {
        let spec = MusicReverbSpec(room: .plate, decay: 1.8, preDelayMs: 10, dampingHz: 20_000)
        let k = kernel(spec, rate: 48_000)
        let out = render(k, seconds: 1, rate: 48_000, frames: 300) { $0 == 100 ? 1 : 0 }
        let h = MusicReverbIR.synthesise(spec, channel: 0, sampleRate: 48_000)
        let lead = MusicReverbIR.leadingSilence(h)
        // The wet impulse response starts `lead` frames after the impulse and equals the response from there.
        #expect(out.l[100..<(100 + lead - 1)].allSatisfy { abs($0) < 1e-6 })
        var worst: Float = 0
        for i in 0..<20_000 { worst = max(worst, abs(out.l[100 + i] - h[i])) }
        #expect(worst < 1e-3, "max error \(worst)")
    }

    @Test func inactiveIsSilentAndFlushDropsTheTail() {
        let k = kernel(MusicReverbSpec(room: .largeRoom, decay: 1.1), rate: 44_100)
        let first = render(k, seconds: 0.5, rate: 44_100) { $0 == 0 ? 1 : 0 }
        #expect(first.l.contains { abs($0) > 1e-4 })
        k.flush()
        let after = render(k, seconds: 0.5, rate: 44_100) { _ in 0 }
        #expect(after.l.allSatisfy { $0 == 0 })
        k.setActive(false)
        let off = render(k, seconds: 0.2, rate: 44_100) { _ in 0.5 }
        #expect(off.l.allSatisfy { $0 == 0 } && off.r.allSatisfy { $0 == 0 })
    }

    @Test func changingTheRoomMidStreamStaysFinite() {
        let k = kernel(MusicReverbSpec(room: .smallRoom, decay: 0.4), rate: 44_100)
        var rng = SplitMix(seed: 1)
        var all: [Float] = []
        for room in MusicReverbRoom.allCases {
            k.requestNow(MusicReverbSpec(room: room, decay: room.naturalDecay))
            let o = render(k, seconds: 0.3, rate: 44_100) { _ in Float(rng.nextUniform()) * 0.5 }
            all += o.l + o.r
        }
        #expect(all.allSatisfy { $0.isFinite && abs($0) < 50 })
    }

    @Test func theAudioUnitRunsInAnOfflineEngine() throws {
        guard let made = MusicReverbAudioUnit.makeNode() else { Issue.record("the unit could not be created"); return }
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let spec = MusicReverbSpec(room: .mediumRoom, decay: 0.7, dampingHz: 20_000)
        made.unit.kernel.requestNow(spec)
        let engine = AVAudioEngine()
        nonisolated(unsafe) var frame = 0
        let source = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for b in buffers {
                let p = b.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(count) { p[i] = (frame + i == 10) ? 1 : 0 }
            }
            frame += Int(count)
            return noErr
        }
        engine.attach(source); engine.attach(made.node)
        engine.connect(source, to: made.node, format: format)
        engine.connect(made.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var energy = 0.0
        var firstSound: Int?
        var rendered = 0
        while rendered < 22_050 {
            let status = try engine.renderOffline(1024, to: buffer)
            guard status == .success else { break }
            let p = try #require(buffer.floatChannelData)[0]
            for i in 0..<Int(buffer.frameLength) {
                energy += Double(p[i] * p[i])
                if firstSound == nil, abs(p[i]) > 1e-4 { firstSound = rendered + i }
            }
            rendered += Int(buffer.frameLength)
        }
        engine.stop()
        #expect(energy > 0.1)
        let h = MusicReverbIR.synthesise(spec, channel: 0, sampleRate: rate)
        let expected = 10 + MusicReverbIR.leadingSilence(h)
        #expect(abs((firstSound ?? 0) - expected) < 400)
    }
}

@Suite("Player follow-up")
struct PlayerFollowUpLogicTests {
    @Test func endlessPlaybackIsOnByDefault() throws {
        #expect(MusicSettings().endlessPlayback)
        #expect(try JSONDecoder().decode(MusicSettings.self, from: Data("{}".utf8)).endlessPlayback)
        // A saved explicit choice is respected.
        #expect(try !JSONDecoder().decode(MusicSettings.self, from: Data(#"{"endlessPlayback":false}"#.utf8)).endlessPlayback)
    }

    @Test func videoModeIsOffByDefaultAndOldFilesLoad() throws {
        #expect(!MusicPlayerPrefs().videoMode && !MusicPlayerPrefs().wavySeekBar)
        let p = try JSONDecoder().decode(MusicPlayerPrefs.self, from: Data("{}".utf8))
        #expect(!p.videoMode && !p.wavySeekBar)
        var on = MusicPlayerPrefs(); on.videoMode = true
        #expect(try JSONDecoder().decode(MusicPlayerPrefs.self, from: JSONEncoder().encode(on)).videoMode)
    }

    @Test @MainActor func streamSelectionTakesAPictureOnlyWhenAsked() {
        let audio = MusicStream(url: "https://x/a.m4a", codec: "aac", container: "m4a", bitrate: 128)
        let video = MusicStream(url: "https://x/v.mp4", codec: "aac", container: "mp4", bitrate: 128, hasVideo: true)
        #expect(MusicStreamResolver.pick(from: [video, audio], quality: .high)?.url == audio.url)
        #expect(MusicStreamResolver.pick(from: [audio, video], quality: .high, wantsVideo: true)?.url == video.url)
        // Nothing with a picture: sound is used even when video was wanted. Only a picture: it still plays.
        #expect(MusicStreamResolver.pick(from: [audio], quality: .high, wantsVideo: true)?.url == audio.url)
        #expect(MusicStreamResolver.pick(from: [video], quality: .high)?.url == video.url)
    }

    @Test func wheelStepsAreWholeAndSmoothed() {
        var w = MusicWheelVolume()
        let n1 = w.steps(delta: 1, precise: false), n2 = w.steps(delta: -3, precise: false), n3 = w.steps(delta: 40, precise: false)
        #expect(n1 == 1 && n2 == -3 && n3 == 4)
        var t = MusicWheelVolume()
        let a1 = t.steps(delta: 5, precise: true), a2 = t.steps(delta: 5, precise: true), a3 = t.steps(delta: 5, precise: true)
        #expect(a1 == 0 && a2 == 0 && a3 == 1)
        let back = t.steps(delta: -3, precise: true)
        #expect(back == 0 && t.carry == -3)
        let bad = t.steps(delta: .nan, precise: true)
        #expect(bad == 0)
        #expect(MusicWheelVolume.volume(from: 0.5, steps: 2) == 0.6)
        #expect(MusicWheelVolume.volume(from: 0.98, steps: 3) == 1)
        #expect(MusicWheelVolume.volume(from: 0.02, steps: -3) == 0)
    }

    @Test func windowedQueueCoversTheViewportAndKeepsItsHeight() {
        #expect(!MusicQueueWindow.isWindowed(rowCount: 200) && MusicQueueWindow.isWindowed(rowCount: 201))
        for heading in [nil, 0, 5, 450, 999] as [Int?] {
            let total = MusicQueueWindow.totalHeight(rowCount: 1000, headingAt: heading)
            for offset in [0, 1, 56 * 7.5, 20_000, total - 600, total] as [CGFloat] {
                let l = MusicQueueWindow.layout(rowCount: 1000, headingAt: heading, offset: offset, viewport: 600)
                let first = MusicQueueWindow.row(atOffset: offset, rowCount: 1000, headingAt: heading)
                let last = MusicQueueWindow.row(atOffset: offset + 600, rowCount: 1000, headingAt: heading)
                #expect(l.range.contains(first) && l.range.contains(last))
                #expect(l.range.lowerBound == max(0, first - 10) && l.range.upperBound == min(1000, last + 11))
                // Spacers plus the drawn rows (plus the heading when drawn) always add up to the whole list.
                let drawn = CGFloat(l.range.count) * 56 + (l.showHeading ? 40 : 0)
                let above = (heading.map { l.range.lowerBound > $0 } ?? false) ? 40 : 0
                #expect(abs(l.topPad + drawn + l.bottomPad - (total)) < 0.5 || abs(l.topPad + drawn + l.bottomPad + CGFloat(above) - total) < 0.5)
                #expect(l.range.count < 80)
            }
        }
        #expect(MusicQueueWindow.rowY(10, headingAt: 5) == 600 && MusicQueueWindow.rowY(4, headingAt: 5) == 224)
    }

    @Test func foreignDragsAreNotOurs() {
        let ours = MusicDragKind.queueRow.identifier
        #expect(MusicDragGuard.isOurs(typeIdentifiers: [ours, "public.utf8-plain-text"], ours: ours))
        #expect(!MusicDragGuard.isOurs(typeIdentifiers: ["public.file-url", "public.url", "public.utf8-plain-text"], ours: ours))
        #expect(MusicDragGuard.row(inPayload: MusicDragGuard.payload(row: 7)) == 7)
        #expect(MusicDragGuard.row(inPayload: "https://example.com") == nil)
        #expect(MusicDragGuard.row(inPayload: MusicQueueDrag.mime + ":-3") == nil)
        #expect(MusicDragGuard.row(inPayload: MusicQueueDrag.mime + ":x") == nil)
    }

    @Test func marqueeRunsOnlyWhenItShould() {
        #expect(MusicMarqueeMath.overflows(textWidth: 200, boxWidth: 150) && !MusicMarqueeMath.overflows(textWidth: 100, boxWidth: 150))
        #expect(MusicMarqueeMath.offset(elapsed: 0.5, textWidth: 300) == 0)
        let after = MusicMarqueeMath.offset(elapsed: MusicMarqueeMath.dwell + 2, textWidth: 300)
        #expect(abs(after + 2 * MusicMarqueeMath.speed) < 0.01)
        // A full pass lands back on the start, so the loop is seamless.
        #expect(MusicMarqueeMath.offset(elapsed: MusicMarqueeMath.period(textWidth: 300), textWidth: 300) == 0)
        #expect(MusicMarqueeMath.shouldRun(overflowing: true, playing: true, onScreen: true, reduceMotion: false))
        #expect(!MusicMarqueeMath.shouldRun(overflowing: true, playing: false, onScreen: true, reduceMotion: false))
        #expect(!MusicMarqueeMath.shouldRun(overflowing: true, playing: true, onScreen: false, reduceMotion: false))
        #expect(!MusicMarqueeMath.shouldRun(overflowing: true, playing: true, onScreen: true, reduceMotion: true))
        #expect(!MusicMarqueeMath.shouldRun(overflowing: false, playing: true, onScreen: true, reduceMotion: false))
    }

    @Test func waveFollowsTheSpec() {
        #expect(MusicWaveMath.thumbGap == 3.5 + 2 + 2)
        #expect(MusicWaveMath.amplitude(playing: true, elapsed: 0, from: 0) == 0)
        #expect(MusicWaveMath.amplitude(playing: true, elapsed: 5, from: 0) == 2.8)
        #expect(MusicWaveMath.amplitude(playing: false, elapsed: 5, from: 2.8) == 0)
        #expect(abs(MusicWaveMath.amplitude(playing: true, elapsed: 0.15, from: 0) - 1.4) < 0.01)
        // The ends taper to a flat line and nothing moves with zero amplitude.
        #expect(MusicWaveMath.displacement(x: 0, end: 100, amplitude: 2.8, phase: 1) == 0)
        #expect(MusicWaveMath.displacement(x: 100, end: 100, amplitude: 2.8, phase: 1) == 0)
        #expect(MusicWaveMath.displacement(x: 50, end: 100, amplitude: 0, phase: 1) == 0)
        #expect(abs(MusicWaveMath.displacement(x: 37, end: 100, amplitude: 2.8, phase: 0.4)) <= 2.8)
        #expect(MusicWaveMath.steadyInterval > 0.04)
    }

    @Test @MainActor func zoomStepsAndPersistence() {
        let d = UserDefaults(suiteName: "zoomtests-\(UUID().uuidString)") ?? .standard
        let z = MusicZoom(defaults: d)
        #expect(z.scale == 1)
        z.zoomIn(); #expect(z.scale == 1.1)
        z.zoomOut(); z.zoomOut(); #expect(z.scale == 0.9)
        #expect(MusicZoom(defaults: d).scale == 0.9)
        z.reset(); #expect(z.scale == 1)
        for _ in 0..<20 { z.zoomIn() }
        #expect(z.scale == 2)
        for _ in 0..<20 { z.zoomOut() }
        #expect(z.scale == 0.7)
        #expect(MusicZoom.nearest(.nan) == 1 && MusicZoom.nearest(1.3) == 1.25)
    }

    @Test @MainActor func reloadChangesTheViewIdentity() {
        let r = MusicReload()
        let before = r.generation
        r.request()
        #expect(r.generation == before + 1)
    }

    @Test func keyTableHasZoomAndLeavesQuitAlone() {
        func key(_ c: String, code: UInt16 = 0, cmd: Bool = true, shift: Bool = false) -> MusicKeyEvent { MusicKeyEvent(character: c, keyCode: code, command: cmd, shift: shift) }
        #expect(MusicShortcutTable.action(for: key("=")) == .zoomIn)
        #expect(MusicShortcutTable.action(for: key("+", shift: true)) == .zoomIn)
        #expect(MusicShortcutTable.action(for: key("-")) == .zoomOut)
        #expect(MusicShortcutTable.action(for: key("0")) == .zoomReset)
        #expect(MusicShortcutTable.action(for: key("q")) == nil)
        #expect(MusicShortcutTable.action(for: key("", code: 96, cmd: false)) == .reload)
        #expect(MusicShortcutTable.action(for: key("f")) == nil)
        #expect(MusicShortcutTable.action(for: key("", code: 124)) == .next)
        #expect(MusicShortcutTable.action(for: key("k")) == .search)
        for a in [MusicShortcutAction.zoomIn, .zoomOut, .zoomReset] { #expect(!a.followsRoomHost) }
    }
}
