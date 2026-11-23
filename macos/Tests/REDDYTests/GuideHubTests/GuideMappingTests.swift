import Testing
import Foundation
@testable import REDDY

@Suite("Guide hub: mapping, enrichment, freshness") struct GuideMappingTests {
    static func guide(_ j: [String: Any]) -> [GuideMapGuideChannel] {
        (j["guide"] as! [[String: Any]]).map { g in
            GuideMapGuideChannel(sourceID: g["source"] as! String, xmltvID: g["id"] as! String, names: g["names"] as! [String], country: g["country"] as? String, language: g["language"] as? String, priority: g["priority"] as! Int)
        }
    }
    static func channel(_ c: [String: Any], id: String) -> GuideMapChannel {
        var ch = GuideMapChannel(id: id, name: c["name"] as! String, tvgID: c["tvg"] as? String, providerID: c["provider"] as? String, country: c["country"] as? String, language: c["language"] as? String,
                                 ownGuideSource: c["own"] as? String, altNames: c["alt"] as? [String] ?? [], restricted: c["restricted"] as? Bool ?? false)
        if let l = c["userLock"] as? [String: Any] { ch.userLock = GuideMatch(guideSourceID: l["source"] as! String, xmltvID: l["xmltv"] as! String, method: .user, confidence: 1, reason: "chosen by you") }
        return ch
    }

    @Test func mappingFixtures() throws {
        let j = try GuideFixtures.json("mapping-cases.json")
        let g = Self.guide(j)
        let cases = j["cases"] as! [[String: Any]]
        #expect(cases.count >= 50)
        for c in cases {
            let tag = "case \(c["id"] ?? "?"): \(c["note"] ?? "")"
            let r = GuideMappingEngine.map(channels: [Self.channel(c["channel"] as! [String: Any], id: "c")], guide: g)[0]
            let e = c["expect"] as! [String: Any]
            switch e["status"] as! String {
            case "mapped":
                let m = try #require(r.match, Comment(rawValue: tag))
                #expect(m.guideSourceID == e["source"] as? String && m.xmltvID == e["xmltv"] as? String, Comment(rawValue: tag))
                #expect(m.method.rawValue == e["method"] as? String, Comment(rawValue: tag))
                #expect(abs(m.confidence - (e["confidence"] as! Double)) < 0.0001, Comment(rawValue: "\(tag) got \(m.confidence)"))
            case "suggested":
                #expect(r.match == nil, Comment(rawValue: tag))
                let s = try #require(r.suggestions.first, Comment(rawValue: tag))
                #expect(s.xmltvID == e["xmltv"] as? String && s.method.rawValue == e["method"] as? String, Comment(rawValue: tag))
                #expect(s.confidence >= e["minConfidence"] as! Double && s.confidence <= e["maxConfidence"] as! Double, Comment(rawValue: "\(tag) got \(s.confidence)"))
            default:
                #expect(r.match == nil, Comment(rawValue: "\(tag) matched \(r.match?.xmltvID ?? "")"))
                #expect(r.unmapped?.rawValue == e["reason"] as? String, Comment(rawValue: "\(tag) reason \(r.unmapped?.rawValue ?? "nil")"))
            }
        }
    }

    @Test func suggestionsNeverReachTheAutomaticMap() throws {
        let r = GuideMappingEngine.map(channels: [GuideMapChannel(id: "x", name: "National Geographic Wild India Plus", country: "in")], guide: Self.guide(try GuideFixtures.json("mapping-cases.json")))[0]
        #expect(r.match == nil && r.suggestions.first?.confidence ?? 1 < 0.60)
    }

    @Test func ambiguousFuzzyKeepsASafetyMargin() {
        let g = [GuideMapGuideChannel(sourceID: "s", xmltvID: "a.in", names: ["Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota"], country: "in"),
                 GuideMapGuideChannel(sourceID: "s", xmltvID: "b.in", names: ["Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Kappa"], country: "in")]
        let r = GuideMappingEngine.map(channels: [GuideMapChannel(id: "x", name: "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Lambda", country: "in")], guide: g)[0]
        #expect(r.match == nil && r.unmapped == .ambiguous && r.suggestions.count == 2)
    }

