import Testing
import Foundation
@testable import REDDY

// Automix, the equalizer and the analysis-driven fade, all checked on synthetic audio and plain data: click tracks at known tempos, tones,
// silence gaps. Nothing here opens an audio device or a network connection.

enum SyntheticAudio {
    static let rate = 22_050.0

    /// A click at every beat (a 1.5 kHz burst over a 60 Hz thump), the first of each four louder, starting at `offset` seconds.
    static func clicks(bpm: Double, seconds: Double, offset: Double = 0.2, accent: Bool = true) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * rate))
        let period = 60 / bpm
        var t = offset, k = 0
        while t < seconds - 0.1 {
            let s = Int(t * rate)
            let amp: Float = accent && k % 4 != 0 ? 0.5 : 1
            for i in 0..<1_500 where s + i < x.count {
                let e = Float(exp(-Double(i) / 150))
                x[s + i] += amp * e * (0.5 * Float(sin(2 * Double.pi * 1_500 * Double(i) / rate)) + 0.5 * Float(sin(2 * Double.pi * 60 * Double(i) / rate)))
            }
            t += period; k += 1
        }
        return x
    }

    /// Clicks whose tempo glides from `from` to `to` BPM; returns the true click times as well.
    static func drifting(from a: Double, to b: Double, seconds: Double) -> (samples: [Float], times: [Double]) {
        var x = [Float](repeating: 0, count: Int(seconds * rate))
        var times: [Double] = []
        var t = 0.3
        while t < seconds - 0.2 {
            times.append(t)
            let s = Int(t * rate)
            for i in 0..<1_500 where s + i < x.count { x[s + i] += Float(exp(-Double(i) / 150)) * Float(sin(2 * Double.pi * 1_500 * Double(i) / rate)) }
            t += 60 / (a + (b - a) * t / seconds)
        }
        return (x, times)
    }

    static func chord(_ freqs: [Double], seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in Float(freqs.reduce(0.0) { $0 + sin(2 * Double.pi * $1 * Double(i) / rate) } * 0.15) }
    }

    /// A hand-built analysis with a perfect grid, for planner tests.
    static func analysis(bpm: Double, confidence: Double = 0.9, duration: Double = 200, contentEnd: Double? = nil, key: (Int, Bool)? = nil,
                         audibleStart: Double = 0.5, energy: Float = 1) -> MusicTrackAnalysis {
        var a = MusicTrackAnalysis()
        a.duration = duration
        a.bpm = bpm
        a.confidence = confidence
        let beat = 60 / bpm
        a.beats = stride(from: audibleStart, to: duration, by: beat).map { ($0 * 1000).rounded() / 1000 }
        a.audibleStart = audibleStart
        a.contentEnd = contentEnd ?? duration - 1
        a.energy = [Float](repeating: energy, count: Int(duration / MusicBeatAnalyzer.energyStep))
        if let k = key { a.keyRoot = k.0; a.keyIsMinor = k.1; a.keyConfidence = 0.9 }
        (a.mixIn, a.mixOut) = MusicBeatAnalyzer.mixPoints(a)
        return a
    }
}

@Suite("Automix analysis") struct AutomixAnalysisTests {
    @Test(arguments: [90.0, 100, 120, 128, 140, 150, 170])
    func tempoOfAccentedClickTracksIsWithinOneBPM(bpm: Double) {
        let a = MusicBeatAnalyzer.analyze(samples: SyntheticAudio.clicks(bpm: bpm, seconds: 40), sampleRate: SyntheticAudio.rate)
        #expect(abs(a.bpm - bpm) < 1, "expected \(bpm), got \(a.bpm)")
        #expect(a.confidence > 0.6)
        #expect(a.hasGrid)
    }

    @Test(arguments: [80.0, 110, 125])
    func tempoOfPlainClickTracksIsWithinOneBPM(bpm: Double) {
        let a = MusicBeatAnalyzer.analyze(samples: SyntheticAudio.clicks(bpm: bpm, seconds: 40, accent: false), sampleRate: SyntheticAudio.rate)
        #expect(abs(a.bpm - bpm) < 1, "expected \(bpm), got \(a.bpm)")
    }

