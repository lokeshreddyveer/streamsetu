import Testing
import Foundation
import CoreGraphics
@testable import REDDY

// Material You palette maths, the light around a video, the import auto-update rules (with a fake clock) and the local provider's ids. Pure logic only.

private func near(_ a: MusicRGB, _ b: MusicRGB, _ tol: Double) -> Bool { abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol && abs(a.b - b.b) <= tol }
private func luminance(_ c: MusicRGB) -> Double {
    func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}
private func contrast(_ a: MusicRGB, _ b: MusicRGB) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }

@Suite struct MaterialPaletteTests {
    private let baseline = MusicOKLCH.rgb(hex: "#6750A4")!

    @Test func hexRoundTrips() {
        #expect(MusicOKLCH.hex(baseline) == "#6750A4")
        #expect(MusicOKLCH.rgb(hex: "f00") == MusicRGB(1, 0, 0))
        #expect(MusicOKLCH.rgb(hex: "zzz") == nil)
    }

    @Test func baselinePurpleSeedsAtHueAndFactorOne() {
        let seed = MusicMaterialSeed(baseline)
        #expect(abs(seed.hue - 293.7) < 0.3)
        #expect(abs(seed.chromaFactor - 1) < 0.01)
    }

    @Test func greyAndNeonSeedsAreClamped() {
        let grey = MusicMaterialSeed(MusicRGB(0.5, 0.5, 0.5))
        #expect(grey.hue == 294 && grey.chromaFactor == 0.15)
        let red = MusicMaterialSeed(MusicRGB(1, 0, 0))
        #expect(abs(red.hue - 29.2) < 0.3 && red.chromaFactor == 1.35)
        let blue = MusicMaterialSeed(MusicOKLCH.rgb(hex: "#1A4EDA")!)       // chroma 0.22 is far above the baseline 0.1305, so it caps
        #expect(abs(blue.hue - 264.0) < 0.3 && blue.chromaFactor == 1.35)
    }

    @Test func lightPrimaryOfTheBaselineIsCloseToTheSeed() {
        let s = MusicMaterialPalette.scheme(MusicMaterialSeed(baseline), dark: false)
        #expect(near(s.primary, baseline, 0.04))
        #expect(luminance(s.background) > 0.9 && luminance(s.onBackground) < 0.05)
    }

    @Test func darkSchemeIsDarkWithReadablePairs() {
        for hex in ["#6750A4", "#1A4EDA", "#85CC23", "#FF0000"] {
            let seed = MusicMaterialSeed(MusicOKLCH.rgb(hex: hex)!)
            let d = MusicMaterialPalette.scheme(seed, dark: true), l = MusicMaterialPalette.scheme(seed, dark: false)
            #expect(luminance(d.background) < 0.05 && luminance(l.background) > 0.9)
            #expect(contrast(d.primary, d.background) > 4.5, "\(hex) dark primary on background")
            #expect(contrast(l.primary, l.background) > 4.5, "\(hex) light primary on background")
            #expect(contrast(d.onPrimary, d.primary) > 3 && contrast(l.onPrimary, l.primary) > 3)
            #expect(contrast(d.onBackground, d.background) > 10 && contrast(l.onBackground, l.background) > 10)
        }
    }

    @Test func surfacesStepAwayFromTheBackground() {
        let d = MusicMaterialPalette.scheme(.baseline, dark: true), l = MusicMaterialPalette.scheme(.baseline, dark: false)
        #expect(luminance(d.surfaceContainerLow) < luminance(d.surfaceContainer) && luminance(d.surfaceContainer) < luminance(d.surfaceContainerHigh))
        #expect(luminance(l.surfaceContainerLow) > luminance(l.surfaceContainer) && luminance(l.surfaceContainer) > luminance(l.surfaceContainerHigh))
        #expect(d.tintFills.background == d.background && d.tintFills.hue == 294)
    }

