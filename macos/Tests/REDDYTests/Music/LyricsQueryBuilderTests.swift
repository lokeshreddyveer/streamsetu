import Testing
import Foundation
@testable import REDDY

struct LyricsQueryBuilderTests {
    private func clean(_ s: String) -> MusicLyricsQueryBuilder.CleanTitle { MusicLyricsQueryBuilder.cleanTitle(s) }

    @Test func titleNoiseIsRemoved() {
        #expect(clean("Dakko Dakko Meka song (from pushpa telugu)").title == "Dakko Dakko Meka")
        #expect(clean("Dakko Dakko Meka song (from pushpa telugu)").film == "pushpa")
        #expect(clean("Kaavaalaa Lyrical Video Song | Jailer | Rajinikanth").title == "Kaavaalaa")
        #expect(clean("Butta Bomma Full Video Song HD").title == "Butta Bomma")
        #expect(clean("Naatu Naatu (Full Video) [4K]").title == "Naatu Naatu")
        #expect(clean("Tum Hi Ho - Official Video").title == "Tum Hi Ho")
        #expect(clean("Bohemian Rhapsody (Remastered 2011)").title == "Bohemian Rhapsody")
        #expect(clean("Srivalli Telugu Lyrical | Pushpa #shorts").title == "Srivalli")
    }

    @Test func fromPatternsGiveTheFilm() {
        #expect(clean("Chaleya (From \"Jawan\")").title == "Chaleya")
        #expect(clean("Chaleya (From \"Jawan\")").film == "Jawan")
        #expect(clean("Oo Antava [From Pushpa - The Rise]").film == "Pushpa - The Rise")
        #expect(clean("Vaathi Coming from Master").title == "Vaathi Coming")
        #expect(clean("Vaathi Coming from Master").film == "Master")
    }

    @Test func featuredArtistsAreSeparated() {
        let a = clean("Blinding Lights (feat. Rosalia)")
        #expect(a.title == "Blinding Lights" && a.featured == ["Rosalia"])
        let b = clean("Peaches ft. Daniel Caesar & Giveon")
        #expect(b.title == "Peaches" && b.featured == ["Daniel Caesar", "Giveon"])
    }

    @Test func songsWithWordsLikeNoiseSurvive() {
        #expect(clean("Song 2").title == "Song 2")
        #expect(clean("Full Circle").title == "Full Circle")
        #expect(clean("Video Killed the Radio Star").title == "Video Killed the Radio Star")
    }

    @Test func artistAndTitleShape() {
        let c = clean("Queen - Bohemian Rhapsody (Official Video Remastered)")
        #expect(c.leadingArtist == "Queen" && c.title == "Bohemian Rhapsody")
    }

    @Test func channelNamesAreNotArtists() {
        for name in ["LOOP Studio", "T-Series", "Zee Music Company", "Aditya Music", "Sony Music India", "Lahari Music", "Think Music", "Speed Records",
                     "Saregama Telugu Studios", "Queen - Topic".replacingOccurrences(of: "Queen - ", with: "Warner Music "), "Shemaroo Entertainment"] {
            #expect(MusicLyricsQueryBuilder.looksLikeChannel(name), Comment(rawValue: name))
        }
        for name in ["Anirudh Ravichander", "Taylor Swift", "A. R. Rahman", "Queen", "Devi Sri Prasad"] {
            #expect(!MusicLyricsQueryBuilder.looksLikeChannel(name), Comment(rawValue: name))
        }
    }

    @Test func artistLinesKeepOnlyPeople() {
        #expect(MusicLyricsQueryBuilder.cleanArtists("LOOP Studio") == "")
        #expect(MusicLyricsQueryBuilder.cleanArtists("Queen - Topic") == "Queen")
        #expect(MusicLyricsQueryBuilder.cleanArtists("TaylorSwiftVEVO") == "TaylorSwift")
        #expect(MusicLyricsQueryBuilder.cleanArtists("Taylor Swift Official") == "Taylor Swift")
        #expect(MusicLyricsQueryBuilder.cleanArtists("Anirudh Ravichander, T-Series") == "Anirudh Ravichander")
        #expect(MusicLyricsQueryBuilder.cleanArtists("Sivam & Devi Sri Prasad") == "Sivam, Devi Sri Prasad")
    }

    @Test func theOwnersExample() {
        let r = MusicLyricsRequest(videoID: "abc", title: "Dakko Dakko Meka song (from pushpa telugu)", artists: "LOOP Studio", album: nil, durationSeconds: 300)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v.first?.title == "Dakko Dakko Meka")
        #expect(v.first?.artists == "")
        #expect(v.first?.album == "pushpa")
        #expect(v.contains { $0.title == "Daakko Daakko Meka" })
        #expect(v.count <= MusicLyricsQueryBuilder.maxVariants)
        let applied = r.applying(v[0])
        #expect(applied.videoID == "abc" && applied.durationSeconds == 300 && applied.title == "Dakko Dakko Meka")
    }

    @Test func aRealArtistIsKeptAndAlsoDroppedAsAFallback() {
        let r = MusicLyricsRequest(videoID: nil, title: "Blinding Lights (Official Audio)", artists: "The Weeknd", album: "After Hours", durationSeconds: 200)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v[0].title == "Blinding Lights" && v[0].artists == "The Weeknd" && v[0].album == "After Hours")
        #expect(v[1].artists == "" && v[1].title == "Blinding Lights")
    }

    @Test func titleWithArtistInsideUsesItWhenUploaderIsAChannel() {
        let r = MusicLyricsRequest(videoID: nil, title: "Arijit Singh - Kesariya | Brahmastra", artists: "T-Series", album: nil, durationSeconds: nil)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v[0].title == "Kesariya" && v[0].artists == "Arijit Singh")
    }

    @Test func variantsAreDistinctAndNeverEmpty() {
        for t in ["", "   ", "(Official Video)", "Song", "HD"] {
            let v = MusicLyricsQueryBuilder.variants(for: MusicLyricsRequest(videoID: nil, title: t, artists: "", album: nil, durationSeconds: nil))
            #expect(v.allSatisfy { !$0.title.isEmpty })
            #expect(Set(v.map { $0.title.lowercased() + "|" + $0.artists.lowercased() }).count == v.count)
        }
    }

    @Test func spellingAlternates() {
        #expect(MusicLyricsQueryBuilder.spellingAlternate("Dakko Dakko Meka") == "Daakko Daakko Meka")
        #expect(MusicLyricsQueryBuilder.spellingAlternate("Meka") == nil)
        #expect(MusicLyricsQueryBuilder.spellingAlternate("Bohemian Rhapsody") == "Bohemian Rhaapsody")
        #expect(MusicLyricsQueryBuilder.spellingAlternate("కావాలా") == nil)
    }
}

