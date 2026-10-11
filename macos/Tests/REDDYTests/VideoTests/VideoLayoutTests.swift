import Testing
import Foundation
import CoreGraphics
@testable import REDDY

@Suite("Video sizing") struct VideoLayoutTests {
    static let containers: [CGSize] = [CGSize(width: 1024, height: 680), CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900), CGSize(width: 1728, height: 1117)]
    let hd = CGSize(width: 1920, height: 1080)

    func rect(_ c: CGSize, _ s: VideoLayoutSettings, source: CGSize? = nil, scale: CGFloat = 1) -> CGRect {
        VideoLayoutCalculator.videoRect(container: c, source: source ?? hd, settings: s, backingScale: scale)
    }
    func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

    @Test func fitPreservesAspectAndCentersAtEveryWindowSize() {
        for c in Self.containers {
            let r = rect(c, VideoLayoutSettings())
            #expect(near(r.width / r.height, 16.0 / 9, 0.001), "aspect at \(c)")
            #expect(r.width <= c.width + 0.01 && r.height <= c.height + 0.01, "never exceeds the container")
            #expect(near(r.midX, c.width / 2) && near(r.midY, c.height / 2), "centred")
            #expect(near(r.width, c.width) || near(r.height, c.height), "touches at least one edge")
        }
        let r = rect(CGSize(width: 1280, height: 800), VideoLayoutSettings())
        #expect(near(r.width, 1280) && near(r.height, 720) && near(r.minY, 40))
    }

    @Test func autoEqualsFit() {
        for c in Self.containers { #expect(rect(c, VideoLayoutSettings(mode: .auto)) == rect(c, VideoLayoutSettings(mode: .fit))) }
    }

    @Test func fillCoversTheContainerWithoutDistortion() {
        for c in Self.containers {
            let r = rect(c, VideoLayoutSettings(mode: .fill))
            #expect(r.width >= c.width - 0.01 && r.height >= c.height - 0.01, "covers at \(c)")
            #expect(near(r.width / r.height, 16.0 / 9, 0.001), "no stretching")
            #expect(near(r.midX, c.width / 2) && near(r.midY, c.height / 2))
        }
    }

    @Test func stretchFillsExactlyAndIgnoresAspect() {
        for c in Self.containers { #expect(rect(c, VideoLayoutSettings(mode: .stretch)) == CGRect(origin: .zero, size: c)) }
    }

    @Test func originalSizeUsesPixelsDividedByBackingScale() {
        let c = CGSize(width: 1728, height: 1117)
        let r1 = rect(c, VideoLayoutSettings(mode: .original), scale: 1)
        let r2 = rect(c, VideoLayoutSettings(mode: .original), scale: 2)
        #expect(near(r1.width, 1920) && near(r1.height, 1080))
        #expect(near(r2.width, 960) && near(r2.height, 540) && near(r2.midX, c.width / 2))
        let sd = rect(c, VideoLayoutSettings(mode: .original), source: CGSize(width: 720, height: 576), scale: 1)
        #expect(near(sd.width, 720) && near(sd.height, 576))
    }

    @Test func aspectOverridesReshapeTheFittedPicture() {
        let c = CGSize(width: 1280, height: 800)
        let table: [(AspectRatioOption, Double)] = [(.r16x9, 16.0 / 9), (.r4x3, 4.0 / 3), (.r21x9, 21.0 / 9), (.r235, 2.35), (.r1x1, 1), (.custom(width: 5, height: 4), 1.25)]
        for (a, ratio) in table {
            let r = rect(c, VideoLayoutSettings(aspect: a))
            #expect(near(r.width / r.height, ratio, 0.001), "\(a.title)")
            #expect(r.width <= c.width + 0.01 && r.height <= c.height + 0.01)
        }
        // "Original" keeps the source's own ratio, e.g. a 4:3 SD stream
        let sd = rect(c, VideoLayoutSettings(aspect: .original), source: CGSize(width: 720, height: 540))
        #expect(near(sd.width / sd.height, 4.0 / 3, 0.001))
        // anamorphic correction: 1:1 forced on a 16:9 source
        #expect(near(rect(c, VideoLayoutSettings(aspect: .r1x1)).width, 800))
    }

    @Test func zoomScalesAboutTheCentreAndClampsPan() {
        let c = CGSize(width: 1280, height: 800)
        for z in VideoLayoutSettings.zoomPresets {
            var s = VideoLayoutSettings(); s.setZoom(z)
            let r = rect(c, s)
            #expect(near(r.width, 1280 * z) && near(r.midX, c.width / 2) && near(r.midY, c.height / 2), "zoom \(z)")
        }
        var s = VideoLayoutSettings(); s.setZoom(2)
        s.panX = 1
        #expect(near(rect(c, s).minX, 0), "panned fully right: left edge meets the container, no gap")
        s.panX = -1
        #expect(near(rect(c, s).maxX, c.width), "panned fully left: right edge meets the container")
        s.panX = 50                                       // out of range is clamped
        #expect(near(rect(c, s).minX, 0))
        // a zoomed picture always still covers the container horizontally
        for px in stride(from: -1.0, through: 1.0, by: 0.25) { s.panX = px; let r = rect(c, s); #expect(r.minX <= 0.01 && r.maxX >= c.width - 0.01) }
    }

    @Test func zoomIsClampedAndOneResetsPan() {
        var s = VideoLayoutSettings()
        s.setZoom(9); #expect(s.zoom == 3)
        s.setZoom(0.2); #expect(s.zoom == 1)
        s.setZoom(2); s.panX = 0.5; s.panY = -0.5
        s.setZoom(1); #expect(s.panX == 0 && s.panY == 0)
    }

    @Test func draggingPansWithinTheAvailableTravel() {
        let c = CGSize(width: 1280, height: 800)
        var s = VideoLayoutSettings(); s.setZoom(2)           // 2560-wide picture: 640 pt of travel each way
        s = VideoLayoutCalculator.pan(s, dragging: CGSize(width: 320, height: 0), container: c, source: hd)
        #expect(near(CGFloat(s.panX), 0.5, 0.001))
        s = VideoLayoutCalculator.pan(s, dragging: CGSize(width: 5000, height: 0), container: c, source: hd)
        #expect(s.panX == 1)
        var unzoomed = VideoLayoutSettings()
        unzoomed = VideoLayoutCalculator.pan(unzoomed, dragging: CGSize(width: 300, height: 300), container: c, source: hd)
        #expect(unzoomed.panX == 0 && unzoomed.panY == 0, "nothing to pan at 100% fit")
    }

    @Test func unknownVideoSizeAndDegenerateContainersAreSafe() {
        #expect(rect(CGSize(width: 800, height: 450), VideoLayoutSettings(), source: .zero) == CGRect(x: 0, y: 0, width: 800, height: 450))
        #expect(rect(.zero, VideoLayoutSettings()) == .zero)
        #expect(rect(CGSize(width: 800, height: 0), VideoLayoutSettings()) == .zero)
        let tiny = rect(CGSize(width: 320, height: 180), VideoLayoutSettings())      // mini player
        #expect(near(tiny.width, 320) && near(tiny.height, 180))
    }

    @Test func windowPresetsMatchTheSpec() {
        #expect(VideoLayoutCalculator.WindowPreset.mini.size == CGSize(width: 320, height: 180))
        #expect(VideoLayoutCalculator.WindowPreset.small.size == CGSize(width: 480, height: 270))
        #expect(VideoLayoutCalculator.WindowPreset.medium.size == CGSize(width: 800, height: 450))
        #expect(VideoLayoutCalculator.WindowPreset.large.size == CGSize(width: 1280, height: 720))
        for p in VideoLayoutCalculator.WindowPreset.allCases { #expect(near(p.size.width / p.size.height, 16.0 / 9, 0.001)) }
    }

    @Test func settingsSurviveEncoding() throws {
        var s = VideoLayoutSettings(mode: .fill, aspect: .custom(width: 5, height: 4)); s.setZoom(1.5); s.panX = 0.3
        let back = try JSONDecoder().decode(VideoLayoutSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        for a in AspectRatioOption.presets { #expect(try JSONDecoder().decode(AspectRatioOption.self, from: JSONEncoder().encode(a)) == a) }
    }

    // MARK: persistence

    @Test func globalAndPerChannelLayoutsPersistAcrossReopening() throws {
        let db = try TestSupport.makeDB()
        let repo = SQLiteVideoPreferencesRepository(db: db)
        #expect(repo.globalLayout() == .default && repo.layout(for: "chan-a") == nil)
        var zoomed = VideoLayoutSettings(); zoomed.setZoom(1.5)
        repo.setLayout(zoomed, for: "chan-a")
        repo.setGlobalLayout(VideoLayoutSettings(mode: .fill))
        let reopened = SQLiteVideoPreferencesRepository(db: try DatabaseManager(path: db.path))
        #expect(reopened.layout(for: "chan-a") == zoomed)
        #expect(reopened.globalLayout().mode == .fill)
        #expect(reopened.layout(for: "chan-b") == nil, "other channels fall back to the global default")
        reopened.clearLayout(for: "chan-a")
        #expect(reopened.layout(for: "chan-a") == nil)
    }

    @Test func removingASourceRemovesItsChannelLayouts() throws {
        let db = try TestSupport.makeDB()
        let s = try TestSupport.makeSource(db)
        let repo = SQLiteVideoPreferencesRepository(db: db)
        let id = ItemID.make(source: s.id, kind: .channel, provider: "1")
        repo.setLayout(VideoLayoutSettings(mode: .fill), for: id)
        repo.setGlobalLayout(VideoLayoutSettings(mode: .stretch))
        try SQLiteCatalogRepository(db: db).deleteSource(id: s.id)
        #expect(repo.layout(for: id) == nil)
        #expect(repo.globalLayout().mode == .stretch, "the global default is not tied to any source")
    }
}
