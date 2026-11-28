import Testing
import Foundation
@testable import REDDY

#if os(macOS)
/// Synthesised audio with a known answer: a click track at a known tempo, chords in a known key, a sine at a known level.
private enum Synth {
    static let rate = SonicDSP.sampleRate

    static func clicks(bpm: Double, seconds: Double, amplitude: Float = 0.6) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * rate))
        let beat = 60 / bpm
        var t = 0.0
        while t < seconds {
            let start = Int(t * rate)
            for i in 0..<Int(0.03 * rate) where start + i < x.count {
                let env = Float(exp(-Double(i) / (0.006 * rate)))
                x[start + i] += amplitude * env * Float(sin(2 * .pi * 1500 * Double(i) / rate))
            }
            t += beat
        }
        return x
    }

    static func chord(_ midi: [Int], seconds: Double, amplitude: Float = 0.1) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * rate))
        for m in midi {
            let f = 440 * pow(2, Double(m - 69) / 12)
            for i in 0..<x.count {
                let t = Double(i) / rate
                x[i] += amplitude * Float(sin(2 * .pi * f * t) + 0.5 * sin(2 * .pi * 2 * f * t) + 0.25 * sin(2 * .pi * 3 * f * t))
            }
        }
        return x
    }

    static func sine(amplitude: Float, hz: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }
}

@Suite("Sonic analysis")
struct SonicAnalysisTests {
    @Test(arguments: [90.0, 120.0, 140.0])
    func aClickTrackGivesItsTempo(bpm: Double) throws {
        let p = try SonicAnalyzer.profile(of: Synth.clicks(bpm: bpm, seconds: 30))
        let found = try #require(p.bpm)
        #expect(abs(found - bpm) <= 2.5, "found \(found) for \(bpm)")
        #expect(p.bpmConfidence > 0.15)
    }

    @Test func aSteadyToneHasNoTempo() throws {
        let p = try SonicAnalyzer.profile(of: Synth.sine(amplitude: 0.3, hz: 440, seconds: 20))
        #expect(p.bpm == nil || p.bpmConfidence < 0.3)
    }

    @Test func majorAndMinorChordsGiveTheirKeys() throws {
        let c = try SonicAnalyzer.profile(of: Synth.chord([60, 64, 67, 48], seconds: 20))
        #expect(c.keyTonic == 0 && c.keyIsMinor == false)
        #expect(c.camelot == "8B" && c.keyName == "C major")
        let a = try SonicAnalyzer.profile(of: Synth.chord([57, 60, 64, 45], seconds: 20))
        #expect(a.keyTonic == 9 && a.keyIsMinor == true)
        #expect(a.camelot == "8A")
    }

    @Test func levelAndPeakFollowTheSignal() throws {
        let p = try SonicAnalyzer.profile(of: Synth.sine(amplitude: 0.1414, hz: 440, seconds: 20))
        #expect(abs(p.levelDB - (-20)) < 1.0)
        #expect(abs(p.peakDB - (-17)) < 1.0)
        #expect(p.dynamicRangeDB < 1)
    }

    @Test func aLoudBusyRecordingIsMoreEnergeticThanAQuietSteadyOne() throws {
        let quiet = try SonicAnalyzer.profile(of: Synth.sine(amplitude: 0.02, hz: 220, seconds: 20))
        let busy = try SonicAnalyzer.profile(of: Synth.clicks(bpm: 150, seconds: 20, amplitude: 0.9))
        #expect(busy.energy > quiet.energy)
        #expect(quiet.energyClass == .relaxed)
    }

    @Test func aRecordingThatChangesHasMoreThanOneSection() throws {
        let x = Synth.chord([60, 64, 67], seconds: 40, amplitude: 0.1) + Synth.chord([66, 70, 73], seconds: 40, amplitude: 0.3) + Synth.chord([60, 64, 67], seconds: 40, amplitude: 0.1)
        let p = try SonicAnalyzer.profile(of: x)
        #expect(p.sections.count >= 2)
        #expect(p.sections.first?.start == 0)
        #expect(abs((p.sections.last?.end ?? 0) - p.analysedSeconds) < 0.5)
    }

    @Test func tooShortAudioIsRefusedNotGuessed() {
        #expect(throws: SonicAnalyzer.Failure.tooShort) { try SonicAnalyzer.profile(of: Synth.sine(amplitude: 0.3, hz: 440, seconds: 3)) }
    }
}