    @Test func beatGridLocksToTheClicksAndKeepsLockWhenTheTempoDrifts() {
        let steady = MusicBeatAnalyzer.analyze(samples: SyntheticAudio.clicks(bpm: 120, seconds: 40, offset: 0.37), sampleRate: SyntheticAudio.rate)
        #expect(abs((steady.beats.first ?? -1) - 0.37) < 0.03)
        for (i, b) in steady.beats.enumerated() {
            let ideal = 0.37 + Double(i) * 0.5
            #expect(abs(b - ideal) < 0.03, "beat \(i) is \(b), ideal \(ideal)")
        }
        let d = SyntheticAudio.drifting(from: 118, to: 124, seconds: 60)
        let drift = MusicBeatAnalyzer.analyze(samples: d.samples, sampleRate: SyntheticAudio.rate)
        #expect(drift.beats.count >= d.times.count - 2 && drift.beats.count <= d.times.count + 1)
        // The first beats are still locking on; after that the grid stays within 40 ms of every real click.
        for b in drift.beats.dropFirst(3) {
            let nearest = d.times.min { abs($0 - b) < abs($1 - b) } ?? 0
            #expect(abs(nearest - b) < 0.04)
        }
    }

    @Test func downbeatIsTheLoudestOfFourBeats() {
        var x = SyntheticAudio.clicks(bpm: 120, seconds: 40, offset: 0.2)
        // Click track accents beats 0, 4, 8 ...; shift the whole track by one beat so the accent falls on beat index 3 of the detected grid.
        x = [Float](repeating: 0, count: Int(0.5 * SyntheticAudio.rate)) + x
        let a = MusicBeatAnalyzer.analyze(samples: x, sampleRate: SyntheticAudio.rate)
        // Whatever the first detected beat is, the downbeat must land on an accented click: beats at 0.7 + 2k s.
        let down = a.downbeats
        #expect(!down.isEmpty)
        #expect(down.allSatisfy { abs((($0 - 0.7) / 2) - (($0 - 0.7) / 2).rounded()) < 0.03 })
    }

    @Test func noiseAndSilenceHaveNoTrustedGrid() {
        let noise = (0..<Int(40 * SyntheticAudio.rate)).map { _ in Float.random(in: -0.3...0.3) }
        let a = MusicBeatAnalyzer.analyze(samples: noise, sampleRate: SyntheticAudio.rate)
        #expect(a.confidence < MusicAutomixPlanner.assistFloor)
        let silent = MusicBeatAnalyzer.analyze(samples: [Float](repeating: 0, count: Int(40 * SyntheticAudio.rate)), sampleRate: SyntheticAudio.rate)
        #expect(silent.failed)
        let tiny = MusicBeatAnalyzer.analyze(samples: [Float](repeating: 0.1, count: 1_000), sampleRate: SyntheticAudio.rate)
        #expect(tiny.failed)
    }

    @Test func keyOfAChordIsFound() {
        let c = MusicBeatAnalyzer.analyze(samples: SyntheticAudio.chord([261.63, 329.63, 392.0, 523.25], seconds: 30), sampleRate: SyntheticAudio.rate)
        #expect(c.keyRoot == 0 && !c.keyIsMinor)
        let a = MusicBeatAnalyzer.analyze(samples: SyntheticAudio.chord([110, 220, 261.63, 329.63, 440], seconds: 30), sampleRate: SyntheticAudio.rate)
        #expect(a.keyRoot == 9 && a.keyIsMinor)
    }

    @Test func silenceAtTheStartAndEndIsFound() {
        var x = SyntheticAudio.clicks(bpm: 120, seconds: 45)
        for i in 0..<Int(2 * SyntheticAudio.rate) { x[i] = 0 }
        for i in Int(30 * SyntheticAudio.rate)..<x.count { x[i] = 0 }
        let a = MusicBeatAnalyzer.analyze(samples: x, sampleRate: SyntheticAudio.rate)
        #expect(abs(a.audibleStart - 2.2) < 0.2)
        #expect(abs(a.contentEnd - 30) < 0.6)
        #expect(a.mixOut.contains { $0.kind == .contentEnd })
        #expect(a.mixIn.first?.kind == .firstBar)
    }

    @Test func aFadeOutIsAnOutro() {
        var x = SyntheticAudio.chord([220, 330], seconds: 40)
        for i in Int(30 * SyntheticAudio.rate)..<x.count { x[i] *= Float(max(0, 1 - (Double(i) / SyntheticAudio.rate - 30) / 10)) * 0.2 }
        let a = MusicBeatAnalyzer.analyze(samples: x, sampleRate: SyntheticAudio.rate)
        let outro = a.outroStart
        #expect(outro != nil && (outro ?? 0) > 29 && (outro ?? 0) < 36)
    }

    @Test func anUnreadableFileIsAFailedEntry() async {
        let a = await MusicBeatAnalyzer.analyze(url: URL(fileURLWithPath: "/nonexistent/song.m4a"))
        #expect(a.failed)
    }
}

@Suite("Automix cache") struct AutomixCacheTests {
    private func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("automix-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func storesAndReloadsAndRejectsAnotherLength() {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MusicAnalysisCache(directory: dir)
        let a = SyntheticAudio.analysis(bpm: 120)
        cache.store(a, trackUID: "x:1", duration: 200)
        #expect(MusicAnalysisCache(directory: dir).analysis(trackUID: "x:1", duration: 200) == a)
        #expect(cache.analysis(trackUID: "x:1", duration: 260) == nil)
        #expect(cache.count == 1 && cache.totalBytes > 0)
    }

