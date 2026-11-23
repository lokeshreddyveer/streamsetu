import Testing
import Foundation
@testable import REDDY

@Suite("Links and drops") struct DeepLinkTests {
    func link(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.parse) }

    @Test func everySupportedLinkParses() {
        #expect(link("streamsetu://add?url=https%3A%2F%2Fexample.com%2Flist.m3u&name=Mine") == .addPlaylist(address: "https://example.com/list.m3u", name: "Mine"))
        #expect(link("streamsetu://play?channel=BBC%20One%20HD") == .playChannel(name: "BBC One HD"))
        #expect(link("streamsetu://watch?movie=Heat") == .playMovie(title: "Heat") && link("streamsetu://watch?series=The%20Bear") == .findSeries(title: "The Bear"))
        #expect(link("streamsetu://open?tab=live") == .openTab(.liveTV) && link("streamsetu://open?tab=TV%20Guide") == .openTab(.guide))
        #expect(link("streamsetu://search?q=football") == .search("football"))
        #expect(link("streamsetu://sleep?minutes=45") == .sleep(minutes: 45))
        #expect(link("streamsetu://pause") == .remote(.pause) && link("streamsetu://next") == .remote(.next) && link("streamsetu://last") == .remote(.last))
        #expect(link("streamsetu:///play?channel=CNN") == .playChannel(name: "CNN"), "the path form works too")
    }

    @Test func atlasLinksCarryOnlyAPlainId() {
        #expect(link("streamsetu://atlas?id=setting.playback.hardwareDecoding") == .atlas(id: "setting.playback.hardwareDecoding"))
        #expect(link("streamsetu:///atlas?id=screen.ios.tab.guide") == .atlas(id: "screen.ios.tab.guide"))
        #expect(DeepLink.link(atlas: "screen.ios.tab.guide").flatMap(DeepLink.parse) == .atlas(id: "screen.ios.tab.guide"), "built links parse back")
        #expect(link("streamsetu://atlas") == nil && link("streamsetu://atlas?id=") == nil && link("streamsetu://atlas?id=a%20b") == nil)
        #expect(link("streamsetu://atlas?id=..%2F..%2Fetc") == nil && link("streamsetu://atlas?id=a;b") == nil && link("streamsetu://atlas?id=\(String(repeating: "a", count: 101))") == nil)
        #expect(DeepLink.link(atlas: "bad id") == nil)
        #expect(DeepLink.atlas(id: "x").isCommand == false, "an Atlas link opens something, so it waits for the unlock instead of being dropped")
    }

    @Test func badOrDangerousLinksAreRefused() {
        #expect(link("https://example.com/add?url=http://x") == nil, "only the app's own scheme")
        #expect(link("streamsetu://add?url=javascript:alert(1)") == nil)
        #expect(link("streamsetu://add?url=file:///etc/passwd") == nil)
        #expect(link("streamsetu://add") == nil && link("streamsetu://play") == nil && link("streamsetu://play?channel=") == nil)
        #expect(link("streamsetu://watch") == nil && link("streamsetu://watch?movie=") == nil)
        #expect(link("streamsetu://sleep?minutes=0") == nil && link("streamsetu://sleep?minutes=9999") == nil && link("streamsetu://sleep?minutes=abc") == nil)
        #expect(link("streamsetu://open?tab=settings") == nil && link("streamsetu://delete") == nil && link("streamsetu://remove?all=1") == nil, "nothing destructive exists")
        #expect(link("streamsetu://add?url=http://x\(String(repeating: "a", count: 2100))") == nil)
        #expect(link("streamsetu://play?channel=\(String(repeating: "a", count: 200))") == nil)
    }

    @Test func droppedFilesAndTextBecomeAPendingAddAndNeverAnAutomaticOne() {
        #expect(PendingAdd.fromFile(URL(fileURLWithPath: "/tmp/list.m3u")) == .file(URL(fileURLWithPath: "/tmp/list.m3u")))
        #expect(PendingAdd.fromFile(URL(fileURLWithPath: "/tmp/list.M3U8")) != nil)
        #expect(PendingAdd.fromFile(URL(fileURLWithPath: "/tmp/photo.png")) == nil && PendingAdd.fromFile(URL(string: "https://x/list.m3u")!) == nil)
        #expect(PendingAdd.fromText("  http://host:8080/get.php?username=a&password=b&type=m3u  ") == .address("http://host:8080/get.php?username=a&password=b&type=m3u", name: nil))
        #expect(PendingAdd.fromText("just some words") == nil && PendingAdd.fromText("ftp://host/list.m3u") == nil && PendingAdd.fromText("") == nil)
    }
}