@Suite("Sonic similarity and sessions")
struct SonicSimilarityTests {
    private func item(_ key: String, vector: [Float], energy: Double = 0.5, bpm: Double? = 120, tonic: Int? = 0, minor: Bool = false) -> SonicSimilarity.Item {
        var p = SonicProfile(); p.vector = vector; p.energy = energy; p.bpm = bpm; p.keyTonic = tonic; p.keyIsMinor = minor; p.keyConfidence = 0.8
        p.rhythm = [Float](repeating: 0.125, count: 8)
        return SonicSimilarity.Item(key: key, profile: p)
    }

    @Test func theMostSimilarSongSoundsMostLike() {
        let a = item("a", vector: [1, 0, 0, 0]), near = item("near", vector: [0.9, 0.1, 0, 0]), far = item("far", vector: [0, 0, 1, 0])
        let r = SonicSimilarity.similar(to: a.profile, excluding: "a", in: [a, far, near])
        #expect(r.map(\.key) == ["near", "far"])
    }

    @Test func camelotRulesMixNeighboursAndRelativeKeys() {
        let c = item("c", vector: [1], tonic: 0).profile            // 8B
        let g = item("g", vector: [1], tonic: 7).profile            // 9B
        let aMin = item("am", vector: [1], tonic: 9, minor: true).profile   // 8A
        let fs = item("fs", vector: [1], tonic: 6).profile          // 2B
        #expect(SonicSimilarity.harmonicallyCompatible(c, g))
        #expect(SonicSimilarity.harmonicallyCompatible(c, aMin))
        #expect(!SonicSimilarity.harmonicallyCompatible(c, fs))
    }

    @Test func tempoAgreementAllowsHalfAndDoubleTime() {
        #expect(SonicSimilarity.tempoAgrees(120, 121))
        #expect(SonicSimilarity.tempoAgrees(60, 120))
        #expect(SonicSimilarity.tempoAgrees(240, 120))
        #expect(!SonicSimilarity.tempoAgrees(120, 135))
    }

    @Test func aJourneyMovesStepByStepFromOneSongToTheOther() {
        let start = item("s", vector: [1, 0, 0]), end = item("e", vector: [0, 0, 1])
        let all = [start, end, item("m1", vector: [0.7, 0.3, 0]), item("m2", vector: [0.3, 0.3, 0.4]), item("m3", vector: [0, 0.3, 0.7]), item("x", vector: [0, 1, 0])]
        let path = SonicSimilarity.journey(from: start, to: end, in: all, steps: 3)
        #expect(path.count == 3)
        #expect(!path.contains { $0.key == "s" || $0.key == "e" })
        #expect(Set(path.map(\.key)).count == 3)
        #expect(path.first?.key == "m1" && path.last?.key == "m3")
    }

    @Test func energyProgressionRisesGraduallyAndNeverRepeats() {
        let all = (0..<10).map { item("t\($0)", vector: [1], energy: Double($0) / 9) }
        let up = SonicSimilarity.energyProgression(from: 0.1, to: 0.9, count: 5, in: all)
        #expect(up.count == 5 && Set(up.map(\.key)).count == 5)
        #expect(zip(up, up.dropFirst()).allSatisfy { $0.profile.energy <= $1.profile.energy })
        let down = SonicSimilarity.energyProgression(from: 0.9, to: 0.1, count: 5, in: all)
        #expect(zip(down, down.dropFirst()).allSatisfy { $0.profile.energy >= $1.profile.energy })
    }
}

@Suite("Sonic storage")
struct SonicStorageTests {
    @Test func aProfileIsKeptUntilTheFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        let store = SonicStore(url: url)
        var p = SonicProfile(); p.bpm = 128; p.vector = [0.1, 0.2]
        await store.set(p, key: "song", stamp: 1000)
        #expect(await store.isCurrent(key: "song", stamp: 1000))
        #expect(!(await store.isCurrent(key: "song", stamp: 2000)))       // the file changed
        #expect(!(await store.isCurrent(key: "other", stamp: 1000)))
        await store.flush()
        let reopened = SonicStore(url: url)
        #expect(await reopened.profile(for: "song")?.bpm == 128)
        await reopened.clear()
        #expect(await reopened.count() == 0)
    }
}
#endif