    @Test func aStaleSchemaIsDeletedNotMigrated() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        var old = SyntheticAudio.analysis(bpm: 120)
        old.schema = MusicTrackAnalysis.schemaVersion - 1
        let key = MusicAnalysisCache.key(trackUID: "x:2", duration: 200)
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent(key + ".json"))
        let cache = MusicAnalysisCache(directory: dir)
        #expect(cache.analysis(trackUID: "x:2", duration: 200) == nil)
        #expect(cache.count == 0)
    }

    @Test func theOldestFilesGoWhenOverTheLimit() {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MusicAnalysisCache(directory: dir, limit: 3)
        for i in 0..<5 {
            cache.store(SyntheticAudio.analysis(bpm: 100 + Double(i)), trackUID: "x:\(i)", duration: 200)
            let key = MusicAnalysisCache.key(trackUID: "x:\(i)", duration: 200)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(i))], ofItemAtPath: dir.appendingPathComponent(key + ".json").path)
        }
        cache.prune()
        #expect(cache.count == 3)
        #expect(MusicAnalysisCache(directory: dir).analysis(trackUID: "x:0", duration: 200) == nil)
        #expect(MusicAnalysisCache(directory: dir).analysis(trackUID: "x:4", duration: 200) != nil)
        #expect(MusicAnalysisCache.maxEntries == 2_000)
        cache.clear()
        #expect(cache.count == 0)
    }

    @Test func pinnedFilesAreSkippedByEviction() {
        var index = MusicLRUIndex()
        index.insert(name: "a.m4a", size: 100, at: Date(timeIntervalSince1970: 1))
        index.insert(name: "b.m4a", size: 100, at: Date(timeIntervalSince1970: 2))
        index.insert(name: "c.m4a", size: 100, at: Date(timeIntervalSince1970: 3))
        #expect(index.evictionList(limit: 150, protectedStem: nil, alsoProtected: ["a"]) == ["b.m4a", "c.m4a"])
        #expect(index.evictionList(limit: 150, protectedStem: nil) == ["a.m4a", "b.m4a"])
    }
}

@Suite("Automix planner") struct AutomixPlannerTests {
    private func input(out: MusicTrackAnalysis? = SyntheticAudio.analysis(bpm: 120), inc: MusicTrackAnalysis? = SyntheticAudio.analysis(bpm: 124),
                       outFacts: MusicTrackFacts = MusicTrackFacts(title: "A", album: "X", artist: "P", duration: 200),
                       inFacts: MusicTrackFacts = MusicTrackFacts(title: "B", album: "Y", artist: "Q", duration: 200),
                       position: Double = 0, tempo: Double = 1, settings: MusicAutomixSettings = MusicAutomixSettings(enabled: true)) -> MusicAutomixInput {
        MusicAutomixInput(outgoing: outFacts, incoming: inFacts, outgoingAnalysis: out, incomingAnalysis: inc, position: position, listenerTempo: tempo, settings: settings)
    }

    private func isFallback(_ d: MusicAutomixDecision) -> Bool { if case .fallback = d { return true }; return false }
    private func isTrueEnd(_ d: MusicAutomixDecision) -> Bool { if case .trueEndFade = d { return true }; return false }

    @Test func offTempoAndShortSongsAreLeftAlone() {
        #expect(isFallback(MusicAutomixPlanner.decide(input(settings: MusicAutomixSettings(enabled: false)))))
        #expect(isFallback(MusicAutomixPlanner.decide(input(tempo: 1.25))))
        let short = MusicTrackFacts(title: "Skit", album: "", artist: "", duration: 30)
        #expect(isFallback(MusicAutomixPlanner.decide(input(outFacts: short))))
        #expect(isFallback(MusicAutomixPlanner.decide(input(outFacts: MusicTrackFacts()))))
    }

    @Test func spokenWordAndLiveRecordingsAreNeverMixed() {
        let talk = MusicTrackFacts(title: "Episode 12: Tape", album: "", artist: "", duration: 200)
        #expect(isFallback(MusicAutomixPlanner.decide(input(inFacts: talk))))
        let live = MusicTrackFacts(title: "Song (Live at the Hall)", album: "", artist: "", duration: 200)
        #expect(isFallback(MusicAutomixPlanner.decide(input(outFacts: live))))
        #expect(MusicAutomixPlanner.isLive(MusicTrackFacts(title: "x", album: "Live at Wembley", artist: "", duration: 1)))
        #expect(!MusicAutomixPlanner.isLive(MusicTrackFacts(title: "Live Forever", album: "Live It Up", artist: "Live", duration: 1)))
    }

