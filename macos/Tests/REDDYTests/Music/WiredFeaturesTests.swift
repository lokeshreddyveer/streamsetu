import Foundation
import AVFoundation
import Testing
@testable import REDDY

@Suite("Song navigation rules") struct TrackMarkRulesTests {
    @Test func loopWinsAndSeeksBackToA() {
        var m = MusicTrackMark(); m.loopA = 30; m.loopB = 60; m.loopOn = true
        #expect(MusicTrackMarkRules.action(position: 59, mark: m, duration: 200) == .none)
        #expect(MusicTrackMarkRules.action(position: 60.1, mark: m, duration: 200) == .seek(30))
        m.loopOn = false
        #expect(MusicTrackMarkRules.action(position: 61, mark: m, duration: 200) == .none)
    }
    @Test func startEndAndSkipsCombine() {
        var m = MusicTrackMark(); m.start = 10; m.skipIntro = 20; m.end = 180; m.skipOutro = 30
        #expect(MusicTrackMarkRules.startPosition(m, duration: 200) == 20)
        #expect(MusicTrackMarkRules.endPosition(m, duration: 200) == 170)
        #expect(MusicTrackMarkRules.action(position: 171, mark: m, duration: 200) == .advance)
        #expect(MusicTrackMarkRules.endPosition(MusicTrackMark(), duration: 200) == nil)
    }
    @Test func bookmarksNeighboursAndTimeParsing() {
        let b = [MusicTrackMark.Bookmark(name: "a", at: 10), .init(name: "b", at: 50), .init(name: "c", at: 90)]
        #expect(MusicTrackMarkRules.neighbour(of: 50, in: b, forward: true)?.name == "c")
        #expect(MusicTrackMarkRules.neighbour(of: 50, in: b, forward: false)?.name == "a")
        #expect(MusicTrackMarkRules.parse("1:30") == 90 && MusicTrackMarkRules.parse("45") == 45 && MusicTrackMarkRules.parse("x") == nil)
        #expect(MusicTrackMarkRules.clock(125) == "2:05")
    }
    @MainActor @Test func storeKeepsAndForgets() {
        let d = UserDefaults(suiteName: "marks-\(UUID().uuidString)")!
        let s = MusicTrackMarkStore(defaults: d)
        s.edit("x") { $0.loopA = 5 }
        #expect(MusicTrackMarkStore(defaults: d).mark(for: "x").loopA == 5)
        s.clear("x")
        #expect(s.marks["x"] == nil)
    }
    @Test func silenceAndCueSheets() {
        var p = [Float](repeating: 0, count: 100); for i in 10..<90 { p[i] = 0.8 }
        let s = MusicWaveform.silence(peaks: p, duration: 100)
        #expect(abs(s.lead - 10) < 0.01 && abs(s.trail - 10) < 0.01)
        let cue = "FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Two\"\n    PERFORMER \"Band\"\n    INDEX 01 03:30:37\n"
        let c = MusicCueSheet.parse(cue)
        #expect(c.count == 2 && c[1].title == "Two" && c[1].performer == "Band" && abs(c[1].start - (210 + 37.0 / 75)) < 0.001)
        #expect(MusicCueSheet.parse("FILE \"a\" WAVE\nFILE \"b\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00").isEmpty)
    }
}

