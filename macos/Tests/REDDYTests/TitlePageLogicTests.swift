import Testing
import Foundation
import CoreGraphics
@testable import REDDY

@Suite("Mac title page logic") struct TitlePageLogicTests {
    @Test func layoutAdaptsToWidth() {
        #expect(TitlePageLogic.metrics(width: 1000).columns == .two)
        #expect(TitlePageLogic.metrics(width: 720).columns == .one && TitlePageLogic.metrics(width: 720).poster > 0)
        #expect(TitlePageLogic.metrics(width: 500).poster == 0)
        let small = TitlePageLogic.dialogSize(window: CGSize(width: 1024, height: 680)), big = TitlePageLogic.dialogSize(window: CGSize(width: 3000, height: 2000))
        #expect(small.width <= 1024 - 96 && small.height <= 680 - 64 && big.width == 1060 && big.height == 820)
    }

    @Test func resumeOnlyWhenWorthIt() {
        func p(_ pos: Double, done: Bool = false) -> WatchProgress { WatchProgress(itemID: "a", kind: .movie, seriesID: nil, positionSeconds: pos, durationSeconds: 6000, updatedAt: Date(), completed: done) }
        #expect(TitlePageLogic.resume(nil) == nil && TitlePageLogic.resume(p(10)) == nil && TitlePageLogic.resume(p(3000, done: true)) == nil && TitlePageLogic.resume(p(5900)) == nil)
        let r = TitlePageLogic.resume(p(3000))
        #expect(r?.fraction == 0.5 && r?.remaining == 3000)
        #expect(TitlePageLogic.playLabel(resume: r) == .init(title: "Resume", detail: "50m left", fraction: 0.5))
        #expect(TitlePageLogic.playLabel(resume: nil).title == "Play")
        #expect(TitlePageLogic.playLabel(episode: (2, 3), resume: nil, startedSeries: true).title == "Play Next S2 E3")
        #expect(TitlePageLogic.playLabel(episode: (1, 1), resume: nil, startedSeries: false).title == "Play S1 E1")
        #expect(TitlePageLogic.playLabel(episode: (2, 3), resume: r, startedSeries: true).title == "Resume S2 E3")
    }

    @Test func chipsAndSpeech() {
        let c = TitlePageLogic.chips(year: 2026, runtimeSeconds: 10_560, age: "PG-13", quality: "4K", seasons: nil)
        #expect(c.map(\.text) == ["2026", "2h 56m", "PG-13", "4K"] && c.filter(\.badge).count == 2)
        #expect(TitlePageLogic.chipsSpoken(c, rating: 8, runtimeSeconds: 10_560) == "2026, 2 hours 56 minutes, rated PG-13, 4K, rating 8.0")
        #expect(TitlePageLogic.chips(year: nil, runtimeSeconds: 0, age: "", quality: nil, seasons: 1).map(\.text) == ["1 season"])
        #expect(TitlePageLogic.genreLine(["Drama", " ", "Action"]) == "Drama · Action" && TitlePageLogic.genreLine([]) == nil)
    }

    @Test func detailsAndCast() {
        let rows = [DetailRow(label: "Starring", value: .people([])), DetailRow(label: "Country", value: .text("UK"))]
        #expect(TitlePageLogic.gridRows(rows, castShown: true).map(\.label) == ["Country"] && TitlePageLogic.gridRows(rows, castShown: false).count == 2)
        let tmdb = TitleDetails.Person(name: "A B", role: nil, photoPath: "/x.jpg"), own = TitleDetails.Person(name: "C", role: nil, photoPath: "https://media.example/c.jpg")
        #expect(TitlePageLogic.photoURL(tmdb, hasKey: false) == nil && TitlePageLogic.photoURL(tmdb, hasKey: true) != nil && TitlePageLogic.photoURL(own, hasKey: false) != nil)
        #expect(TitlePageLogic.initials("matt john damon") == "MJ")
    }

    @Test func rowsFadeOnlyWhereMoreLies() {
        #expect(TitlePageLogic.fadeEdges(offset: 0, content: 300, viewport: 400) == (false, false))
        #expect(TitlePageLogic.fadeEdges(offset: 0, content: 900, viewport: 400) == (false, true))
        #expect(TitlePageLogic.fadeEdges(offset: -200, content: 900, viewport: 400) == (true, true))
        #expect(TitlePageLogic.fadeEdges(offset: -500, content: 900, viewport: 400) == (true, false))
        #expect(TitlePageLogic.seasonsAsChips(6) && !TitlePageLogic.seasonsAsChips(7))
    }

    @Test func colourFromArtwork() throws {
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
            let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); return c.makeImage()!
        }
        let red = try #require(TitlePalette.dominant(of: solid(0.9, 0.1, 0.1)))
        #expect(red.r > 0.8 && red.g < 0.2)
        let w = TitlePalette.wash(red)
        #expect(abs(max(w.r, w.g, w.b) - 0.42) < 0.01)
        let grey = try #require(TitlePalette.dominant(of: solid(0.5, 0.5, 0.5)))
        #expect(grey.saturation < 0.05)
    }

    @Test func nextEpisodeWording() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z")!
        func n(_ s: String?) -> TitleNextEpisode? { TitleNextEpisode.from(stamp: s, now: now, calendar: cal, locale: Locale(identifier: "en_GB")) }
        #expect(n("2026-12-01T20:00:00+00:00") == .today && n("2026-12-02T02:00:00+00:00") == .tomorrow && n("2026-12-04T02:00:00Z") == .days(3))
        #expect(n("2026-11-30T02:00:00Z") == nil && n(nil) == nil && n("soon") == nil && n("") == nil)
        #expect(n("2027-02-10T00:00:00Z") == .on("10 Feb") && n("2026-12-20") == .on("20 Dec"))
    }

    @Test func episodeNamesLoseTheirArtefacts() {
        let c = TitlePageLogic.cleanEpisodeTitle
        #expect(c("Murder in Mahim (Telugu) - S01E01 -", "Murder in Mahim", 1) == "Episode 1")
        #expect(c("Murder in Mahim (Telugu) - S01E02 - The Chase", "Murder in Mahim", 2) == "The Chase")
        #expect(c("Low Tide", "Harbor Lights", 2) == "Low Tide")
        #expect(c("  - ", "X", 5) == "Episode 5" && c("S02E10", "X", 10) == "Episode 10" && c("Episode 4", "X", 4) == "Episode 4")
        #expect(c("The Salt and Iron", "Iron", 3).contains("Salt"))
    }
}