    @Test func missingFailedOrWrongLengthAnalysisFallsBack() {
        #expect(isFallback(MusicAutomixPlanner.decide(input(out: nil))))
        #expect(isFallback(MusicAutomixPlanner.decide(input(out: .failedEntry(duration: 200)))))
        #expect(isFallback(MusicAutomixPlanner.decide(input(out: SyntheticAudio.analysis(bpm: 120, duration: 230)))))
        // The next song not being analysed still lets the current one fade at its real end.
        #expect(isTrueEnd(MusicAutomixPlanner.decide(input(inc: nil))))
        #expect(isTrueEnd(MusicAutomixPlanner.decide(input(inc: .failedEntry(duration: 200)))))
    }

    @Test func fadeOnlyStyleFadesAtTheTrueEnd() {
        let d = MusicAutomixPlanner.decide(input(out: SyntheticAudio.analysis(bpm: 120, contentEnd: 190), settings: MusicAutomixSettings(enabled: true, style: .fadeOnly)))
        #expect(d == .trueEndFade(contentEnd: 190, reason: "Fade style"))
        // No trailing silence: nothing to correct, the player's own path is used.
        #expect(isFallback(MusicAutomixPlanner.decide(input(out: SyntheticAudio.analysis(bpm: 120, contentEnd: 199.9), settings: MusicAutomixSettings(enabled: true, style: .fadeOnly)))))
    }

    @Test func noClearBeatMeansAPlainFadeAtTheEnd() {
        #expect(isTrueEnd(MusicAutomixPlanner.decide(input(out: SyntheticAudio.analysis(bpm: 120, confidence: 0.1), inc: SyntheticAudio.analysis(bpm: 124, confidence: 0.1)))))
        var noGrid = SyntheticAudio.analysis(bpm: 120); noGrid.bpm = 0; noGrid.beats = []
        #expect(isTrueEnd(MusicAutomixPlanner.decide(input(out: noGrid))))
    }

    @Test func closeTemposAreBeatMatchedOnBarLinesAndTheOutgoingSongIsNeverRetimed() throws {
        guard case .mix(let plan) = MusicAutomixPlanner.decide(input()) else { Issue.record("expected a mix"); return }
        #expect(plan.kind == .beatMatched)
        let window = MusicAutomixPlanner.stretchWindow(strength: 0.5)
        #expect(window.contains(plan.inRate))
        #expect(abs(plan.inRate - 120.0 / 124.0) < 0.0002)
        // The overlap is a whole number of the outgoing song's own bars (the outgoing song plays at speed 1 throughout).
        let bar = 4 * 0.5
        #expect(abs(plan.overlap / bar - (plan.overlap / bar).rounded()) < 1e-6)
        #expect(plan.overlap >= MusicAutomixPlanner.minOverlap && plan.overlap <= MusicAutomixPlanner.maxOverlap)
        // It starts on an outgoing bar line (bars at 0.5 + 2k) and ends before the file does.
        #expect(abs((plan.outStart - 0.5) / 2 - ((plan.outStart - 0.5) / 2).rounded()) < 0.01)
        #expect(plan.outEnd <= 199.5)
        #expect(plan.inCue < 200 * MusicAutomixPlanner.maxCueShare)
        #expect(plan.easeUnits > 0 && plan.handoverMedia > plan.inEnd)
        #expect(plan.bassSwapAt > 0.3 && plan.bassSwapAt <= 0.85)
    }

    @Test func aTempoTooFarApartBecomesAFilterBlendAtNormalSpeed() {
        guard case .mix(let plan) = MusicAutomixPlanner.decide(input(inc: SyntheticAudio.analysis(bpm: 140))) else { Issue.record("expected a mix"); return }
        #expect(plan.kind == .filterRide)
        #expect(plan.inRate == 1 && plan.easeUnits == 0)
    }

    @Test func halfAndDoubleTimeAreTheSamePulse() {
        let folded = MusicAutomixPlanner.fold(70, toward: 140)
        #expect(folded.bpm == 140 && folded.factor == 0.5)
        #expect(MusicAutomixPlanner.fold(180, toward: 90).bpm == 90)
        guard case .mix(let plan) = MusicAutomixPlanner.decide(input(out: SyntheticAudio.analysis(bpm: 140), inc: SyntheticAudio.analysis(bpm: 70))) else { Issue.record("expected a mix"); return }
        #expect(plan.kind == .beatMatched && abs(plan.inRate - 1) < 0.0001)
        #expect(abs(plan.inUnit - 60.0 / 70 * 0.5) < 1e-9)
    }

