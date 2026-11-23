import Testing
import Foundation
@testable import REDDY

@Suite("Guide hub: XMLTV decoder") struct XMLTVDecoderTests {
    @Test func timeFixtures() throws {
        let cases = try GuideFixtures.json("timezone-cases.json")["cases"] as! [[String: Any]]
        #expect(cases.count >= 20)
        for c in cases {
            let mode: GuideTimeZoneMode = switch c["mode"] as! String { case "local": .local(zoneID: c["zone"] as! String); case "utc": .utc; default: .automatic }
            let got = XMLTVTime.parse(c["input"] as! String, mode: mode)
            let want = (c["expect"] as? String).map(GuideFixtures.iso)
            #expect(got == want, "\(c["input"] ?? "") \(c["mode"] ?? "") \(c["zone"] ?? "")")
        }
    }

    @Test func basicFieldsAndDrops() throws {
        let r = try GuideFixtures.read("xmltv/basic.xml")
        #expect(r.channels.count == 2)
        #expect(r.channels[0].displayNames == ["BBC One", "BBC 1"] && r.channels[0].icon == "https://example.test/bbcone.png")
        #expect(r.stats.programmesSeen == 5 && r.stats.programmesKept == 3 && r.stats.droppedInvalid == 2)
        let p = r.programmes[0]
        #expect(p.title == "Evening News" && p.subtitle == "Headlines" && p.category == "News" && p.lang == "en" && p.date == "2026" && p.rating == "PG" && p.icon == "https://example.test/news.jpg")
        #expect(p.start == GuideFixtures.iso("2026-11-22T18:00:00Z") && p.stop == GuideFixtures.iso("2026-11-22T18:30:00Z"))
    }

    @Test func offsetsAreConvertedToUTC() throws {
        let r = try GuideFixtures.read("xmltv/with-offsets.xml")
        let starts = r.programmes.map(\.start.timeIntervalSince1970)
        let utc = GuideFixtures.iso("2026-11-22T12:00:00Z").timeIntervalSince1970
        #expect(starts == [utc - 3600, utc + 5 * 3600, utc, utc - 5.5 * 3600, utc - 3600, utc])
    }

    @Test func localZoneModeReadsOffsetlessTimesInTheZone() throws {
        let r = try GuideFixtures.read("xmltv/with-offsets.xml", mode: .local(zoneID: "Europe/Paris"))
        let utc = GuideFixtures.iso("2026-11-22T12:00:00Z").timeIntervalSince1970
        #expect(r.programmes[2].start.timeIntervalSince1970 == utc - 3600, "no offset: Paris wall time")
        #expect(r.programmes[0].start.timeIntervalSince1970 == utc - 3600, "an offset still wins")
    }

    @Test func episodeNumbers() throws {
        let r = try GuideFixtures.read("xmltv/episode-num.xml")
        #expect(r.programmes.map(\.episodeNum) == ["S02E05", "E08", "Ep 12"])
        #expect(r.programmes[0].lang == "fr")
    }

    @Test func externalEntitiesAreNotRead() throws {
        let r = try GuideFixtures.read("xmltv/dtd-xxe.xml")
        let hostname = (try? String(contentsOfFile: "/etc/hostname", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "never-present"
        #expect(!r.channels.contains { $0.displayNames.joined().contains(hostname) })
    }

    @Test func hugeTextIsCut() throws {
        let r = try GuideFixtures.read("xmltv/huge-names.xml")
        #expect(r.channels[0].displayNames[0].count == XMLTVDecoder.maxName)
        #expect(r.programmes[0].title.count == XMLTVDecoder.maxTitle)
        #expect(r.programmes[0].description!.count == XMLTVDecoder.maxText)
    }

    @Test func gzipIsUnpackedAndReadsLikeThePlainFile() throws {
        let a = try GuideFixtures.read("xmltv/gzip.xml.gz"), b = try GuideFixtures.read("xmltv/basic.xml")
        #expect(a.programmes == b.programmes && a.channels == b.channels)
    }

    @Test func windowCountsAnEmptyGuideInsteadOfHidingIt() throws {
        let now = GuideFixtures.iso("2026-11-22T12:00:00Z")
        let r = try GuideFixtures.read("xmltv/all-past.xml", window: now.addingTimeInterval(-3 * 3600)...now.addingTimeInterval(3 * 86400))
        #expect(r.stats.programmesSeen == 3 && r.stats.programmesKept == 0 && r.stats.droppedPast == 3 && r.stats.droppedFuture == 0)
        #expect(r.stats.lastStop == GuideFixtures.iso("2026-11-12T21:00:00Z") && r.stats.firstStart == GuideFixtures.iso("2026-11-10T20:00:00Z"))
        let future = try GuideFixtures.read("xmltv/basic.xml", window: GuideFixtures.iso("2026-11-01T00:00:00Z")...GuideFixtures.iso("2026-11-02T00:00:00Z"))
        #expect(future.stats.droppedFuture == 3)
    }

    @Test func invalidTimesAndNonGuides() throws {
        #expect(try GuideFixtures.read("xmltv/invalid-times.xml").stats.droppedInvalid == 2)
        #expect(try GuideFixtures.read("xmltv/channels-only.xml").stats.channels == 2)
        #expect(throws: (any Error).self) { try GuideFixtures.read("xmltv/not-a-guide.xml") }
    }

    @Test func limitsStopARunawayGuide() throws {
        var l = GuideLimits.standard; l.maxProgrammes = 2
        #expect(throws: GuideReadError.tooManyProgrammes) { try GuideFixtures.read("xmltv/basic.xml", limits: l) }
        l = .standard; l.maxChannels = 1
        #expect(throws: GuideReadError.tooManyChannels) { try GuideFixtures.read("xmltv/basic.xml", limits: l) }
    }
}