@Suite("Collection safety and maintenance") struct MaintenanceTests {
    @Test func readOnlyByDefaultAndLocksWin() {
        let d = UserDefaults(suiteName: "safety-\(UUID().uuidString)")!
        #expect(MusicCollectionSafety.isReadOnly(d) && MusicCollectionSafety.verdict(for: "/a.mp3", d) == .readOnly)
        d.set(false, forKey: MusicCollectionSafety.readOnlyKey)
        #expect(MusicCollectionSafety.verdict(for: "/a.mp3", d) == .allowed)
        MusicCollectionSafety.setLocked(["/a.mp3"], true, d)
        #expect(MusicCollectionSafety.verdict(for: "/a.mp3", d) == .locked)
    }
    @Test func journalBacksUpAndUndoesATagChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.bin"); try Data("original".utf8).write(to: file)
        let j = MusicChangeJournal(directory: dir.appendingPathComponent("m"))
        let r = try #require(j.backup(of: file, summary: "title"))
        try Data("changed".utf8).write(to: file)
        #expect(j.undo(r.id))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(!j.undo(r.id), "a record is undone once")
    }
    @Test func renameTemplateCleansAndPlans() {
        #expect(MusicRenameTemplate.clean("AC/DC: Live?") == "AC_DC_ Live_")
        let e = LocalEntry(id: "1", folderID: "f", path: "/m/x.mp3", title: "Song", artist: "Art", album: "Alb", trackNumber: 3, durationMs: 1000, modified: Date(), artworkFile: nil, ext: "mp3")
        #expect(MusicRenameTemplate.path(for: e, template: "{artist}/{album}/{track} - {title}", multiDisc: false) == "Art/Alb/03 - Song")
        let plan = MusicRenameTemplate.plan([e], root: "/m", template: "{artist}/{title}", locked: [])
        #expect(plan.moves.first?.to == "/m/Art/Song.mp3")
        #expect(MusicRenameTemplate.plan([e], root: "/m", template: "{artist}/{title}", locked: ["/m/x.mp3"]).moves.isEmpty)
    }
    @Test func healthFindsGapsAndTheCsvIsSafe() {
        func e(_ n: Int, disc: Int? = nil) -> LocalEntry {
            var x = LocalEntry(id: "\(n)\(disc ?? 0)", folderID: "f", path: "/m/\(n).mp3", title: "T\(n)", artist: "A", album: "Alb", trackNumber: n, durationMs: 1000, modified: Date(), artworkFile: nil, ext: "mp3")
            x.discNumber = disc; x.albumTagged = true; return x
        }
        #expect(MusicLibraryHealth.incompleteAlbums([e(1), e(2), e(4)]).count == 1)
        #expect(MusicLibraryHealth.incompleteAlbums([e(1), e(2), e(3)]).isEmpty)
        #expect(MusicLibraryHealth.missingDiscs([e(1, disc: 1), e(1, disc: 3)]).count == 1)
        var bad = e(1); bad.title = "=cmd|' /C calc'!A0"
        #expect(MusicInventoryExport.csv([bad]).contains("\"'=cmd"))
    }
}

@Suite("Converter") struct ConverterTests {
    @Test func settingsFollowThePreset() {
        let aac = MusicConverter.settings(for: MusicConversionPreset.builtIn[0], sourceRate: 48000, sourceChannels: 2)
        #expect(aac[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC && aac[AVEncoderBitRateKey] as? Int == 256_000 && aac[AVSampleRateKey] as? Double == 44100)
        let wav = MusicConverter.settings(for: MusicConversionPreset(id: "w", name: "", format: .wav, sampleRate: nil, channels: nil, bitDepth: 24), sourceRate: 96000, sourceChannels: 2)
        #expect(wav[AVLinearPCMBitDepthKey] as? Int == 24 && wav[AVSampleRateKey] as? Double == 96000)
    }
    @Test func outputNamesNeverOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: "/x/Song.mp3")
        let a = MusicConverter.output(for: src, in: dir, format: .flac)
        try Data().write(to: a)
        #expect(MusicConverter.output(for: src, in: dir, format: .flac).lastPathComponent == "Song 2.flac")
    }
    @Test func aRealRoundTripConvertsAndVerifies() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("tone.wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        do {      // the writer must be released before the file is read, so its length is finalised
            let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!; buf.frameLength = 44100
            for c in 0..<2 { for i in 0..<44100 { buf.floatChannelData![c][i] = sin(Float(i) * 0.05) * 0.5 } }
            try file.write(from: buf)
        }
        let out = dir.appendingPathComponent("tone.m4a")
        let secs = try await MusicConverter.convert(inputs: [src], to: out, preset: MusicConversionPreset.builtIn[0], progress: { _ in }, isCancelled: { false })
        #expect(abs(secs - 1) < 0.2)
        #expect(MusicConverter.verify(out, expectedSeconds: secs) == nil)
        let part = dir.appendingPathComponent("part.wav")
        let ps = try await MusicConverter.convert(inputs: [src], to: part, preset: MusicConversionPreset.builtIn[4], range: 0.25...0.75, progress: { _ in }, isCancelled: { false })
        #expect(abs(ps - 0.5) < 0.05)
    }
}