    @Test func clashingKeysShortenTheOverlap() {
        let c = SyntheticAudio.analysis(bpm: 120, key: (0, false)), fSharp = SyntheticAudio.analysis(bpm: 124, key: (6, false))
        let close = SyntheticAudio.analysis(bpm: 124, key: (7, false))
        guard case .mix(let clash) = MusicAutomixPlanner.decide(input(out: c, inc: fSharp)), case .mix(let fine) = MusicAutomixPlanner.decide(input(out: c, inc: close)) else {
            Issue.record("expected mixes"); return
        }
        #expect(clash.overlap < fine.overlap)
        #expect(clash.overlap <= 8 * 0.5 + 1e-9)
        #expect(!MusicAutomixPlanner.keysCompatible((0, false), (6, false)))
        #expect(MusicAutomixPlanner.keysCompatible((0, false), (9, true)))
        #expect(MusicAutomixPlanner.keysCompatible((0, false), (7, false)))
    }

    @Test func strengthSetsTheOverlapAndTheStretchWindow() {
        func overlap(_ s: Double) -> Double {
            if case .mix(let p) = MusicAutomixPlanner.decide(input(settings: MusicAutomixSettings(enabled: true, style: .smooth, strength: s))) { return p.overlap }
            return 0
        }
        #expect(overlap(0) < overlap(1))
        let g = MusicAutomixPlanner.stretchWindow(strength: 0), s = MusicAutomixPlanner.stretchWindow(strength: 1)
        #expect(g.upperBound < s.upperBound && g.lowerBound > s.lowerBound)
        // Speeding up is allowed further than slowing down.
        #expect(s.upperBound - 1 > 1 - s.lowerBound)
    }

    @Test func aBlendThatWouldThrowAwayTooMuchMusicWaitsForTheEnd() {
        var out = SyntheticAudio.analysis(bpm: 120)
        out.outroStart = 120
        (out.mixIn, out.mixOut) = MusicBeatAnalyzer.mixPoints(out)
        // The outro marker is 80 s before the end and the music is still loud, so leaving there would skip far more than 10 s.
        guard case .mix(let plan) = MusicAutomixPlanner.decide(input(out: out)) else { Issue.record("expected a mix"); return }
        #expect(plan.outEnd > 190)
    }

    @Test func aMixThatIsAlreadyLateFallsBackToAPlainFade() {
        #expect(isTrueEnd(MusicAutomixPlanner.decide(input(position: 197))))
    }