    // MARK: enrichment

    static func index(blocklist: Data? = try? GuideFixtures.data("iptvorg-mini/blocklist.json")) throws -> IPTVOrgIndex {
        let dec = JSONDecoder()
        return try IPTVOrgIndex.build(channels: dec.decode([IPTVOrgChannel].self, from: GuideFixtures.data("iptvorg-mini/channels.json")), blocklist: blocklist,
                                      logos: dec.decode([IPTVOrgLogo].self, from: GuideFixtures.data("iptvorg-mini/logos.json")), feeds: dec.decode([IPTVOrgFeed].self, from: GuideFixtures.data("iptvorg-mini/feeds.json")))
    }

    @Test func enrichmentFixtures() throws {
        let index = try Self.index()
        let cases = try GuideFixtures.json("iptvorg-cases.json")["cases"] as! [[String: Any]]
        for c in cases {
            let ch = c["channel"] as! [String: Any], e = c["expect"] as! [String: Any]
            let got = IPTVOrgEnricher.match(name: ch["name"] as! String, tvgID: ch["tvg"] as? String, country: ch["country"] as? String, restricted: ch["restricted"] as? Bool ?? false, index: index)
            let tag = Comment(rawValue: c["note"] as! String)
            #expect(got?.dbID == e["match"] as? String, tag)
            guard let got else { continue }
            #expect(got.matchedBy == e["by"] as? String, tag)
            if let l = e["logo"] as? String { #expect(got.logoURL == l, tag) }
            if let l = e["languages"] as? [String] { #expect(got.languages == l, tag) }
            if let l = e["timezones"] as? [String] { #expect(got.timezones == l, tag) }
        }
    }

    @Test func blocklistFailsClosed() throws {
        #expect(throws: IPTVOrgError.blocklistUnavailable) { try Self.index(blocklist: nil) }
        #expect(throws: IPTVOrgError.blocklistUnavailable) { try Self.index(blocklist: Data("not json".utf8)) }
        #expect(throws: IPTVOrgError.blocklistUnavailable) { try Self.index(blocklist: Data("[]".utf8)) }
        #expect(throws: IPTVOrgError.blocklistUnavailable) { try Self.index(blocklist: Data("{\"a\":1}".utf8)) }
    }

    @Test func blockedChannelsLeaveNoTraceInTheIndex() throws {
        let index = try Self.index()
        #expect(index.channels["BlockedNews.uk"] == nil && index.logos(for: "BlockedNews.uk").isEmpty && index.ids(forName: "blocked news").isEmpty && index.blocked == ["BlockedNews.uk"])
    }

    // MARK: freshness

    @Test func freshnessFixtures() throws {
        let j = try GuideFixtures.json("freshness-cases.json")
        for c in j["cases"] as! [[String: Any]] {
            func d(_ k: String) -> Date? { (c[k] as? String).map(GuideFixtures.iso) }
            let r = GuideFreshness.evaluate(GuideFreshnessInput(now: d("now")!, enabled: c["enabled"] as! Bool, windowEnd: d("windowEnd"), lastSuccess: d("lastSuccess"), lastAttemptFailed: c["lastAttemptFailed"] as! Bool,
                                                                refreshInterval: Double(c["refreshHours"] as! Int) * 3600, programmes: c["programmes"] as! Int))
            let e = c["expect"] as! [String: Any]
            let tag = Comment(rawValue: c["note"] as! String)
            #expect(r.key == e["key"] as? String && r.level.rawValue == e["level"] as? String, tag)
            if let a = e["amount"] as? Int { #expect(r.amount == a, tag) }
            #expect(GuideMessages.text[r.key] != nil)
        }
    }
}