struct LyricsLookupRulesTests {
    @Test func missesAreOnlyRememberedWhenTrustedSourcesAnswered() {
        let r = MusicLyricsCachePolicy.self
        #expect(r.shouldStoreMiss(none: [MusicLyricsSources.lrclib], errors: []))
        #expect(r.shouldStoreMiss(none: [MusicLyricsSources.lrclib], errors: [MusicLyricsSources.genius, MusicLyricsSources.portato]))
        #expect(!r.shouldStoreMiss(none: [MusicLyricsSources.lrclib], errors: [MusicLyricsSources.netease]))
        #expect(!r.shouldStoreMiss(none: [MusicLyricsSources.portato, MusicLyricsSources.simpMusic], errors: []))
        #expect(!r.shouldStoreMiss(none: [], errors: []))
        #expect(MusicLyricsCachePolicy.missTTL == 6 * 3600)
    }

    @Test func oldNoLyricsRowsAreDropped() throws {
        let old = #"{"fetchedAt": 1000}"#.data(using: .utf8) ?? Data()
        #expect(MusicLyricsDiskStore.decode(old) == nil)
        let current = #"{"fetchedAt": 1000, "schema": \#(MusicLyricsCachePolicy.schema)}"#.data(using: .utf8) ?? Data()
        let e = MusicLyricsDiskStore.decode(current)
        #expect(e != nil && e?.lyrics == nil)
    }

    @Test func nearestLengthComesFirstAndUnknownLast() {
        let items: [(String, Double?)] = [("far", 400), ("near", 301), ("none", nil), ("exact", 300)]
        let out = MusicLyricsMatch.ordered(items, wanted: 300) { $0.1 }.map(\.0)
        #expect(out == ["exact", "near", "none"])
        #expect(MusicLyricsMatch.ordered(items, wanted: nil) { $0.1 }.count == 4)
    }

    @Test func kugouNeteaseAndMegalobizCandidates() {
        let kugou: [String: Any] = ["data": ["info": [["hash": "a", "duration": 200], ["hash": "b", "duration": 301]]]]
        #expect(KugouProvider.hashes(kugou, wanted: 300) == ["b"])
        let netease: [String: Any] = ["result": ["songs": [["id": 1, "duration": 250_000], ["id": 2, "duration": 299_000], ["id": 3, "duration": 301_000]]]]
        #expect(NeteaseProvider.songIDs(netease, wanted: 300) == ["2", "3"])
        let mega: [String: Any] = ["results": [["id": 278488, "duration": 300.28], ["id": 110616, "duration": 300.17], ["id": 5, "duration": 90.0]]]
        #expect(MegalobizProvider.ids(mega, wanted: 300) == ["110616", "278488"])
        let lrc: [String: Any] = ["lines": [["time_ms": 58790, "text": "Veluthuru thintadi aaku.."], ["time_ms": 63280, "text": "aakunu thintadi meka!.."]]]
        #expect(MegalobizProvider.map(lrc)?.synced?.count == 2)
    }

    @Test func plusSignsInQueriesAreEncoded() async throws {
        struct Spy: MusicHTTPTransport {
            let seen: @Sendable (URL) -> Void
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if let u = request.url { seen(u) }
                return (Data("{}".utf8), HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse())
            }
        }
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()
        let http = MusicHTTP(transport: Spy { box.url = $0 })
        _ = try await http.get(URL(string: "https://example.com/x")!, query: ["q": "a+b c"])
        #expect(box.url?.absoluteString.contains("q=a%2Bb%20c") == true)
    }

    @Test func unavailableStateHasAnHonestLabel() {
        #expect(MusicLyricsSourceState.unavailable.label == "Unavailable right now")
    }

    @MainActor @Test func aSourceIsLeftOutAfterThreeHardFailures() {
        let h = MusicLyricsHealth()
        h.recordFailure("x"); h.recordFailure("x")
        #expect(!h.isDown("x"))
        h.recordFailure("x")
        #expect(h.isDown("x"))
        h.reset("x")
        #expect(!h.isDown("x"))
        h.recordFailure("y"); h.recordAnswer("y")
        #expect(!h.isDown("y"))
    }

    @Test func hardFailureStatuses() {
        for s in [401, 403, 410, 429, 500, 502, 503] { #expect(MusicLyricsProbe.isHardFailure(status: s)) }
        for s in [200, 204, 304, 404, 400] { #expect(!MusicLyricsProbe.isHardFailure(status: s)) }
    }
}