    @Test func tonesRunFromBlackToWhiteAndGreyMatchesLStar() {
        let grey = MusicTonalPalette(hue: 0, chroma: 0)
        #expect(near(grey.color(tone: 0), MusicRGB(0, 0, 0), 0.001))
        #expect(near(grey.color(tone: 100), MusicRGB(1, 1, 1), 0.001))
        #expect(near(grey.color(tone: 50), MusicRGB(0.4667, 0.4667, 0.4667), 0.01))     // L* 50 is #777777
        let ramp = MusicTonalPalette(hue: 294, chroma: 0.135).ramp()
        let lums = MusicTonalPalette.tones.compactMap { ramp[$0] }.map(luminance)
        #expect(lums == lums.sorted())
        #expect(ramp.count == MusicTonalPalette.tones.count)
    }

    @Test func outOfGamutChromaKeepsTheHue() {
        let c = MusicOKLCH.rgb(l: 0.9, c: 0.35, h: 142)
        #expect((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b))
        #expect(abs(MusicOKLCH.from(c).h - 142) < 4)
    }

    @Test func themeChoiceDefaultsToStandardAndPicksTheSeed() {
        let d = UserDefaults(suiteName: "theme-\(UUID().uuidString)")!
        #expect(MusicThemeSettings.palette(d) == .standard)
        MusicThemeSettings.setPalette(.materialPicked, d)
        #expect(MusicThemeSettings.palette(d) == .materialPicked)
        MusicThemeSettings.setPickedColor(MusicRGB(1, 0, 0), d)
        #expect(MusicOKLCH.hex(MusicThemeSettings.pickedColor(d)) == "#FF0000")
        let cover = MusicRGB(0, 1, 0), picked = MusicRGB(0, 0, 1), sys = MusicRGB(1, 0, 1)
        #expect(MusicThemeSettings.seedColor(for: .standard, cover: cover, picked: picked, system: sys) == nil)
        #expect(MusicThemeSettings.seedColor(for: .materialCover, cover: cover, picked: picked, system: sys) == cover)
        #expect(MusicThemeSettings.seedColor(for: .materialCover, cover: nil, picked: picked, system: sys) == nil)
        #expect(MusicThemeSettings.seedColor(for: .materialPicked, cover: cover, picked: picked, system: sys) == picked)
        #expect(MusicThemeSettings.seedColor(for: .materialSystem, cover: cover, picked: picked, system: sys) == sys)
    }
}