@Suite("Listening modes") struct ListeningModeTests {
    @Test func everyModeHasAProfileAndNormalChangesNothing() {
        for m in MusicListeningMode.allCases { #expect(!m.title.isEmpty && !m.detail.isEmpty) }
        #expect(MusicModeProfile.of(.standard) == MusicModeProfile())
        #expect(MusicModeProfile.of(.audiophile).bypassesSignalProcessing && MusicModeProfile.of(.audiophile).noFades)
        #expect(MusicModeProfile.of(.album).keepsOrder && MusicModeProfile.of(.guest).privateListening && MusicModeProfile.of(.party).guestsMayQueue)
        #expect(MusicModeProfile.of(.dataSaving).lowQuality && MusicModeProfile.of(.study).quietToasts && MusicModeProfile.of(.roadTrip).largeControls)
    }
}

@Suite("Automation") struct AutomationTests {
    @Test func permissionsDefaultToCautionForOutsideCallers() {
        let d = UserDefaults(suiteName: "perm-\(UUID().uuidString)")!
        #expect(MusicAutomationPermissions.scopes(.localAPI, d).isEmpty && MusicAutomationPermissions.scopes(.link, d) == [.navigate])
        #expect(MusicAutomationPermissions.allows(.palette, .control, d) && !MusicAutomationPermissions.allows(.link, .control, d))
        MusicAutomationPermissions.set([.read], for: .localAPI, d)
        #expect(MusicAutomationPermissions.allows(.localAPI, .read, d) && !MusicAutomationPermissions.allows(.localAPI, .control, d))
    }
    @Test func scheduleDueRules() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 7, minute: 30))!     // a Friday
        var s = MusicSchedule(kind: .alarm, hour: 7, minute: 30)
        #expect(MusicScheduleRules.isDue(s, now: now, calendar: cal))
        s.weekdays = [2]; #expect(!MusicScheduleRules.isDue(s, now: now, calendar: cal))
        s.weekdays = [6]; #expect(MusicScheduleRules.isDue(s, now: now, calendar: cal))
        s.lastFired = now.addingTimeInterval(-10); #expect(!MusicScheduleRules.isDue(s, now: now, calendar: cal))
    }
    @Test func outputRulesMatchByName() {
        #expect(MusicScheduleRules.ruleMatches(MusicOutputRule(match: "airpods", calls: []), outputName: "Lokesh's AirPods Pro"))
        #expect(!MusicScheduleRules.ruleMatches(MusicOutputRule(match: "", calls: []), outputName: "x"))
    }
    @Test func localAPIRouterChecksTokenAndBody() {
        let raw = "POST /v1/command HTTP/1.1\r\nAuthorization: Bearer secret123\r\nContent-Length: 20\r\n\r\n{\"name\":\"next\",\"arg\":\"5\"}"
        let r = MusicLocalAPIRouter.parse(raw)!
        #expect(r.method == "POST" && r.path == "/v1/command")
        #expect(MusicLocalAPIRouter.authorised(r, token: "secret123") && !MusicLocalAPIRouter.authorised(r, token: "secret124") && !MusicLocalAPIRouter.authorised(r, token: "x"))
        #expect(MusicLocalAPIRouter.call(from: r.body) == MusicCommandCall(name: "next", argument: "5"))
        #expect(String(data: MusicLocalAPIRouter.reply(401, ["error": "x"]), encoding: .utf8)!.hasPrefix("HTTP/1.1 401"))
    }
}

