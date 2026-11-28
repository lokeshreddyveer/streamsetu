import Foundation
import Testing
@testable import REDDY

// The two sample plugins printed in SAMPLE-PLUGIN.md, extracted from the document itself and run through the real host and adapters with a stub
// transport: search, lookup, lyrics, then audio sources and stream mapping. If the document and the host drift apart, this fails.

private final class RoutedTransport: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    private let routes: @Sendable (URL) -> (Int, String)
    init(_ routes: @escaping @Sendable (URL) -> (Int, String)) { self.routes = routes }
    var urls: [URL] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        lock.withLock { seen.append(url) }
        let (code, body) = routes(url)
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse())
    }
}

private func sampleScripts() throws -> [String] {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/REDDY/Services/Music/Plugins/SAMPLE-PLUGIN.md")
    let text = try String(contentsOf: doc, encoding: .utf8)
    var blocks: [String] = []
    var current: [String] = []
    var inside = false
    for line in text.components(separatedBy: "\n") {
        if line == "```js" { inside = true; current = []; continue }
        if line.hasPrefix("```"), inside { blocks.append(current.joined(separator: "\n")); inside = false; continue }
        if inside { current.append(line) }
    }
    return blocks
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-sample-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func host(_ script: String, caps: [MusicPluginCapability], dir: URL, transport: MusicHTTPTransport) -> (MusicPluginManifest, MusicPluginHost) {
    let m = MusicPluginManifest(id: "example-source", name: "Example Source", version: "1.0.0", author: "Test", summary: "Sample", capabilities: caps,
                                permissions: MusicPluginPermissions(networkHosts: ["api.example.com"], storage: true, crypto: false, signIn: false))
    var http = MusicHTTP(); http.transport = transport
    return (m, MusicPluginHost(manifest: m, script: script, storageURL: dir.appendingPathComponent("s.json"), http: http))
}

@Suite struct PluginSampleEndToEndTests {
    @Test func theDocumentHoldsTwoSamples() throws {
        let blocks = try sampleScripts()
        #expect(blocks.count == 2 && blocks[0].contains("searchTracks") && blocks[1].contains("sources(track)"))
    }

    @Test func metadataSampleSearchesLooksUpAndFindsLyrics() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RoutedTransport { url in
            switch url.path {
            case "/v1/search":
                return (200, #"{"total":45,"items":[{"id":7,"title":"Sample Song","seconds":201.5,"artist_id":3,"artist":"Sample Band","album_id":9,"album":"Sample Album","cover":"https://img.example.com/c.jpg","explicit":true}]}"#)
            case "/v1/tracks/7":
                return (200, #"{"id":7,"title":"Sample Song","seconds":201,"artist_id":3,"artist":"Sample Band"}"#)
            case "/v1/tracks/404":
                return (404, "{}")
            case "/v1/lyrics":
                return (200, #"{"lines":[{"ms":1000,"text":"first line"},{"ms":3000,"text":"second line"}]}"#)
            default:
                return (500, "")
            }
        }
        let (m, h) = host(try sampleScripts()[0], caps: [.metadata, .lyrics], dir: dir, transport: transport)
        let adapters = MusicPluginAdapters.make(manifest: m, host: h)
        let meta = try #require(adapters.first as? PluginMetadataAdapter)

        let page = try await meta.searchTracks("sample & song", page: nil)
        let t = try #require(page.items.first)
        #expect(t.id == "7" && t.providerID == "example-source" && t.title == "Sample Song" && t.durationMs == 201_500 && t.explicit)
        #expect(t.artists.first?.name == "Sample Band" && t.album?.title == "Sample Album" && t.thumbnails.first?.url == "https://img.example.com/c.jpg")
        #expect(page.totalCount == 45 && page.next == .offset(offset: 30, limit: 30))
        let query = transport.urls.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        #expect(query.first { $0.name == "q" }?.value == "sample & song")

        let next = try await meta.searchTracks("sample", page: page.next)
        #expect(next.items.count == 1 && transport.urls.last?.query?.contains("offset=30") == true)

        #expect(try await meta.track(id: "7").title == "Sample Song")
        await #expect(throws: MusicError.notFound) { _ = try await meta.track(id: "404") }

        let lyricsAdapter = try #require(adapters.last as? PluginLyricsAdapter)
        let lyrics = try #require(try await lyricsAdapter.lyrics(for: t))
        #expect(lyrics.synced?.map(\.text) == ["first line", "second line"] && lyrics.synced?.first?.timeMs == 1000)
    }

    @Test func audioSampleProposesSourcesAndMapsStreams() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RoutedTransport { url in
            if url.path == "/v1/find" { return (200, #"{"matches":[{"id":"m1","title":"Sample Song","artist":"Sample Band","ms":201000,"score":0.93},{"id":"m2","title":"Sample Song (live)","artist":"Sample Band","ms":250000,"score":0.4}]}"#) }
            if url.path == "/v1/media/m1" {
                return (200, #"{"files":[{"url":"https://cdn.example.com/m1.m4a","codec":"aac","container":"m4a","kbps":128},{"url":"http://insecure.example.com/m1.mp3","codec":"mp3","container":"mp3","kbps":320}]}"#)
            }
            if url.path == "/v1/media/gone" { return (404, "{}") }
            return (500, "")
        }
        let (m, h) = host(try sampleScripts()[1], caps: [.audio], dir: dir, transport: transport)
        let audio = try #require(MusicPluginAdapters.make(manifest: m, host: h).first as? PluginAudioAdapter)
        let track = MusicTrack(id: "sp1", providerID: "spotify", title: "Sample Song", durationMs: 201_000, artists: [MusicArtistRef(id: "", name: "Sample Band")])

        let sources = try await audio.sources(for: track)
        #expect(sources.map(\.id) == ["m1", "m2"] && sources[0].providerID == "example-source" && sources[0].confidence == 0.93 && sources[0].durationMs == 201_000)
        let find = URLComponents(url: try #require(transport.urls.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(find.first { $0.name == "title" }?.value == "Sample Song" && find.first { $0.name == "artist" }?.value == "Sample Band")

        let streams = try await audio.streams(for: sources[0])
        // Only https addresses survive the adapter.
        #expect(streams.count == 1 && streams[0].url == "https://cdn.example.com/m1.m4a" && streams[0].codec == "aac" && streams[0].bitrate == 128)
        #expect(streams[0].headers["Referer"] == "https://example.com/")

        var gone = sources[0]; gone.id = "gone"
        await #expect(throws: MusicError.notFound) { _ = try await audio.streams(for: gone) }
    }

    @Test func aPluginCannotReachAHostItDidNotDeclare() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RoutedTransport { _ in (200, "{}") }
        let script = "var plugin = { async sources(t) { var r = await host.http.fetch('https://evil.example.org/x'); return []; } };"
        let (m, h) = host(script, caps: [.audio], dir: dir, transport: transport)
        let audio = try #require(MusicPluginAdapters.make(manifest: m, host: h).first as? PluginAudioAdapter)
        await #expect(throws: MusicError.self) { _ = try await audio.sources(for: MusicTrack(id: "1", providerID: "x", title: "T", durationMs: 1, artists: [])) }
        #expect(transport.urls.isEmpty)
    }
}