@Suite struct AmbientGlowMathTests {
    private let picture = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    @Test func kernelWeightsSumToOne() {
        for sigma in [0.5, 1.5, 3] { #expect(abs(MusicAmbientMath.kernel(sigma: sigma).reduce(0, +) - 1) < 1e-12) }
        #expect(MusicAmbientMath.kernel(sigma: 1.5).count == 11)
    }

    @Test func insideTheCellReadsTheFrameAndOutsideReadsTheEdgeBand() {
        let inside = MusicAmbientMath.sourcePoint(cell: CGPoint(x: 0.5, y: 0.5), picture: picture)
        #expect(abs(inside.x - 0.5) < 1e-9 && abs(inside.y - 0.5) < 1e-9)
        let left = MusicAmbientMath.sourcePoint(cell: CGPoint(x: 0.05, y: 0.5), picture: picture)
        #expect(abs(left.x - 0.06) < 1e-9 && abs(left.y - 0.5) < 1e-9)         // 12% in from the left edge
        let corner = MusicAmbientMath.sourcePoint(cell: CGPoint(x: 0.0, y: 0.0), picture: picture)
        #expect(abs(corner.x - 0.06) < 1e-9 && abs(corner.y - 0.06) < 1e-9)
    }

    @Test func glowColoursFollowTheFrameEdges() {
        // Left half red, right half blue.
        var px = [UInt8](); for _ in 0..<4 { for x in 0..<8 { px += x < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        let frame = MusicAmbientFrame(width: 8, height: 4, rgba: px)
        let grid = MusicAmbientMath.sample(frame, picture: picture, columns: 8, rows: 4)
        #expect(grid[0 * 8 + 0].x > 0.9 && grid[0 * 8 + 0].z < 0.1)
        #expect(grid[0 * 8 + 7].z > 0.9 && grid[0 * 8 + 7].x < 0.1)
    }

    @Test func smoothingSnapsFirstThenEasesWithTheTimeConstant() {
        let a: [SIMD3<Float>] = [SIMD3(0, 0, 0)], b: [SIMD3<Float>] = [SIMD3(1, 1, 1)]
        #expect(MusicAmbientMath.smooth(previous: nil, new: b, dt: 0.07) == b)
        let one = MusicAmbientMath.smooth(previous: a, new: b, dt: 0.12)[0].x
        #expect(abs(one - Float(1 - exp(-1.0))) < 1e-5)
        var v = a; for _ in 0..<5 { v = MusicAmbientMath.smooth(previous: v, new: b, dt: 0.07) }   // 0.35 s of 15 fps frames
        #expect(v[0].x > 0.94)
    }

    @Test func blurKeepsAFlatGridFlat() {
        let flat = MusicAmbientMath.flat(SIMD3(0.2, 0.4, 0.6), columns: 8, rows: 4)
        let out = MusicAmbientMath.blur(flat, columns: 8, rows: 4)
        #expect(out.allSatisfy { abs($0.x - 0.2) < 1e-5 && abs($0.z - 0.6) < 1e-5 })
    }

    @Test func strengthIsZeroInsideFadesOutwardAndEndsAtTheReach() {
        let s = { (x: Double) in MusicAmbientMath.strength(cell: CGPoint(x: x, y: 0.5), picture: picture, aspect: 1) }
        #expect(s(0.5) == 0)
        #expect(s(0.24) > s(0.15) && s(0.15) > s(0.1))
        #expect(s(0.75 + 0.5 * 0.3 + 0.01) == 0)         // beyond 0.3 picture heights (0.15 of the view here)
    }

    @Test func attachingTheGlowOnlyRunsAtFifteenFramesAtMost() {
        #expect(MusicAmbientMath.framesPerSecond == 15)
        #expect(MusicAmbientMath.columns * MusicAmbientMath.rows == 576)
    }
}

// MARK: - Import scheduler

@MainActor
private final class Fake {
    var now = Date(timeIntervalSince1970: 2_000_000)
    var consented = true
    var busy = false
    var budget = ImportBudget()
    var records: [String: SpotifySourceRecord] = [:]
    var updated: [UUID] = []
    var sleeps: [TimeInterval] = []
    var results: [UUID: Result<SpotifyImportJob.UpdateSummary, ImportError>] = [:]

    func id(auto: Bool, checkedHoursAgo: Double) -> UUID {
        let u = UUID()
        records[u.uuidString] = SpotifySourceRecord(url: "https://open.spotify.com/playlist/\(u.uuidString.prefix(8))", keys: ["a"], auto: auto, checked: now.addingTimeInterval(-checkedHoursAgo * 3600))
        return u
    }

    func scheduler(hang: Bool = false) -> MusicImportScheduler {
        let env = MusicImportScheduler.Environment(
            now: { self.now }, consented: { self.consented }, records: { self.records },
            setRecord: { r, id in self.records[id.uuidString] = r }, budget: { self.budget }, isBusy: { self.busy },
            update: { id in
                self.updated.append(id)
                switch self.results[id] ?? .success(.init(added: 1, removed: 0, upToDate: false)) { case .success(let s): return s; case .failure(let e): throw e }
            },
            sleep: { t in
                await MainActor.run { self.sleeps.append(t) }
                if hang { try? await Task.sleep(for: .seconds(3600)) }
            })
        return MusicImportScheduler(environment: env, defaults: UserDefaults(suiteName: "sched-\(UUID().uuidString)")!)
    }
}

@MainActor @Suite struct ImportSchedulerTests {
    @Test func nothingRunsUnlessSwitchedOn() async {
        let f = Fake(); _ = f.id(auto: false, checkedHoursAgo: 48)
        let s = f.scheduler()
        s.start()
        #expect(!s.isRunning)                         // no task, no timer when nothing is enabled
        #expect(await s.checkNow() == 0 && f.updated.isEmpty)
    }

    @Test func notConsentedMeansNothing() async {
        let f = Fake(); _ = f.id(auto: true, checkedHoursAgo: 48); f.consented = false
        let s = f.scheduler(hang: true)
        s.start()
        #expect(!s.isRunning)
        #expect(await s.checkNow() == 0)
    }

    @Test func dueImportsAreUpdatedAndTheResultIsRecorded() async {
        let f = Fake()
        let old = f.id(auto: true, checkedHoursAgo: 8), fresh = f.id(auto: true, checkedHoursAgo: 1)
        f.results[old] = .success(.init(added: 3, removed: 1, upToDate: false))
        let s = f.scheduler()
        #expect(await s.checkNow() == 1)
        #expect(f.updated == [old] && !f.updated.contains(fresh))
        let o = s.outcome(for: old)
        #expect(o?.kind == .updated && o?.added == 3 && o?.removed == 1 && o?.at == f.now)
        #expect(s.lastRun == f.now)
        #expect(f.records[old.uuidString]?.checked == f.now)     // not due again for six hours
    }

    @Test func longestUncheckedGoesFirstAndReadsAreSpacedFiveSeconds() async {
        let f = Fake()
        let a = f.id(auto: true, checkedHoursAgo: 10), b = f.id(auto: true, checkedHoursAgo: 30), c = f.id(auto: true, checkedHoursAgo: 20)
        let s = f.scheduler()
        #expect(await s.checkNow() == 3)
        #expect(f.updated == [b, c, a])
        #expect(f.sleeps == [5, 5])
    }

    @Test func busyImportOrLowBudgetOrCooldownSkipTheWholePass() async {
        let f = Fake(); _ = f.id(auto: true, checkedHoursAgo: 12)
        let s = f.scheduler()
        f.busy = true
        #expect(await s.checkNow() == 0)
        f.busy = false
        f.budget = ImportBudget(windowStart: f.now.addingTimeInterval(-600), count: 590)
        #expect(await s.checkNow() == 0)                          // 10 left of 600 is below the minimum
        f.budget = ImportBudget(windowStart: f.now.addingTimeInterval(-600), count: 100)
        f.budget.cooldownUntil = f.now.addingTimeInterval(1000)
        #expect(await s.checkNow() == 0)
        f.budget = ImportBudget(windowStart: f.now.addingTimeInterval(-4000), count: 600)       // window over: full budget again
        #expect(await s.checkNow() == 1)
    }

    @Test func aBlockFromTheServiceEndsThePassAndAFailureIsShown() async {
        let f = Fake()
        let first = f.id(auto: true, checkedHoursAgo: 30), second = f.id(auto: true, checkedHoursAgo: 20)
        f.results[first] = .failure(.cooldown(until: f.now.addingTimeInterval(3600)))
        let s = f.scheduler()
        #expect(await s.checkNow() == 1)
        #expect(f.updated == [first])
        #expect(s.outcome(for: first)?.kind == .failed)
        #expect(f.records[first.uuidString]?.checked == f.now.addingTimeInterval(-30 * 3600))     // a rest is not a look
        f.results[second] = .failure(.network("offline"))
        f.results[first] = nil
        #expect(await s.checkNow() == 2)
        #expect(s.outcome(for: second)?.message == "offline")
    }

    @Test func upToDateIsReportedAsSuch() async {
        let f = Fake(); let id = f.id(auto: true, checkedHoursAgo: 12)
        f.results[id] = .success(.init(added: 0, removed: 0, upToDate: true))
        let s = f.scheduler()
        _ = await s.checkNow()
        #expect(s.outcome(for: id)?.kind == .upToDate)
    }

    @Test func theSwitchStartsAndStopsTheLoop() async {
        let f = Fake(); let id = f.id(auto: false, checkedHoursAgo: 12)
        let s = f.scheduler(hang: true)
        #expect(!s.isAutoUpdate(id) && s.canUpdate(id))
        s.setAutoUpdate(true, for: id)
        #expect(s.isAutoUpdate(id) && s.isRunning)
        s.setAutoUpdate(false, for: id)
        #expect(!s.isAutoUpdate(id) && !s.isRunning)
        s.stop()
    }

    @Test func firstLookIsSoonAfterLaunchThenAtMostOncePerHour() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        #expect(ImportSchedule.delay(now: now, lastRun: nil) == ImportSchedule.initialDelay)
        #expect(ImportSchedule.delay(now: now, lastRun: now.addingTimeInterval(-600)) == 3000)
        #expect(ImportSchedule.delay(now: now, lastRun: now.addingTimeInterval(-7200)) == 0)
        #expect(ImportSchedule.interval == 3600)
    }

    @Test func budgetRemainingCountsWithoutSpending() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var b = ImportBudget()
        #expect(b.remaining(now: t) == 600)
        _ = b.admit(now: t)
        #expect(b.remaining(now: t) == 599 && b.remaining(now: t) == 599)
        #expect(b.remaining(now: t.addingTimeInterval(3601)) == 600)
        b.trip(now: t)
        #expect(b.remaining(now: t.addingTimeInterval(10)) == 0)
    }
}

// MARK: - Local provider ids

@Suite struct LocalProviderIdTests {
    private func entry(_ title: String, artist: String, album: String, path: String, albumArtist: String? = nil, track: Int? = nil) -> LocalEntry {
        LocalEntry(id: LocalLibraryIndex.trackID(path: path), folderID: "f", path: path, title: title, artist: artist, album: album, trackNumber: track, durationMs: 1000,
                   modified: Date(timeIntervalSince1970: 0), artworkFile: nil, ext: "mp3", albumArtist: albumArtist, discNumber: nil, albumTagged: nil)
    }

