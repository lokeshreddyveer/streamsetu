import Testing
import Foundation
@testable import REDDY

@Suite("Xtream decoding") struct XtreamTests {
    let source = PlaylistSource(name: "X", type: .xtream, baseURL: "http://h:80")
    var mapper: XtreamMapper { XtreamMapper(source: source) }

    @Test func leniencyAcrossProviders() throws {
        let json = #"[{"num":1,"name":"One","stream_id":101,"stream_icon":"","epg_channel_id":"one.tv","category_id":"5"},{"num":"2","name":"  Two  ","stream_id":"102","category_id":6},{"name":"No id"},{"stream_id":103,"name":"======== Header ========"}]"#
        let dtos: [XtreamLiveDTO] = try XtreamClient.decodeList(Data(json.utf8), action: "get_live_streams")
        let ch = mapper.channels(dtos, names: ["5": "News", "6": "Sport"])
        #expect(ch.map(\.name) == ["One", "Two"], "missing ids and separator rows are dropped")
        #expect(ch[0].categoryName == "News" && ch[1].categoryName == "Sport")
        #expect(ch[0].logoURL == nil && ch[0].epgID == "one.tv")
        #expect(ch[0].streamRef == "101")
        #expect(ch[0].id == ItemID.make(source: source.id, kind: .channel, provider: "101"))
    }

    @Test func emptySectionsDecodeAsEmpty() throws {
        for body in ["false", "null", "{}", "[]"] {
            let dtos: [XtreamVODDTO] = try XtreamClient.decodeList(Data(body.utf8), action: "get_vod_streams")
            #expect(dtos.isEmpty, "body \(body)")
        }
        #expect(throws: XtreamError.self) { let _: [XtreamVODDTO] = try XtreamClient.decodeList(Data(#"{"user_info":{"auth":0}}"#.utf8), action: "x") }
        #expect(throws: XtreamError.self) { let _: [XtreamVODDTO] = try XtreamClient.decodeList(Data("<html>".utf8), action: "x") }
    }

    @Test func moviesCarryExtensionYearAndAddedDate() throws {
        let json = #"[{"stream_id":7,"name":"Film (2019)","stream_icon":"http://p.jpg","rating":"7.5","added":"1700000000","category_id":"2","container_extension":"mkv"}]"#
        let m = mapper.movies(try XtreamClient.decodeList(Data(json.utf8), action: "v"), names: ["2": "Drama"])
        #expect(m.count == 1)
        #expect(m[0].streamRef == "7.mkv" && m[0].releaseYear == 2019 && m[0].categoryName == "Drama")
        #expect(m[0].addedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func seriesInfoDictionaryAndArrayShapesBothWork() throws {
        let series = Series(id: "sid", sourceID: source.id, providerID: "9", title: "Show", normalizedTitle: "show", overview: nil, posterURL: nil,
                            backdropURL: nil, genre: nil, releaseYear: nil, rating: nil, categoryID: nil, categoryName: nil, addedAt: nil, lastMetadataRefresh: nil)
        let dict = #"{"seasons":[{"season_number":1,"name":"S1"}],"info":{"plot":"A show","genre":"Drama"},"episodes":{"1":[{"id":"501","episode_num":"10","title":"Ten","container_extension":"mp4","info":{"duration_secs":1500}},{"id":"502","episode_num":2,"title":"Two","info":{}}],"2":[{"id":"601","episode_num":1,"title":"S2E1","season":2}]}}"#
        let arr = #"{"episodes":[[{"id":"1","episode_num":1,"title":"A"}],[{"id":"2","episode_num":1,"title":"B"}]]}"#
        let d1 = mapper.seriesDetail(try JSONDecoder().decode(XtreamSeriesInfoDTO.self, from: Data(dict.utf8)), for: series)
        #expect(d1.episodes.map(\.title) == ["Two", "Ten", "S2E1"], "numeric order within season, then next season")
        #expect(d1.seasons.map(\.number) == [1, 2])
        #expect(d1.series.overview == "A show" && d1.series.genre == "Drama")
        #expect(d1.episodes[1].durationSeconds == 1500 && d1.episodes[1].streamRef == "501.mp4")
        let d2 = mapper.seriesDetail(try JSONDecoder().decode(XtreamSeriesInfoDTO.self, from: Data(arr.utf8)), for: series)
        #expect(d2.episodes.map(\.seasonNumber) == [1, 2])
    }

    @Test func streamURLsAreBuiltAtPlaybackTimeFromKeychainCredentials() throws {
        func provider(formats: [String]) -> XtreamProvider {
            var s = source; s.capabilities.outputFormats = formats
            return XtreamProvider(source: s, account: XtreamAccount(base: "http://h:80", user: "us er", pass: "p@ss/w"), http: HTTPClient())
        }
        #expect(try provider(formats: ["ts", "m3u8"]).streamURL(kind: .channel, ref: "12").absoluteString == "http://h:80/live/us%20er/p%40ss%2Fw/12.ts")
        #expect(try provider(formats: ["m3u8"]).streamURL(kind: .channel, ref: "12").pathExtension == "m3u8")
        #expect(try provider(formats: []).streamURL(kind: .movie, ref: "7.mkv").path.hasPrefix("/movie/"))
        #expect(try provider(formats: []).streamURL(kind: .episode, ref: "5.mp4").path.hasPrefix("/series/"))
    }
}