    @Test func settingsDecodeWithDefaultsAndClamp() throws {
        let d = try JSONDecoder().decode(MusicAutomixSettings.self, from: Data("{}".utf8))
        #expect(!d.enabled && d.style == .smooth && d.strength == 0.5)
        let c = try JSONDecoder().decode(MusicAutomixSettings.self, from: Data(#"{"enabled":true,"style":"nonsense","strength":9}"#.utf8))
        #expect(c.enabled && c.style == .smooth && c.strength == 1)
    }
}

@Suite("Automix renderer maths") struct AutomixRendererTests {
    private func plan(kind: MusicMixPlan.Kind = .beatMatched, rate: Double = 1.03) -> MusicMixPlan {
        MusicMixPlan(kind: kind, outStart: 100, overlap: 10, inCue: 4, inRate: rate, beatSeconds: 0.5, inUnit: 0.5, bassSwapAt: 0.7, bassSwapWidth: 0.2,
                     easeUnits: kind == .beatMatched ? 8 : 0, reasons: [])
    }

    @Test func equalPowerFadersSumToUnitPower() {
        for i in 0...20 {
            let f = MusicAutomixCurves.faders(progress: Double(i) / 20)
            #expect(abs(f.out * f.out + f.in * f.in - 1) < 1e-9)
        }
        let a = MusicAutomixCurves.faders(progress: 0), b = MusicAutomixCurves.faders(progress: 1)
        #expect(a.out == 1 && a.in == 0 && abs(b.out) < 1e-12 && b.in == 1)
    }

    @Test func headroomTrimKeepsAnythingLouderThanUnitPowerUnderUnit() {
        for i in 0...20 {
            let f = MusicAutomixCurves.faders(progress: Double(i) / 20, shape: 0.8)
            let t = MusicAutomixCurves.headroomTrim(out: f.out, in: f.in)
            #expect(t <= 1)
            #expect((f.out * t) * (f.out * t) + (f.in * t) * (f.in * t) <= 1 + 1e-9)
        }
        #expect(MusicAutomixCurves.headroomTrim(out: 0.5, in: 0.5) == 1)
    }

    @Test func filterSweepsGlideInEqualRatios() {
        #expect(abs(MusicAutomixCurves.geometric(20, 220, 0.5) - (20.0 * 220).squareRoot()) < 1e-9)
        #expect(MusicAutomixCurves.geometric(20, 220, 0) == 20 && abs(MusicAutomixCurves.geometric(20, 220, 1) - 220) < 1e-9)
    }

    @Test func theBassChangesHandsOnceAndOnlyOnce() {
        let p = plan()
        var lastOut = 0.0, lastIn = 1_000.0
        for i in 0...50 {
            let f = MusicAutomixCurves.frame(plan: p, style: .club, progress: Double(i) / 50)
            #expect(f.outHighPass >= lastOut - 1e-9 && f.inHighPass <= lastIn + 1e-9)
            lastOut = f.outHighPass; lastIn = f.inHighPass
        }
        let start = MusicAutomixCurves.frame(plan: p, style: .club, progress: 0), end = MusicAutomixCurves.frame(plan: p, style: .club, progress: 1)
        #expect(start.outHighPass == 20 && abs(start.inHighPass - 220) < 1e-6)
        #expect(abs(end.outHighPass - 220) < 1e-6 && abs(end.inHighPass - 20) < 1e-6)
        #expect(start.outGain == 1 && start.inGain == 0 && abs(end.outGain) < 1e-9 && abs(end.inGain - 1) < 1e-9)
    }

    @Test func aFilterBlendClosesTheOutgoingTopAndOpensTheIncomingBottom() {
        let p = plan(kind: .filterRide, rate: 1)
        let mid = MusicAutomixCurves.frame(plan: p, style: .smooth, progress: 0.5), end = MusicAutomixCurves.frame(plan: p, style: .smooth, progress: 1)
        #expect(mid.outLowPass < 6_000 && abs(end.outLowPass - 500) < 1)
        #expect(MusicAutomixCurves.frame(plan: p, style: .smooth, progress: 0).inHighPass >= 1_200 - 1e-6)
    }

    @Test func bakedFadersKeepThePowerConstantAtEverySample() {
        let sr = 44_100.0
        let n = Int(sr)
        let out = MusicAutomixBake.envelope(frameCount: n, sampleRate: sr) { MusicAutomixCurves.faders(progress: $0).out }
        let inc = MusicAutomixBake.envelope(frameCount: n, sampleRate: sr) { MusicAutomixCurves.faders(progress: $0).in }
        var ones: [[Float]] = [[Float](repeating: 1, count: n), [Float](repeating: 1, count: n)]
        MusicAutomixBake.apply(out, to: &ones)
        #expect(abs(Double(ones[0][n / 2]) - cos(Double.pi / 4)) < 0.01 && ones[1][0] > 0.99)
        for i in stride(from: 0, to: n, by: 997) { #expect(abs(Double(out[i] * out[i] + inc[i] * inc[i]) - 1) < 0.01) }
    }

    @Test func theIncomingDeckFadesInThroughTheOverlapThenOutAtTheHandover() {
        let p = plan()
        let endMedia = p.handoverMedia - p.inCue
        #expect(MusicAutomixBake.incomingGain(plan: p, style: .smooth, atMedia: 0, endMedia: endMedia) == 0)
        #expect(MusicAutomixBake.incomingGain(plan: p, style: .smooth, atMedia: p.overlap * p.inRate + 1, endMedia: endMedia) == 1)
        #expect(MusicAutomixBake.incomingGain(plan: p, style: .smooth, atMedia: endMedia + MusicAutomixCurves.handoverSeconds, endMedia: endMedia) < 1e-9)
        #expect(MusicAutomixBake.outgoingGain(plan: p, style: .smooth, at: p.overlap + 0.1) == 0)
        #expect(MusicAutomixBake.joinFade(0) == 0 && MusicAutomixBake.joinFade(1) == 1)
    }

    @Test func theTempoEasesBackOneUnitAtATimeAndLandsOnTheGrid() {
        let p = plan(rate: 1.04)
        #expect(MusicRateEase.rate(startRate: 1.04, unit: 0) == 1.04)
        #expect(MusicRateEase.rate(startRate: 1.04, unit: 4) < 1.04)
        #expect(MusicRateEase.rate(startRate: 1.04, unit: 100) == 1)
        #expect(MusicRateEase.rate(startRate: 0.96, unit: 100) == 1)
        // 8 units of 0.5 s of media, played at a rate a little over 1, take slightly less than 4 real seconds.
        #expect(p.easeSeconds < 4 && p.easeSeconds > 3.7)
        #expect(abs(p.handoverMedia - (p.inCue + p.overlap * 1.04 + 8 * 0.5)) < 1e-9)
    }
}

@Suite("Equalizer") struct EqualizerTests {
    @Test func sixteenValidPresetsWithOwnNamesAndModestGains() {
        #expect(MusicEqualizerPresets.all.count == 16)
        #expect(Set(MusicEqualizerPresets.all.map(\.id)).count == 16 && Set(MusicEqualizerPresets.all.map(\.title)).count == 16)
        for p in MusicEqualizerPresets.all {
            #expect(p.gains.count == 7)
            #expect(p.gains.allSatisfy { MusicEqualizerSettings.gainRange.contains($0) && abs($0) <= 6 })
            var s = MusicEqualizerSettings(); s.apply(p)
            #expect(s.isValid && s.presetID == p.id)
            #expect(MusicEqualizerMath.makeupGainDB(s) <= 0)
        }
        #expect(MusicEqualizerPresets.preset(id: "flat")?.gains.allSatisfy { $0 == 0 } == true)
    }

    @Test func aCustomCurveMatchesNoPreset() {
        #expect(MusicEqualizerPresets.matching([1, 2, 3, 4, 5, 6, 7]) == nil)
        #expect(MusicEqualizerPresets.matching(MusicEqualizerPresets.all[3].gains.map { $0 + 0.04 })?.id == "bassLift")
        #expect(MusicEqualizerPresets.matching([0, 0]) == nil)
    }

    @Test func invalidSettingsAreRejected() {
        var s = MusicEqualizerSettings()
        s.bands[2] = 13
        #expect(!s.isValid)
        s = MusicEqualizerSettings(); s.bands[0] = .nan
        #expect(!s.isValid)
        s = MusicEqualizerSettings(); s.padBass = 1.5
        #expect(!s.isValid)
        s = MusicEqualizerSettings(); s.bands = [0, 0, 0]
        #expect(!s.isValid)
        s = MusicEqualizerSettings(); s.spatial.amount = 2
        #expect(!s.isValid)
        #expect(MusicEqualizerSettings().isValid)
    }

    @Test func theResponseFollowsTheGains() {
        var s = MusicEqualizerSettings(); s.apply(MusicEqualizerPresets.preset(id: "bassLift") ?? MusicEqualizerPresets.all[0])
        #expect(MusicEqualizerMath.responseDB(s, at: 50) > 3)
        #expect(abs(MusicEqualizerMath.responseDB(s, at: 4_000)) < 1)
        #expect(MusicEqualizerMath.curve(s).count == 96)
        let flat = MusicEqualizerSettings()
        #expect(MusicEqualizerMath.curve(flat).allSatisfy { abs($0) < 1e-9 })
        #expect(MusicEqualizerMath.makeupGainDB(flat) == 0)
        #expect(MusicEqualizerMath.makeupGainDB(s) < 0 && MusicEqualizerMath.makeupGainDB(s) > -12)
    }

    @Test func theTonePadMovesTheShelvesAndNothingElse() {
        var s = MusicEqualizerSettings(); s.enabled = true; s.padBass = 1; s.padTreble = -1
        #expect(MusicEqualizerMath.responseDB(s, at: 40) > 6)
        #expect(MusicEqualizerMath.responseDB(s, at: 15_000) < -6)
        #expect(abs(MusicEqualizerMath.responseDB(s, at: 1_000)) < 1.5)
        #expect(s.needsEngine)
        let mapped = MusicEqualizerLogic.padValues(x: 1, y: 0)
        #expect(mapped.bass == 1 && mapped.treble == 1)
        let back = MusicEqualizerLogic.padPosition(bass: 0, treble: 0)
        #expect(back.x == 0.5 && back.y == 0.5)
    }

    @Test func offOrFlatNeedsNoEngine() {
        var s = MusicEqualizerSettings()
        #expect(!s.needsEngine)
        s.enabled = true
        #expect(!s.needsEngine)
        s.bands[3] = 4
        #expect(s.needsEngine)
        s.enabled = false
        #expect(!s.needsEngine)
        s.spatial.enabled = true
        #expect(s.needsEngine)
    }

    @Test func wideningLeavesMonoAloneAndGrowsTheSide() {
        let w = MusicSpatialWidener()
        w.set({ var s = MusicSpatialSettings(); s.enabled = true; s.amount = 1; return s }())
        var l = [Float](repeating: 0.5, count: 512), r = [Float](repeating: 0.5, count: 512)
        // Prime the glide, then check a mono buffer is unchanged.
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            if let a = lp.baseAddress, let b = rp.baseAddress { w.process(left: a, right: b, frames: 512) }
        } }
        #expect(l.allSatisfy { abs($0 - 0.5) < 1e-6 } && r.allSatisfy { abs($0 - 0.5) < 1e-6 })
        l = (0..<512).map { _ in 0.4 }; r = (0..<512).map { _ in -0.4 }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            if let a = lp.baseAddress, let b = rp.baseAddress { w.process(left: a, right: b, frames: 512) }
        } }
        #expect(abs(l[511] - 0.4 * Float(MusicSpatialWidener.sideGain(amount: 1))) < 1e-4 && abs(r[511] + l[511]) < 1e-6)
        #expect(MusicSpatialWidener.sideGain(amount: 0) == 1 && MusicSpatialWidener.sideGain(amount: 1) == 2.5)
    }

    @Test func settingsPersistWithTheirOwnDefaultsAndOldFilesStillLoad() throws {
        var prefs = MusicPlayerPrefs()
        prefs.equalizer.enabled = true
        prefs.equalizer.apply(MusicEqualizerPresets.all[5])
        prefs.equalizer.spatial.enabled = true
        prefs.automix = MusicAutomixSettings(enabled: true, style: .club, strength: 0.8)
        let back = try JSONDecoder().decode(MusicPlayerPrefs.self, from: JSONEncoder().encode(prefs))
        #expect(back == prefs)
        let old = try JSONDecoder().decode(MusicPlayerPrefs.self, from: Data(#"{"crossfadeLength":4}"#.utf8))
        #expect(old.equalizer == MusicEqualizerSettings() && old.automix == MusicAutomixSettings() && old.crossfadeLength == 4)
        let broken = try JSONDecoder().decode(MusicPlayerPrefs.self, from: Data(#"{"equalizer":{"bands":[1,2],"padBass":99}}"#.utf8))
        #expect(broken.equalizer.isValid)
    }
}

@Suite("Automix fallbacks") @MainActor struct AutomixControllerTests {
    private func track(_ id: String, seconds: Int64 = 200) -> MusicTrack {
        MusicTrack(id: id, providerID: "test", title: "Song \(id)", durationMs: seconds * 1000, artists: [])
    }

    private func controller() -> (MusicAutomixController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("automix-controller-\(UUID().uuidString)")
        return (MusicAutomixController(directory: dir), dir)
    }

    @Test func offMeansTheNormalPath() {
        let (c, dir) = controller(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = MusicTransitionQuery(current: track("a"), currentURL: nil, next: track("b"), nextURL: nil, position: 10, duration: 200, tempo: 1, settings: MusicAutomixSettings())
        #expect(c.advice(for: q) == .useDefault)
        #expect(c.statusText == "Off")
    }

    @Test func aStreamedSongOrMissingAnalysisMeansTheNormalPath() {
        let (c, dir) = controller(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = MusicTransitionQuery(current: track("a"), currentURL: nil, next: track("b"), nextURL: nil, position: 10, duration: 200, tempo: 1, settings: MusicAutomixSettings(enabled: true))
        #expect(c.advice(for: q) == .useDefault)
        #expect(c.statusText.contains("streamed"))
    }

    @Test func aCachedAnalysisOfTheCurrentSongGivesTheTrueEndFadeAndNothingElse() {
        let (c, dir) = controller(); defer { try? FileManager.default.removeItem(at: dir) }
        c.cache.store(SyntheticAudio.analysis(bpm: 120, contentEnd: 188), trackUID: track("a").uid, duration: 200)
        let q = MusicTransitionQuery(current: track("a"), currentURL: nil, next: track("b"), nextURL: nil, position: 10, duration: 200, tempo: 1,
                                     settings: MusicAutomixSettings(enabled: true, style: .fadeOnly))
        #expect(c.advice(for: q) == .fadeEnd(contentEnd: 188))
    }

    @Test func twoCachedAnalysesGiveAMixAndALateOneFallsBack() {
        let (c, dir) = controller(); defer { try? FileManager.default.removeItem(at: dir) }
        c.cache.store(SyntheticAudio.analysis(bpm: 120), trackUID: track("a").uid, duration: 200)
        c.cache.store(SyntheticAudio.analysis(bpm: 124), trackUID: track("b").uid, duration: 200)
        var q = MusicTransitionQuery(current: track("a"), currentURL: nil, next: track("b"), nextURL: nil, position: 10, duration: 200, tempo: 1, settings: MusicAutomixSettings(enabled: true))
        guard case .mix(let plan) = c.advice(for: q) else { Issue.record("expected a mix"); return }
        q.position = plan.outStart + MusicAutomixPlanner.lateTolerance + 1
        #expect(c.advice(for: q) == .useDefault)
        c.markFailed(current: q.current, next: q.next ?? q.current, settings: q.settings, duration: 200)
        q.position = 10
        #expect(c.advice(for: q) == .useDefault)
    }

    @Test func clearingTheCacheForgetsEverything() {
        let (c, dir) = controller(); defer { try? FileManager.default.removeItem(at: dir) }
        c.cache.store(SyntheticAudio.analysis(bpm: 120), trackUID: "x:9", duration: 200)
        c.refreshCacheStats()
        #expect(c.cachedSongs == 1)
        c.clearCache()
        #expect(c.cachedSongs == 0 && c.cache.analysis(trackUID: "x:9", duration: 200) == nil)
    }
}
