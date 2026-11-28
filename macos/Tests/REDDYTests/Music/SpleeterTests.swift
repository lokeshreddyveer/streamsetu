import Testing
import Foundation
@testable import REDDY

// MARK: Helpers

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("spleeter-tests-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func tone(_ hz: Double, frames: Int, amplitude: Float = 0.4) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 44_100)) }
}

private func rms(_ a: ArraySlice<Float>) -> Double {
    guard !a.isEmpty else { return 0 }
    return (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count)).squareRoot()
}

/// Masks that do not depend on the audio: a stand-in for the network.
private struct FixedMasks: MusicSpleeterMaskPredicting {
    var vocal: Float
    var accompaniment: Float
    func masks(magnitude: [Float]) throws -> [Float] {
        let plane = magnitude.count / 2
        return [Float](repeating: vocal, count: 2 * plane) + [Float](repeating: accompaniment, count: 2 * plane)
    }
}

private final class Gather {
    var left: [Float]
    init(_ n: Int) { left = [Float](repeating: 0, count: n) }
    func put(_ start: Int, _ l: [Float], _ r: [Float]) { for i in 0..<l.count { left[start + i] = l[i] } }
}

private func instrumental(_ source: [Float], vocal: Float, accompaniment: Float) throws -> [Float] {
    let model = SpleeterStemModel(predictor: FixedMasks(vocal: vocal, accompaniment: accompaniment))
    let out = Gather(source.count)
    try MusicSeparationEngine.run(source: MusicArrayPCMSource(left: source, right: source), model: model, emit: out.put)
    return out.left
}

// MARK: Front end

@Suite struct SpleeterFrontEndTests {
    @Test func transformMatchesThePublishedModel() {
        let c = SpleeterStemModel.config
        #expect(c.nFFT == 4096 && c.hop == 1024 && c.dimF == 1024 && c.dimT == 512)
        #expect(c.isValid && c.chunk == 1024 * 511)
        #expect(SpleeterStemModel.defaultLayout.stem == .vocals && SpleeterStemModel.defaultLayout.sampleRate == 44_100)
    }

    @Test func ratioMaskIsTheVocalShareOfTheSquaredEstimates() {
        #expect(SpleeterStemModel.ratio(vocalMask: 1, accompanimentMask: 0, power: 100) > 0.999_999)
        #expect(SpleeterStemModel.ratio(vocalMask: 0, accompanimentMask: 1, power: 100) < 1e-6)
        #expect(abs(SpleeterStemModel.ratio(vocalMask: 0.5, accompanimentMask: 0.5, power: 4) - 0.5) < 1e-6)
        #expect(abs(SpleeterStemModel.ratio(vocalMask: 0.6, accompanimentMask: 0.8, power: 9) - 0.36 / 1.0) < 1e-6)
        // Silence: both estimates are empty and the reference splits it evenly; there is nothing to split.
        #expect(abs(SpleeterStemModel.ratio(vocalMask: 0.3, accompanimentMask: 0.9, power: 0) - 0.5) < 1e-6)
    }

    @Test func allVocalMaskTakesTheLowBandOutOfTheInstrumental() throws {
        let frames = 44_100 * 2
        let song = zip(tone(440, frames: frames), tone(15_000, frames: frames, amplitude: 0.2)).map { $0 + $1 }
        let inst = try instrumental(song, vocal: 1, accompaniment: 0)
        let mid = 20_000..<60_000
        // 440 Hz is gone; the 15 kHz part sits above the network's 11 kHz reach and stays (0.2 / sqrt 2 = 0.141).
        #expect(abs(rms(inst[mid]) - 0.141) < 0.02)
        let low = zip(inst, tone(440, frames: frames, amplitude: 0.4)).map { $0 * $1 }[mid].reduce(0, +) / 40_000
        #expect(abs(low) < 0.005)
    }

    @Test func allAccompanimentMaskKeepsTheSongWhole() throws {
        let frames = 44_100 * 2
        let song = zip(tone(440, frames: frames), tone(15_000, frames: frames, amplitude: 0.2)).map { $0 + $1 }
        let inst = try instrumental(song, vocal: 0, accompaniment: 1)
        let err = zip(inst, song).map { $0 - $1 }
        #expect(rms(err[10_000..<80_000]) < 0.01)
    }

    @Test func aWrongSizeIsRefused() {
        let model = SpleeterStemModel(predictor: FixedMasks(vocal: 1, accompaniment: 0))
        let c = SpleeterStemModel.config
        guard let stft = MusicSTFT(config: c) else { Issue.record("no transform"); return }
        #expect(throws: MusicStemModelError.self) { _ = try model.estimateVocals(left: [0, 0], right: [0, 0], stft: stft) }
        #expect(throws: MusicStemModelError.self) { _ = try model.separate([]) }
    }
}

// MARK: Included model

