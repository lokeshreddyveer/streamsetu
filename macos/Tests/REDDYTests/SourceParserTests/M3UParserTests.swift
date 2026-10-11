import Testing
import Foundation
@testable import REDDY

@Suite("M3U parsing") struct M3UParserTests {
    private func parse(_ text: String, chunk: Int = 1 << 20) -> (entries: [M3UEntry], header: M3UHeader, skipped: Int) {
        var p = M3UStreamParser()
        var out: [M3UEntry] = []
        let data = Data(text.utf8)
        var i = 0
        while i < data.count {
            let end = min(i + chunk, data.count)
            p.feed(data.subdata(in: i..<end)) { out.append($0) }
            i = end
        }
        p.finish { out.append($0) }
        return (out, p.header, p.skippedLines)
    }

    @Test func parsesAttributesAndName() {
        let r = parse("""
        #EXTM3U url-tvg="http://e/x.xml.gz,http://e/y.xml"
        #EXTINF:-1 tvg-id="ex.tv" tvg-name="Example" tvg-logo="http://l/a.png" group-title="News, World",Example TV
        http://s/1.m3u8
        """)
        #expect(r.entries.count == 1)
        let e = r.entries[0]
        #expect(e.name == "Example TV")
        #expect(e.tvgID == "ex.tv")
        #expect(e.groupTitle == "News, World")     // comma inside quotes must not split the name
        #expect(e.logo == "http://l/a.png")
        #expect(r.header.epgURLs == ["http://e/x.xml.gz", "http://e/y.xml"])
    }

    @Test func handlesCRLFAndBOM() {
        let r = parse("\u{FEFF}#EXTM3U\r\n#EXTINF:-1,One\r\nhttp://s/1.ts\r\n#EXTINF:-1,Two\r\nhttp://s/2.ts\r\n")
        #expect(r.entries.map(\.name) == ["One", "Two"])
        #expect(r.entries.map(\.url) == ["http://s/1.ts", "http://s/2.ts"])
    }

    @Test func chunkBoundariesDoNotMatter() {
        func block(_ i: Int) -> String {
            let group = i % 5
            return "#EXTINF:-1 group-title=\"G\(group)\",Chan \(i)\nhttp://s/\(i).ts\n"
        }
        let text = "#EXTM3U\n" + (0..<200).map(block).joined()
        let whole = parse(text)
        for size in [1, 7, 64, 1000] {
            let r = parse(text, chunk: size)
            #expect(r.entries == whole.entries, "chunk size \(size)")
        }
        #expect(whole.entries.count == 200)
    }

    @Test func missingMetadataStillProducesEntry() {
        let r = parse("#EXTM3U\n#EXTINF:-1,\nhttp://s/1.ts\nhttp://s/bare-name.ts\n")
        #expect(r.entries.count == 2)
        #expect(r.entries[0].name == "Unnamed")
        #expect(r.entries[1].name == "bare-name")
    }

    @Test func oversizedLinesAreSkippedNotFatal() {
        var p = M3UStreamParser(maxLineBytes: 100)
        var out: [M3UEntry] = []
        p.feed(Data(("#EXTM3U\n#EXTINF:-1,Ok\nhttp://s/ok.ts\n" + String(repeating: "x", count: 500) + "\n#EXTINF:-1,Two\nhttp://s/2.ts\n").utf8)) { out.append($0) }
        p.finish { out.append($0) }
        #expect(out.map(\.name) == ["Ok", "Two"])
        #expect(p.skippedLines == 1)
    }

    @Test func detectsHLSManifestVersusCatalog() {
        let hls = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts\n".utf8)
        let cat = Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"a\",A\nhttp://s/a.m3u8\n".utf8)
        #expect(M3UValidator.detect(head: hls) == .hlsManifest)
        #expect(M3UValidator.detect(head: cat) == .catalog)
        #expect(M3UValidator.detect(head: Data("<html>nope</html>".utf8)) == .invalid)
    }

    @Test func resolvesRelativeURLsAndRejectsBadSchemes() {
        let base = URL(string: "http://host/dir/list.m3u")!
        let rel = M3UValidator.validate(M3UEntry(name: "A", url: "stream/1.ts"), base: base)
        #expect(rel?.url == "http://host/dir/stream/1.ts")
        #expect(M3UValidator.validate(M3UEntry(name: "A", url: "file:///etc/passwd"), base: base) == nil)
        #expect(M3UValidator.validate(M3UEntry(name: "A", url: "javascript:alert(1)"), base: base) == nil)
        #expect(M3UValidator.validate(M3UEntry(name: "A", url: "rtsp://h/x"), base: base) != nil)
    }
}
