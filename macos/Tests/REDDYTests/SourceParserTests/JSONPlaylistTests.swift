import Testing
import Foundation
@testable import REDDY

@Suite struct JSONPlaylistTests {
    @Test func arrayOfChannels() {
        let json = #"[{"name":"News \"One\"","url":"http://h/1.m3u8","logo":"http://h/l.png","group":"News","tvg_id":"n1"},{"title":"No stream"},{"name":"Two","stream_url":"http://h/2.ts"}]"#
        let m3u = JSONPlaylist.m3u(from: Data(json.utf8))
        #expect(m3u?.contains("tvg-id=\"n1\"") == true)
        #expect(m3u?.contains("group-title=\"News\"") == true)
        #expect(m3u?.contains("News 'One'") == true)        // quotes cannot break the M3U line
        #expect(m3u?.components(separatedBy: "#EXTINF").count == 3)   // the entry without a stream is dropped
    }

    @Test func wrappedInAnObject() {
        let json = #"{"channels":[{"name":"A","url":"https://h/a.m3u8"}]}"#
        #expect(JSONPlaylist.m3u(from: Data(json.utf8)) != nil)
    }

    @Test func hdHomeRunLineup() {
        let json = #"[{"GuideNumber":"2.1","GuideName":"KABC","HD":1,"URL":"http://192.168.1.50:5004/auto/v2.1"}]"#
        let m3u = JSONPlaylist.m3u(from: Data(json.utf8))
        #expect(m3u?.contains("tvg-chno=\"2.1\"") == true && m3u?.contains(",KABC") == true && m3u?.contains("auto/v2.1") == true)
    }

    @Test func notAPlaylist() {
        #expect(JSONPlaylist.m3u(from: Data(#"{"hello":"world"}"#.utf8)) == nil)
        #expect(JSONPlaylist.m3u(from: Data("not json".utf8)) == nil)
        #expect(JSONPlaylist.looksLikeJSON(Data("  [".utf8)) && !JSONPlaylist.looksLikeJSON(Data("#EXTM3U".utf8)))
    }

    @Test func moreStreamingSchemesArePlayable() {
        for s in ["udp://239.0.0.1:1234", "rtp://239.0.0.1:5004", "srt://h:9000", "rtmps://h/live", "http://h/a"] {
            #expect(SourceURLValidator.isPlayableScheme(URL(string: s)!))
        }
        #expect(!SourceURLValidator.isPlayableScheme(URL(string: "file:///etc/passwd")!))
        #expect(StreamCapabilities.container(for: URL(string: "udp://239.0.0.1:1234")!) == .rtsp)
    }
}