@Suite struct SpleeterBundledModelTests {
    private func resources(withModel: Bool) throws -> URL {
        let base = tempDir()
        if withModel {
            let m = base.appendingPathComponent("Models/SpleeterVocals2.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 2_000).write(to: m.appendingPathComponent("coremldata.bin"))
        }
        return base
    }

    @MainActor @Test func aBuildWithoutTheModelOffersNothing() throws {
        let mgr = MusicKaraokeModelManager(directory: tempDir(), catalog: [], bundledResources: try resources(withModel: false))
        #expect(mgr.installed.isEmpty && mgr.bundledModel == nil)
        #expect(mgr.resolve(modelID: nil, tier: .light) == nil)
    }

    @MainActor @Test func theIncludedModelShowsAsInstalledAndCannotBeDeleted() throws {
        let res = try resources(withModel: true)
        let mgr = MusicKaraokeModelManager(directory: tempDir(), catalog: [], bundledResources: res)
        let m = try #require(mgr.bundledModel)
        #expect(m.family == .spleeter && m.isBundled == true && m.licenseName == "MIT licence" && m.sizeBytes >= 2_000)
        #expect(mgr.compiledURL(for: m).path.hasSuffix("Models/SpleeterVocals2.mlmodelc"))
        #expect(mgr.compiledURL(for: m).path.hasPrefix(res.path))
        #expect(!mgr.delete(m.id) && mgr.isInstalled(m.id))
        for tier in MusicKaraokeTier.allCases { #expect(mgr.resolve(modelID: nil, tier: tier)?.id == m.id) }
        #expect(m.layout.stft == SpleeterStemModel.config)
    }

    @MainActor @Test func karaokeIsSetUpOffByDefaultAndSwitchesOn() throws {
        let defaults = UserDefaults(suiteName: "spleeter-tests-" + UUID().uuidString) ?? .standard
        let mgr = MusicKaraokeModelManager(directory: tempDir(), catalog: [], bundledResources: try resources(withModel: true))
        let c = MusicKaraokeCenter(models: mgr, cache: MusicKaraokeCache(directory: tempDir()), defaults: defaults)
        #expect(c.isSetUp && !c.isEnabled && c.statusText == "Off")
        c.setEnabled(true)
        #expect(c.isEnabled && c.activeModel?.id == "spleeter-2stems")
        c.setEnabled(false)
        #expect(!c.isEnabled)
    }

    @MainActor @Test func theManifestNeverStoresTheIncludedModel() throws {
        let dir = tempDir()
        let mgr = MusicKaraokeModelManager(directory: dir, catalog: [], bundledResources: try resources(withModel: true))
        #expect(mgr.installed.count == 1)
        let again = MusicKaraokeModelManager(directory: dir, catalog: [], bundledResources: try resources(withModel: false))
        #expect(again.installed.isEmpty)
    }

    @Test func oldManifestsWithoutAFamilyStillDecode() throws {
        let json = #"[{"id":"a","name":"A","tier":"light","compiledName":"a.mlmodelc","sizeBytes":5,"layout":{"stft":{"nFFT":4096,"hop":1024,"dimF":1024,"dimT":512,"compensate":1},"stem":"vocals","sampleRate":44100}}]"#
        let list = try JSONDecoder().decode([MusicKaraokeInstalledModel].self, from: Data(json.utf8))
        #expect(list.count == 1 && list[0].family == nil && list[0].isBundled == nil)
    }

    @Test func theNoticeShippedWithTheModelCarriesTheLicence() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Notices/Spleeter-NOTICE.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("MIT") && text.contains("Copyright (c) 2019-present, Deezer SA") && text.contains("f3a90b39dd2874269e8b05a48a86745df897b848c61f3958efc80a39152bd692"))
        #expect(LegalText.licenses.contains("Spleeter") && LegalText.licenses.contains("Deezer SA"))
    }
}

// MARK: The real network

/// Runs when `Scripts/fetch-karaoke-model.sh` has been run on this machine; skipped otherwise.
@Suite struct SpleeterRealModelTests {
    private var modelURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Models/SpleeterVocals2.mlmodelc", isDirectory: true)
    }

    @Test func theConvertedNetworkSeparatesAChordFromNoise() throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return }
        let model = try SpleeterStemModel(compiledURL: modelURL, processor: .cpu)
        let frames = 44_100 * 6
        var rng = SystemRandomNumberGenerator()
        let chord = zip(tone(220, frames: frames), zip(tone(277, frames: frames), tone(330, frames: frames))).map { $0 + $1.0 + $1.1 }
        let noise = (0..<frames).map { _ in Float.random(in: -0.05...0.05, using: &rng) }
        let song = zip(chord, noise).map { $0 + $1 }
        let out = Gather(frames)
        try MusicSeparationEngine.run(source: MusicArrayPCMSource(left: song, right: song), model: model, emit: out.put)
        #expect(out.left.allSatisfy { $0.isFinite })
        // A steady chord is accompaniment: most of it must survive.
        #expect(rms(out.left[44_100..<(frames - 44_100)]) > 0.5 * rms(song[44_100..<(frames - 44_100)]))
    }
}