@Suite("Visuals, shelves and setup") struct MiscWiredTests {
    @Test func analyzerSeesATone() {
        let n = MusicVisualizerAnalyzer.fftSize, rate = 44100.0
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / rate)) * 0.5 }
        let f = MusicVisualizerAnalyzer(bands: 40).analyse(left: tone, right: tone, sampleRate: rate, smoothing: 0)
        #expect(f.bands.count == 40 && (f.bands.max() ?? 0) > 0.5 && f.correlation > 0.99)
        let loudest = f.bands.firstIndex(of: f.bands.max()!)!
        #expect(loudest > 10 && loudest < 30, "1 kHz sits in the middle of 30 Hz to 16 kHz")
        let anti = tone.map { -$0 }
        #expect(MusicVisualizerAnalyzer(bands: 40).analyse(left: tone, right: anti, sampleRate: rate).correlation < -0.99)
    }
    @Test func tapIsOffUnlessActive() {
        let t = MusicAudioTap.shared
        t.setActive(false)
        let s: [Float] = [1, 1, 1, 1]
        s.withUnsafeBufferPointer { t.push(left: $0.baseAddress!, right: nil, frames: 4, sampleRate: 44100) }
        #expect(t.latest(4).left == [0, 0, 0, 0])
        t.setActive(true)
        s.withUnsafeBufferPointer { t.push(left: $0.baseAddress!, right: nil, frames: 4, sampleRate: 44100) }
        #expect(t.latest(4).left == [1, 1, 1, 1])
        t.setActive(false)
    }
    @MainActor @Test func shelvesAreRedrawnPerSeedAndKeepTheFront() {
        let items = Array(0..<30)
        let a = MusicShelfVariety.varied(items, seed: 1, name: "x", keep: 2), b = MusicShelfVariety.varied(items, seed: 2, name: "x", keep: 2)
        #expect(a != b && Array(a.prefix(2)) == [0, 1] && Set(a) == Set(items))
        #expect(a == MusicShelfVariety.varied(items, seed: 1, name: "x", keep: 2))
    }
    @Test func genresCycleThroughLikeLoveAndNotForMe() {
        var f = MusicSetupFlow()
        f.toggleGenre("Pop"); #expect(f.state(of: "Pop") == .liked)
        f.loveGenre("Pop"); #expect(f.state(of: "Pop") == .loved && f.genres.contains("Pop"))
        f.rejectGenre("Pop"); #expect(f.state(of: "Pop") == .notForMe && !f.genres.contains("Pop"))
        f.loveGenre("Jazz"); f.rejectGenre("Rock")
        let p = f.applying(to: MusicTastePrefs())
        #expect(p.lovedGenres == ["Jazz"] && p.dislikedGenres.contains("Rock") && !p.genres.contains("Rock"))
        let old = try? JSONDecoder().decode(MusicTastePrefs.self, from: Data("{\"languages\":[\"hindi\"],\"genres\":[],\"artists\":[]}".utf8))
        #expect(old?.languages == ["hindi"] && old?.lovedGenres.isEmpty == true, "an older saved copy still reads")
    }
    @Test func volumeCeilingAndConcertMatching() {
        let d = UserDefaults(suiteName: "ceil-\(UUID().uuidString)")!
        #expect(MusicAccessibilityPrefs.volumeCeiling(d) == 1)
        d.set(true, forKey: MusicAccessibilityPrefs.limitOnKey); d.set(0.6, forKey: MusicAccessibilityPrefs.limitKey)
        #expect(MusicAccessibilityPrefs.volumeCeiling(d) == 0.6)
        d.set(0.1, forKey: MusicAccessibilityPrefs.limitKey)
        #expect(MusicAccessibilityPrefs.volumeCeiling(d) == 0.3, "never lower than 30%")
    }
}
