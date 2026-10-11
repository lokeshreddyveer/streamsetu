import Testing
import Foundation
@testable import REDDY

@Suite struct SourceDetectorTests {
    private func d(_ s: String) -> DetectedSource? { SourceDetector.detect(s) }

    @Test func xtreamLinksFillTheLogin() {
        let x = d("http://host.example:8080/get.php?username=bob&password=s3cret&type=m3u_plus&output=ts")
        #expect(x?.kind == .xtream && x?.server == "http://host.example:8080" && x?.username == "bob" && x?.password == "s3cret")
        #expect(d("https://h.example/panel/player_api.php?username=a&password=b")?.server == "https://h.example/panel")
    }

    @Test func serversByPortAndPath() {
        #expect(d("http://nas:32400/web/index.html")?.kind == .plex)
        #expect(d("http://nas:32400/?X-Plex-Token=abc")?.password == "abc")
        #expect(d("http://nas:8096")?.kind == .jellyfin && d("http://nas/emby")?.kind == .emby)
        #expect(d("http://pi:9981")?.kind == .tvheadend && d("http://pi/playlist/channels.m3u")?.kind == .tvheadend)
        #expect(d("http://portal.example/stalker_portal/c/")?.kind == .stalker && d("http://p.example/c")?.kind == .stalker)
        #expect(d("http://192.168.1.50/web/getservices")?.kind == .enigma2)
        #expect(d("http://192.168.1.60/lineup.json")?.kind == .hdhomerun && d("http://hdhomerun.local")?.kind == .hdhomerun)
    }

    @Test func playlistsAndStreams() {
        #expect(d("https://x.example/list.m3u")?.kind == .m3uURL && d("https://x.example/list.m3u8")?.kind == .m3uURL)
        #expect(d("https://x.example/channels.json")?.kind == .m3uURL)
        #expect(d("https://x.example/stream.ts")?.kind == .stream && d("https://x.example/radio.mp3")?.kind == .stream)
        #expect(d("rtsp://cam.local/live")?.kind == .stream && d("udp://239.0.0.1:1234")?.kind == .stream && d("srt://h:9000")?.kind == .stream)
        #expect(d("https://x.example/something")?.kind == .m3uURL)
    }

    @Test func nonAddressesAreIgnored() {
        #expect(d("") == nil && d("hello there") == nil && d("not a url") == nil && d("ftp://x/y") == nil && d("file:///etc/passwd") == nil)
        #expect(d("http://a\nhttp://b") == nil)
    }

    @Test func directStreamsAreNotDownloadedAsPlaylists() {
        #expect(SourceDetector.isDirectStream(URL(string: "https://h/a.ts")!) && SourceDetector.isDirectStream(URL(string: "rtsp://h/a")!))
        #expect(!SourceDetector.isDirectStream(URL(string: "https://h/list.m3u8")!) && !SourceDetector.isDirectStream(URL(string: "https://h/get.php?username=a")!))
    }
}

@Suite struct Enigma2Tests {
    private let source = PlaylistSource(name: "Sat", type: .enigma2, baseURL: "http://192.168.1.50")

    @Test func channelsByBouquetSkipMarkers() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"{"result":true,"services":[{"servicename":"Favourites (TV)","subservices":[{"servicereference":"1:0:19:283D:3FB:1:C00000:0:0:0:","servicename":"Das Erste HD"},{"servicereference":"1:64:1:0:0:0:0:0:0:0::-----","servicename":"-----"},{"servicereference":"1:0:19:283D:3FB:1:C00000:0:0:0:","servicename":"Duplicate"}]},{"servicename":"Empty","subservices":[]}]}"#.utf8)) as! [String: Any]
        let m = Enigma2Mapper(source: source).channels(json)
        #expect(m.channels.count == 1 && m.channels[0].name == "Das Erste HD" && m.bouquets.count == 1 && m.bouquets[0].name == "Favourites (TV)")
    }

    @Test func streamUrlUsesTheStreamPortAndLogin() throws {
        let p = Enigma2Provider(source: source, user: "root", pass: "pw", http: HTTPClient())
        let u = try p.streamURL(kind: .channel, ref: "1:0:19:283D:3FB:1:C00000:0:0:0:")
        #expect(u.port == 8001 && u.user == "root" && u.password == "pw" && u.path.hasPrefix("/1:0:19"))
        let open = try Enigma2Provider(source: source, user: nil, pass: nil, http: HTTPClient()).streamURL(kind: .channel, ref: "1:0:1:1:1:1:1:0:0:0:")
        #expect(open.user == nil && open.port == 8001)
    }
}
