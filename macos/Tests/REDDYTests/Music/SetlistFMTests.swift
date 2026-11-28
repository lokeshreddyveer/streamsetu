import Foundation
import Testing
@testable import REDDY

@Suite("setlist.fm concerts") struct SetlistFMTests {
    // Shape follows setlist.fm's documented JSON (api.setlist.fm/docs); not verified against a live reply.
    static let reply = """
    {"type":"setlists","itemsPerPage":20,"page":1,"total":2,"setlist":[
     {"id":"abc1","eventDate":"23-08-2024","artist":{"mbid":"x","name":"Coldplay"},
      "venue":{"name":"Wembley Stadium","city":{"name":"London","country":{"code":"GB","name":"United Kingdom"}}},
      "tour":{"name":"Music of the Spheres"},"url":"https://www.setlist.fm/setlist/coldplay/2024/abc1.html",
      "sets":{"set":[{"song":[{"name":"Yellow"},{"name":"Fix You (Live)"},{"name":"Hey Jude","cover":{"name":"The Beatles"}}]},
                     {"encore":1,"song":[{"name":"Clocks"}]}]}},
     {"id":"abc2","eventDate":"bad","venue":{"name":"Club"},"sets":{"set":[]},"url":"http://insecure.example/x"}]}
    """

    @Test func parsesShowsSongsEncoreAndCovers() throws {
        let j = try #require(JSONSerialization.jsonObject(with: Data(Self.reply.utf8)) as? [String: Any])
        let c = SetlistFMParser.concerts(j)
        #expect(c.count == 2)
        #expect(c[0].place == "Wembley Stadium, London, United Kingdom")
        #expect(c[0].tour == "Music of the Spheres")
        #expect(c[0].songs.map(\.name) == ["Yellow", "Fix You (Live)", "Hey Jude", "Clocks"])
        #expect(c[0].songs[2].coverOf == "The Beatles")
        #expect(c[0].songs[3].encore && !c[0].songs[0].encore)
        #expect(c[0].url?.scheme == "https")
    }

    @Test func aBadDateAnInsecureLinkAndNoSongsAreKeptSafely() throws {
        let j = try #require(JSONSerialization.jsonObject(with: Data(Self.reply.utf8)) as? [String: Any])
        let c = SetlistFMParser.concerts(j)[1]
        #expect(c.date == nil && c.songs.isEmpty && c.url == nil)
        #expect(SetlistFMParser.concerts([:]).isEmpty)
    }

    @Test func dateIsDayMonthYear() {
        let d = SetlistFMParser.date("23-08-2024")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(d.map { cal.dateComponents([.year, .month, .day], from: $0) }?.month == 8)
        #expect(SetlistFMParser.date("31-13-2024") == nil && SetlistFMParser.date(nil) == nil)
    }

    @Test func titlesMatchIgnoringBracketsCaseAndAccents() {
        #expect(SetlistMatcher.key("Fix You (Live)") == SetlistMatcher.key("fix you"))
        #expect(SetlistMatcher.key("Café del Mar - Remix") == SetlistMatcher.key("Cafe del Mar"))
    }

    @Test func theClientRefusesABadIdWithoutAnyRequest() async {
        let client = SetlistFMClient(key: { "k" })
        await #expect(throws: (any Error).self) { _ = try await client.recentConcerts(mbid: "not-an-id/../x") }
    }

    @Test func noKeyMeansUnavailable() { #expect(!SetlistFMClient(key: { nil }).isAvailable) }
}