    private func provider(with entries: [LocalEntry]) throws -> LocalFilesProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-ids-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var idx = LocalLibraryIndex(entries: entries)
        idx.scanVersion = LocalLibraryIndex.currentScanVersion
        try JSONEncoder().encode(idx).write(to: dir.appendingPathComponent("index.json"))
        return LocalFilesProvider(store: LocalLibraryStore(directory: dir))
    }

    @Test func trackReferencesUseTheAlbumKeyAndThePrimaryArtist() throws {
        let e = entry("Song", artist: "Ann feat. Bob", album: "Hits", path: "/m/hits/1.mp3", albumArtist: "Ann")
        let p = try provider(with: [e])
        let t = p.track(e)
        #expect(t.album?.id == LocalLibraryIndex.albumKey(of: e))
        #expect(t.artists.first?.id == LocalLibraryIndex.artistID(LocalLibraryIndex.primaryArtist(of: e)))
        #expect(t.artists.first?.name == "Ann feat. Bob")
        let g = LocalLibraryIndex(entries: [e]).albums()[0]
        #expect(p.album(g).id == t.album?.id)
    }

    @Test func artistAlbumsFollowTheNewKeysAndCollaboratorsFileUnderThePrimaryArtist() async throws {
        let a1 = entry("One", artist: "Ann", album: "First", path: "/m/first/1.mp3", albumArtist: "Ann")
        let a2 = entry("Two", artist: "Ann feat. Bob", album: "Second", path: "/m/second/1.mp3", albumArtist: "Ann")
        let other = entry("Three", artist: "Cy", album: "Third", path: "/m/third/1.mp3", albumArtist: "Cy")
        let p = try provider(with: [a1, a2, other])
        let ann = LocalLibraryIndex.artistID("Ann")
        let page = try await p.artistAlbums(id: ann, page: nil)
        #expect(Set(page.items.map(\.title)) == ["First", "Second"])
        #expect(page.items.allSatisfy { $0.artists.first?.id == ann })
        let tracks = try await p.albumTracks(id: LocalLibraryIndex.albumKey(of: a2), page: nil)
        #expect(tracks.items.map(\.title) == ["Two"])
    }

    @Test func oldIdsStillResolve() async throws {
        let e = entry("Song", artist: "Ann feat. Bob", album: "Hits", path: "/m/hits/1.mp3")
        let p = try provider(with: [e])
        let oldAlbum = LocalLibraryIndex.albumID(album: "Hits", artist: "Ann feat. Bob")
        #expect(try await p.album(id: oldAlbum).title == "Hits")
        #expect(try await p.albumTracks(id: oldAlbum, page: nil).items.count == 1)
        let oldArtist = LocalLibraryIndex.artistID("Ann feat. Bob")
        #expect(try await p.artist(id: oldArtist).name == "Ann")
        #expect(try await p.artistAlbums(id: oldArtist, page: nil).items.map(\.title) == ["Hits"])
    }
}
