import Testing
import Foundation
@testable import REDDY

private final class KeylessStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil)
        return (Data(body.utf8), resp ?? HTTPURLResponse())
    }
}

private final class KeylessMemoryStore: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ value: String, account: String) { lock.lock(); values[account] = value; lock.unlock() }
    func remove(_ account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

private func http(_ stub: KeylessStub) -> MusicHTTP { MusicHTTP(transport: stub) }

private let sampleTrack = MusicTrack(id: "t1", providerID: "x", title: "Song", durationMs: 200_000,
                                     artists: [MusicArtistRef(id: "a", name: "Artist")], album: MusicAlbumRef(id: "al", title: "Album"))

@Suite struct KeylessProvidersTests {

    // MARK: Audius

    @Test func audiusTrackMapping() throws {
        let json = """
        {"id":"D7KyD","title":"Sunrise","duration":215,"play_count":1234,"permalink":"/artist/sunrise",
         "is_streamable":true,
         "artwork":{"150x150":"https://c/150.jpg","480x480":"https://c/480.jpg"},
         "user":{"id":"u1","name":"Artist One","handle":"artist"}}
        """
        let d = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let t = try #require(AudiusProvider.mapTrack(d, host: "https://disc.example"))
        #expect(t.id == "D7KyD" && t.providerID == "audius" && t.title == "Sunrise")
        #expect(t.durationMs == 215_000 && t.artistLine == "Artist One" && t.popularity == 1234)
        #expect(t.thumbnails.map(\.width) == [150, 480])
        #expect(t.externalURL == "https://audius.co/artist/sunrise")
        let s = try #require(t.directStreams?.first)
        #expect(s.url == "https://disc.example/v1/tracks/D7KyD/stream?app_name=StreamSetu" && s.bitrate == 320 && s.proto == .progressive)
    }

    @Test func audiusMappingToleratesMissingFields() {
        #expect(AudiusProvider.mapTrack([:], host: "h") == nil)
        let t = AudiusProvider.mapTrack(["id": "1", "title": "Bare"], host: "https://h")
        #expect(t?.artists.first?.name == "Unknown artist" && t?.artistLine == "" && t?.durationMs == 0)   // the data keeps what the source said; the line shown to people does not repeat the filler
    }

    @Test func audiusSearchUsesDirectoryHostAndAppName() async throws {
        let stub = KeylessStub { r in
            if r.url?.host == "api.audius.co" { return (200, #"{"data":["https://node1.example"]}"#) }
            return (200, #"{"data":[{"id":"1","title":"A","duration":10,"user":{"id":"u","name":"N"}}]}"#)
        }
        let page = try await AudiusProvider(http: http(stub)).searchTracks("hello", page: .offset(offset: 0, limit: 1))
        #expect(page.items.count == 1)
        #expect(page.next == .offset(offset: 1, limit: 1))
        let call = try #require(stub.requests.last?.url?.absoluteString)
        #expect(call.hasPrefix("https://node1.example/v1/tracks/search") && call.contains("app_name=StreamSetu") && call.contains("query=hello"))
    }

    @Test func audiusFailsOverToAnotherHost() async throws {
        let stub = KeylessStub { r in
            switch r.url?.host {
            case "api.audius.co": return (200, #"{"data":["https://bad.example","https://good.example"]}"#)
            case "bad.example": return (500, "")
            default: return (200, #"{"data":[]}"#)
            }
        }
        // Whichever host is picked first, the call must end up served by the good one.
        _ = try await AudiusProvider(http: http(stub)).searchTracks("x", page: nil)
        #expect(stub.requests.last?.url?.host == "good.example")
    }

    // MARK: JioSaavn

    @Test func saavnSearchMapping() throws {
        let json = """
        {"total":1,"start":1,"results":[{"id":"abc","title":"Tum &amp; Hum","type":"song","image":"https://c.saavncdn.com/x/150x150.jpg",
          "explicit_content":"0","perma_url":"https://www.jiosaavn.com/song/x",
          "more_info":{"album":"Film &quot;One&quot;","album_id":"al1","duration":"240","320kbps":"true",
            "encrypted_media_url":"SECRET","media_preview_url":"https://preview.saavncdn.com/123/abc_96_p.mp4",
            "artistMap":{"primary_artists":[{"id":"ar1","name":"Singer"}]}}}]}
        """
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let t = try #require(obj.array("results").compactMap(JioSaavnProvider.mapSong).first)
        #expect(t.title == "Tum & Hum" && t.durationMs == 240_000 && t.artistLine == "Singer")
        #expect(t.album?.id == "al1" && t.album?.title == "Film \"One\"")
        #expect(t.thumbnails.last?.url.contains("500x500") == true)
        // A 30 second preview address is not full audio and the encrypted field is never read, so the track is metadata only.
        #expect(t.directStreams == nil)
    }

    @Test func saavnWithoutPlainUrlHasNoStream() throws {
        let d: [String: Any] = ["id": "1", "title": "T", "more_info": ["encrypted_media_url": "xyz"]]
        let t = try #require(JioSaavnProvider.mapSong(d))
        #expect(t.directStreams == nil)
    }

    @Test func saavnSearchPagesAndRequestShape() async throws {
        let stub = KeylessStub { _ in (200, #"{"total":100,"results":[{"id":"1","title":"A"},{"id":"2","title":"B"}]}"#) }
        let page = try await JioSaavnProvider(http: http(stub)).searchTracks("q", page: .page(1, size: 2))
        #expect(page.items.count == 2 && page.next == .page(2, size: 2))
        let url = try #require(stub.requests.first?.url?.absoluteString)
        #expect(url.contains("__call=search.getResults") && url.contains("ctx=web6dot0") && url.contains("q=q"))
    }

    // MARK: iTunes

    @Test func itunesLookupMapping() async throws {
        let json = """
        {"resultCount":3,"results":[
         {"wrapperType":"collection","collectionType":"Album","collectionId":10,"artistId":5,"artistName":"Band","collectionName":"Record",
          "artworkUrl100":"https://i/100x100bb.jpg","releaseDate":"2019-05-03T07:00:00Z","trackCount":2},
         {"wrapperType":"track","kind":"song","trackId":101,"trackName":"Two","collectionId":10,"collectionName":"Record","artistId":5,"artistName":"Band",
          "trackNumber":2,"discNumber":1,"trackTimeMillis":180000,"trackExplicitness":"explicit","previewUrl":"https://p/x.m4a","artworkUrl100":"https://i/100x100bb.jpg"},
         {"wrapperType":"track","kind":"song","trackId":100,"trackName":"One","collectionId":10,"artistId":5,"artistName":"Band","trackNumber":1,"discNumber":1}]}
        """
        let stub = KeylessStub { _ in (200, json) }
        let p = ITunesProvider(http: http(stub))
        let album = try await p.album(id: "10")
        #expect(album.title == "Record" && album.releaseDate == "2019-05-03" && album.totalTracks == 2)
        let tracks = try await p.albumTracks(id: "10", page: nil).items
        #expect(tracks.map(\.title) == ["One", "Two"])
        let two = try #require(tracks.last)
        #expect(two.explicit && two.durationMs == 180_000 && two.directStreams == nil && two.externalURL == nil)
        #expect(two.thumbnails.last?.url == "https://i/600x600bb.jpg")
        #expect(two.album?.id == "10")
    }

    // MARK: LRCLIB

    @Test func lrcMultiStampAndOffset() {
        let text = """
        [ar:Someone]
        [offset:+500]
        [00:05.123]first
        [00:12.00][01:30.5]chorus
        [00:20]no fraction
        not a lyric line
        """
        let lines = MusicLyricsParsers.parseLRC(text)
        #expect(lines.map(\.text) == ["first", "chorus", "no fraction", "chorus"])
        #expect(lines.map(\.timeMs) == [4623, 11500, 19500, 90000])
    }

    @Test func lrcClampsNegativeAndSorts() {
        let lines = MusicLyricsParsers.parseLRC("[00:10.00]b\n[offset:+20000]\n[00:01.00]a")
        #expect(lines.map(\.timeMs) == [0, 0])
        #expect(MusicLyricsParsers.parseLRC("").isEmpty)
    }

    @Test func lrclibFallsBackToSearch() async throws {
        let stub = KeylessStub { r in
            if r.url?.path == "/api/get" { return (404, "") }
            return (200, #"[{"instrumental":false,"duration":300,"plainLyrics":"far"},{"instrumental":false,"duration":201,"syncedLyrics":"[00:01.00]hi","plainLyrics":"hi"}]"#)
        }
        let l = try await LRCLibProvider(http: http(stub)).lyrics(for: sampleTrack)
        #expect(l?.synced?.first?.text == "hi" && l?.plain == "hi" && l?.sourceName == "LRCLIB")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("StreamSetu-Music") == true)
    }

    @Test func lrclibNothingFoundIsNil() async throws {
        let stub = KeylessStub { _ in (404, "") }
        #expect(try await LRCLibProvider(http: http(stub)).lyrics(for: sampleTrack) == nil)
    }

    // MARK: ListenBrainz

    @Test func listenBrainzPayloadShape() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let single = try #require(try JSONSerialization.jsonObject(with: ListenBrainzProvider.payload(listenType: "single", track: sampleTrack, listenedAt: when, playedMs: 100_000)) as? [String: Any])
        #expect(single["listen_type"] as? String == "single")
        let listen = try #require((single["payload"] as? [[String: Any]])?.first)
        #expect(listen["listened_at"] as? Int == 1_700_000_000)
        let meta = try #require(listen["track_metadata"] as? [String: Any])
        #expect(meta["track_name"] as? String == "Song" && meta["artist_name"] as? String == "Artist" && meta["release_name"] as? String == "Album")

        let now = try #require(try JSONSerialization.jsonObject(with: ListenBrainzProvider.payload(listenType: "playing_now", track: sampleTrack, listenedAt: nil, playedMs: nil)) as? [String: Any])
        let nowListen = try #require((now["payload"] as? [[String: Any]])?.first)
        #expect(now["listen_type"] as? String == "playing_now" && nowListen["listened_at"] == nil)
    }

    @Test func listenBrainzTokenValidationAndSubmit() async throws {
        let store = KeylessMemoryStore()
        let stub = KeylessStub { r in
            if r.url?.path.hasSuffix("validate-token") == true {
                return (200, r.value(forHTTPHeaderField: "Authorization") == "Token good" ? #"{"valid":true,"user_name":"me"}"# : #"{"valid":false}"#)
            }
            return (200, #"{"status":"ok"}"#)
        }
        let p = ListenBrainzProvider(http: http(stub), store: store)
        await #expect(throws: MusicError.self) { try await p.setToken("bad") }
        #expect(await p.isSignedIn == false)
        try await p.setToken("good")
        #expect(await p.isSignedIn)
        try await p.scrobble(MusicScrobble(timestamp: Date(timeIntervalSince1970: 5), track: sampleTrack, playedMs: 1))
        let last = try #require(stub.requests.last)
        #expect(last.url?.path.hasSuffix("submit-listens") == true && last.httpMethod == "POST")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Token good")
        await p.signOut()
        #expect(await p.isSignedIn == false)
    }

    // MARK: Last.fm

    @Test func lastFMSignature() {
        #expect(LastFMProvider.md5Hex("hello") == "5d41402abc4b2a76b9719d911017c592")
        // md5("abhello"): parameters sorted by name, name+value, then the secret; format is excluded.
        #expect(LastFMProvider.signature(["a": "b", "format": "json"], secret: "hello") == "69102f689bf714f58ac6c17082930c10")
        #expect(LastFMProvider.signature(["a": "b"], secret: "hello") == "69102f689bf714f58ac6c17082930c10")
    }

    @Test func lastFMScrobbleRequest() async throws {
        let stub = KeylessStub { _ in (200, #"{"scrobbles":{}}"#) }
        let p = LastFMProvider(http: http(stub), store: KeylessMemoryStore())
        await #expect(throws: MusicError.self) { try await p.scrobble(MusicScrobble(timestamp: Date(), track: sampleTrack, playedMs: 1)) }
        await p.setCredentials(apiKey: "key", secret: "sec", sessionKey: "sk")
        try await p.scrobble(MusicScrobble(timestamp: Date(timeIntervalSince1970: 42), track: sampleTrack, playedMs: 1))
        let req = try #require(stub.requests.last)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("method=track.scrobble") && body.contains("timestamp=42") && body.contains("api_sig="))
        #expect(!body.contains("secret="))
    }

    @Test func lastFMErrorReplyMapsToSignedOut() async throws {
        let stub = KeylessStub { _ in (200, #"{"error":9,"message":"Invalid session key"}"#) }
        let p = LastFMProvider(http: http(stub), store: KeylessMemoryStore())
        await p.setCredentials(apiKey: "k", secret: "s", sessionKey: "x")
        await #expect(throws: MusicError.notSignedIn("Last.fm")) { try await p.scrobble(MusicScrobble(timestamp: Date(), track: sampleTrack, playedMs: 1)) }
    }
}
