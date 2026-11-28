import Foundation
import Testing
@testable import REDDY

// Local library folder stamps and short-file memory (temporary folders, fake files), plus the equalizer's automatic preamp, glide steps and preset import.

private func makeTree(_ files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-scan-\(UUID().uuidString)", isDirectory: true)
    for f in files {
        let u = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
    }
    return root
}

@Suite struct LocalScanTests {
    @Test func firstWalkListsEverythingAndStampsDirectories() throws {
        let root = try makeTree(["A/one.mp3", "A/B/two.flac", "A/notes.txt", "Podcasts/pod.mp3"])
        defer { try? FileManager.default.removeItem(at: root) }
        let w = try #require(LocalScanner.walk(root: root, stamps: [:], known: [:], skipped: [:]))
        #expect(w.found.count == 2)
        #expect(w.directoriesReused == 0 && w.directoriesListed >= 3)
        #expect(w.stamps.count >= 3)
    }

    @Test func unchangedDirectoriesAreReusedFromTheIndex() throws {
        let root = try makeTree(["A/one.mp3", "A/B/two.flac"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(LocalScanner.walk(root: root, stamps: [:], known: [:], skipped: [:]))
        let second = try #require(LocalScanner.walk(root: root, stamps: first.stamps, known: first.found, skipped: [:]))
        #expect(second.directoriesListed == 0 && second.directoriesReused >= 3)
        #expect(second.found == first.found)
    }

    @Test func aNewFileDeepDownIsFoundWhenStampsAreOld() throws {
        let root = try makeTree(["A/one.mp3", "A/B/two.flac"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(LocalScanner.walk(root: root, stamps: [:], known: [:], skipped: [:]))
        // Pretend the last scan happened an hour ago, then add a file deep down.
        let old = first.stamps.mapValues { $0.addingTimeInterval(-3600) }
        let deep = root.resolvingSymlinksInPath().appendingPathComponent("A/B/three.mp3")
        try Data("x".utf8).write(to: deep)
        let second = try #require(LocalScanner.walk(root: root, stamps: old, known: first.found, skipped: [:]))
        #expect(second.found.keys.contains(deep.path))
        #expect(second.found.count == 3)
    }

    @Test func thoroughForgetsStampsSoEverythingIsListed() throws {
        var index = LocalLibraryIndex()
        index.folderStamps = ["f": ["/a": Date()]]
        index.skippedShort = ["f": ["/a/x.mp3": Date()], "g": ["/b/y.mp3": Date()]]
        index.forgetStamps(folderID: "f")
        #expect(index.stamps(in: "f").isEmpty && index.skipped(in: "f").isEmpty && !index.skipped(in: "g").isEmpty)
        index.forgetStamps()
        #expect(index.folderStamps == nil && index.skippedShort == nil)
    }

    @Test func shortFilesAreNotReadAgainUntilTheyChange() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let found = ["/m/short.mp3": t, "/m/new.mp3": t]
        let p = LocalLibraryIndex.plan(known: [:], found: found, skipped: ["/m/short.mp3": t])
        #expect(p.toRead == ["/m/new.mp3"])
        let changed = LocalLibraryIndex.plan(known: [:], found: ["/m/short.mp3": t.addingTimeInterval(60)], skipped: ["/m/short.mp3": t])
        #expect(changed.toRead == ["/m/short.mp3"])
    }

    @Test func oldIndexFilesStillDecode() throws {
        let data = Data(#"{"version":1,"entries":[]}"#.utf8)
        let i = try JSONDecoder().decode(LocalLibraryIndex.self, from: data)
        #expect(i.folderStamps == nil && i.stamps(in: "x").isEmpty)
        let again = try JSONDecoder().decode(LocalLibraryIndex.self, from: JSONEncoder().encode(i))
        #expect(again.entries.isEmpty)
    }

    @Test func unreadableRootGivesNil() {
        #expect(LocalScanner.walk(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), stamps: [:], known: [:], skipped: [:]) == nil)
    }
}

@Suite struct EqualizerPolishTests {
    @Test func flatCurveNeedsNoPreamp() {
        #expect(MusicEqualizerMath.autoPreampDB(MusicEqualizerSettings()) == 0)
    }

    @Test func preampCancelsTheHighestBoost() {
        var s = MusicEqualizerSettings(); s.enabled = true; s.bands = [0, 0, 0, 6, 0, 0, 0]
        let pre = MusicEqualizerMath.autoPreampDB(s)
        #expect(pre < -5.5 && pre >= -8)
        let peak = MusicEqualizerMath.peakBoostDB(s)
        #expect(peak + pre <= 0.001)
        #expect(MusicEqualizerMath.makeupGainDB(s) == pre)
    }

    @Test func allPresetsNeverExceedFullScaleWithAutoPreamp() {
        for p in MusicEqualizerPresets.all {
            var s = MusicEqualizerSettings(); s.apply(p)
            #expect(MusicEqualizerMath.peakBoostDB(s) + MusicEqualizerMath.makeupGainDB(s) <= 0.001)
        }
    }

    @Test func turningItOffKeepsTheOlderShare() {
        var s = MusicEqualizerSettings(); s.enabled = true; s.bands = [0, 0, 0, 10, 0, 0, 0]; s.autoPreamp = false
        let share = MusicEqualizerMath.makeupGainDB(s)
        s.autoPreamp = true
        #expect(MusicEqualizerMath.makeupGainDB(s) < share)
    }

    @Test func preampSettingIsSavedAndOldFilesDefaultToOn() throws {
        var s = MusicEqualizerSettings(); s.autoPreamp = false
        let back = try JSONDecoder().decode(MusicEqualizerSettings.self, from: JSONEncoder().encode(s))
        #expect(back.autoPreamp == false)
        let old = try JSONDecoder().decode(MusicEqualizerSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.autoPreamp)
    }

    @Test func glideStepsAreEvenAndEndExactly() {
        let steps = MusicEqualizerGlide.steps(from: 0, to: 8)
        #expect(steps.count == MusicEqualizerGlide.stepCount && steps.last == 8)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 > $0 })
        #expect(abs((steps[1] - steps[0]) - 1) < 1e-9)
        #expect(MusicEqualizerGlide.steps(from: 3, to: 3) == [3])
        #expect(MusicEqualizerGlide.stepMs * MusicEqualizerGlide.stepCount == MusicEqualizerGlide.durationMs)
    }

    @Test func importReadsPeakingAndShelves() throws {
        let text = """
        Preamp: -4.0 dB
        Filter 1: ON LSC Fc 105 Hz Gain 4 dB Q 0.70
        Filter 2: ON PK Fc 800 Hz Gain -3 dB Q 1.0
        Filter 3: ON HSC Fc 8000 Hz Gain 2 dB Q 0.70
        Filter 4: OFF PK Fc 3000 Hz Gain 5 dB Q 1.0
        Filter 5: ON LP Fc 18000 Hz
        """
        let p = MusicEqualizerImport.parse(text)
        #expect(p.filters.count == 3 && p.preamp == -4)
        #expect(p.skipped.count == 1)
        let r = try MusicEqualizerImport.fit(text)
        #expect(r.bands.count == 7 && r.bands.allSatisfy { MusicEqualizerSettings.gainRange.contains($0) })
        #expect(r.bands[0] > 1 && r.bands[3] < -1 && r.bands[6] > 0.5)
        #expect(r.approximated)
        #expect(r.filePreampDB == -4)
    }

    @Test func aSingleBandCentredBellFitsClosely() throws {
        let r = try MusicEqualizerImport.fit("Filter 1: ON PK Fc 800 Hz Gain 3 dB Q 0.9")
        #expect(r.bands[3] >= 2.5)
        #expect(r.filterCount == 1 && r.skippedLines.isEmpty)
    }

    @Test func importRefusesEmptyAndHugeFiles() {
        #expect(throws: MusicEqualizerImport.Failure.noFilters) { try MusicEqualizerImport.fit("hello\nworld") }
        let huge = String(repeating: "x", count: MusicEqualizerImport.maxBytes + 1)
        #expect(throws: MusicEqualizerImport.Failure.tooLarge) { try MusicEqualizerImport.fit(huge) }
    }

    @Test func importClampsExtremeGains() throws {
        let r = try MusicEqualizerImport.fit("Filter 1: ON PK Fc 800 Hz Gain 40 dB Q 0.5")
        #expect(r.bands.max() == 12)
        #expect(r.approximated)
    }
}
