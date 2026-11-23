import Testing
import Foundation
@testable import REDDY

/// What the persona evaluation (tools/personas) showed and the engines now do: shared fixtures artwork/fixtures/name-cleaning-persona.json and epg/fixtures/mapping-persona.json, plus the lookup retry.
@Suite("Persona fixes") struct PersonaFixesTests {
    static func root(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(rel)
    }

    @Test func nameCleaningPersonaFixtures() throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root("artwork/fixtures/name-cleaning-persona.json"))) as! [[String: Any]]
        #expect(rows.count >= 10)
        for r in rows { #expect(ArtworkNameCleaner.clean(r["input"] as! String, year: r["year"] as? Int) == r["expectedClean"] as! String, Comment(rawValue: r["input"] as! String)) }
    }

    @Test func aLeadingYearBecomesTheSearchYear() {
        let p = ArtworkNameCleaner.parse("IN - 2024 - KALKI 2898-AD")
        #expect(p.text == "KALKI 2898-AD" && p.year == 2024)
    }

    @Test func guidePersonaFixtures() throws {
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root("epg/fixtures/mapping-persona.json"))) as! [String: Any]
        let g = GuideMappingTests.guide(j)
        for c in j["cases"] as! [[String: Any]] {
            let tag = "case \(c["id"] ?? "?"): \(c["note"] ?? "")"
            let r = GuideMappingEngine.map(channels: [GuideMappingTests.channel(c["channel"] as! [String: Any], id: "c")], guide: g)[0]
            let e = c["expect"] as! [String: Any]
            if e["status"] as! String == "mapped" {
                let m = try #require(r.match, Comment(rawValue: tag))
                #expect(m.xmltvID == e["xmltv"] as? String && m.method.rawValue == e["method"] as? String, Comment(rawValue: tag))
                #expect(abs(m.confidence - (e["confidence"] as! Double)) < 0.0001, Comment(rawValue: "\(tag) got \(m.confidence)"))
            } else { #expect(r.match == nil, Comment(rawValue: tag)) }
        }
    }

    @Test func twoCountryPrefixesAreRead() {
        let k = ChannelNormalizer.name("US| US: MTV HD")
        #expect(k.base == "mtv" && k.countryPrefix == "us")
    }

    @Test func spellingVariantsShortenLongVowelsDoubledLettersAndAspirates() {
        #expect(MetadataMatchService.spellingVariants("baahubalee").contains("bahubale"))
        #expect(MetadataMatchService.spellingVariants("moodi movie").contains("mudi movie"))
        #expect(MetadataMatchService.spellingVariants("raja").isEmpty)          // nothing to shorten
        #expect(MetadataMatchService.spellingVariants("abc").isEmpty)           // too short
        #expect(MetadataMatchService.spellingVariants("\u{9AD}\u{93E}\u{930}\u{924}").isEmpty)   // native script is left alone
    }

    @Test func aNumberedSequelOrAnAbsentTitleIsNotTakenForTheOriginal() {
        let c: [ArtworkMatchDecision.Candidate] = [.init(id: 1, title: "Dhoom 2", originalTitle: "Dhoom 2", year: 2006, popularity: 30, originalLanguage: "hi")]
        #expect(ArtworkMatchDecision.decide(.init(title: "Dhoom", year: 2004, isSeries: false), c, text: "Dhoom") == nil)
        let remakes: [ArtworkMatchDecision.Candidate] = [.init(id: 2, title: "Drishyam", originalTitle: "Drishyam", year: 2013, popularity: 20, originalLanguage: "ml"), .init(id: 3, title: "Drishyam", originalTitle: "Drishyam", year: 2015, popularity: 25, originalLanguage: "hi")]
        #expect(ArtworkMatchDecision.decide(.init(title: "Drishyam", year: 2015, isSeries: false), remakes, text: "Drishyam") == 2)          // name only: the first result in order
        #expect(ArtworkMatchDecision.decide(.init(title: "Drishyam", year: nil, isSeries: false), remakes, text: "Drishyam") == 2)
    }
}
