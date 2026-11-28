import Foundation
import Testing
@testable import REDDY

private struct StubTransport: MusicHTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body) = handler(request)
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private func stubHTTP(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> MusicHTTP {
    MusicHTTP(transport: StubTransport(handler: handler))
}

private func signedInSpotify(_ http: MusicHTTP) -> SpotifyProvider {
    let store = MemorySpotifySecretStore([
        "spotify.clientID": "cid", "spotify.accessToken": "tok", "spotify.refreshToken": "ref",
        "spotify.expiry": String(Date().addingTimeInterval(3600).timeIntervalSince1970)
    ])
    return SpotifyProvider(http: http, auth: SpotifyAuth(http: http, store: store))
}

private let sampleTrack = MusicTrack(id: "t1", providerID: "spotify", title: "Lose Yourself", durationMs: 326_000,
                                     artists: [MusicArtistRef(id: "a1", name: "Eminem")])

@Suite struct SpotifyTests {
    @Test func pkceMatchesRFC7636Vector() {
        #expect(SpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = SpotifyPKCE.makeVerifier()
        #expect(v.count >= 43 && v.count <= 128)
    }

    @Test func authorizeURLCarriesChallengeAndNoSecret() throws {
        let u = try #require(SpotifyAuth.authorizeURL(clientID: "cid", redirectURI: "http://127.0.0.1:43821/callback", challenge: "CH", state: "ST"))
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code_challenge" }?.value == "CH")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(!items.contains { $0.name.contains("secret") })
    }

    @Test func trackMapping() async throws {
        let json = """
        {"id":"t1","name":"Lose Yourself","duration_ms":326000,"track_number":1,"disc_number":1,"explicit":true,"popularity":80,
         "external_ids":{"isrc":"USIR10211111"},"external_urls":{"spotify":"https://open.spotify.com/track/t1"},
         "artists":[{"id":"a1","name":"Eminem"}],
         "album":{"id":"al1","name":"8 Mile","album_type":"album","release_date":"2002-10-29","total_tracks":17,
                  "images":[{"url":"https://img/640","width":640,"height":640},{"url":"https://img/64","width":64,"height":64}],
                  "artists":[{"id":"a1","name":"Eminem"}]}}
        """
        let p = signedInSpotify(stubHTTP { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (200, json)
        })
        let t = try await p.track(id: "t1")
        #expect(t.uid == "spotify:t1")
        #expect(t.title == "Lose Yourself")
        #expect(t.durationMs == 326_000)
        #expect(t.isrc == "USIR10211111")
        #expect(t.explicit)
        #expect(t.artistLine == "Eminem")
        #expect(t.album?.title == "8 Mile")
        #expect(t.thumbnails.best(minSide: 600) == "https://img/640")
    }

    @Test func albumTracksAttachAlbumInfo() async throws {
        let album = #"{"id":"al1","name":"8 Mile","images":[{"url":"https://img/300","width":300,"height":300}],"artists":[{"id":"a1","name":"Eminem"}],"total_tracks":2}"#
        let tracks = #"{"total":2,"next":null,"items":[{"id":"t1","name":"One","duration_ms":1000,"artists":[{"id":"a1","name":"Eminem"}]},null,{"id":"t2","name":"Two","duration_ms":2000,"artists":[]}]}"#
        let p = signedInSpotify(stubHTTP { req in
            (200, (req.url?.path ?? "").hasSuffix("/tracks") ? tracks : album)
        })
        let page = try await p.albumTracks(id: "al1", page: nil)
        #expect(page.items.map(\.title) == ["One", "Two"])
        #expect(page.items.allSatisfy { $0.album?.id == "al1" })
        #expect(page.next == nil)
        #expect(page.totalCount == 2)
    }

    @Test func forbiddenEndpointsDegradeToEmpty() async throws {
        let p = signedInSpotify(stubHTTP { _ in (403, "{}") })
        #expect(try await p.relatedArtists(id: "a1").isEmpty)
        #expect(try await p.artistTopTracks(id: "a1").isEmpty)
        #expect(try await p.featured().isEmpty)
        #expect(try await p.genres().isEmpty)
    }

    @Test func signedOutOpensItemsFromTheEmbedPageInsteadOfThrowing() async throws {
        let json = #"{"props":{"pageProps":{"state":{"data":{"entity":{"type":"track","name":"Open Song","id":"t1","duration":1000,"artists":[{"name":"X","uri":"spotify:artist:a1"}]}}}}}}"#
        let http = stubHTTP { req in (200, req.url?.host == "open.spotify.com" ? "<script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script>" : "{}") }
        let p = SpotifyProvider(http: http, auth: SpotifyAuth(http: http, store: MemorySpotifySecretStore()))
        #expect(try await p.track(id: "t1").title == "Open Song")
    }
}

@Suite struct YouTubeAudioProviderTests {
    private func instances(_ kind: YouTubeInstances.Kind, _ http: MusicHTTP, _ urls: [String]) -> YouTubeInstances {
        YouTubeInstances(http: http, fixed: [kind: urls.compactMap(URL.init(string:))])
    }

    @Test func pipedPicksBestAudioFirstAndParsesExpiry() async throws {
        let json = """
        {"audioStreams":[
          {"url":"https://p/low?expire=1900000000","format":"M4A","mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":128000},
          {"url":"https://p/high?expire=1900000000","format":"WEBMA_OPUS","mimeType":"audio/webm; codecs=\\"opus\\"","bitrate":160000},
          {"url":"https://p/video","mimeType":"video/mp4; codecs=\\"avc1\\"","bitrate":900000,"videoOnly":true}]}
        """
        let http = stubHTTP { _ in (200, json) }
        let p = PipedProvider(http: http, instances: instances(.piped, http, ["https://piped.test"]))
        let src = MusicAudioSource(id: "abcdefghijk", providerID: "piped", title: "x", artist: nil, album: nil, durationMs: nil, externalURL: nil, confidence: 1)
        let s = try await p.streams(for: src)
        #expect(s.count == 2)
        #expect(s[0].codec == "opus" && s[0].container == "webm" && s[0].bitrate == 160)
        #expect(s[1].codec == "aac" && s[1].container == "m4a")
        #expect(s[0].expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func pipedFallsBackToNextInstance() async throws {
        let ok = #"{"items":[{"url":"/watch?v=vid00000001","title":"Lose Yourself","uploaderName":"Eminem - Topic","duration":326}]}"#
        let http = stubHTTP { req in req.url?.host == "bad.test" ? (500, "") : (200, ok) }
        let p = PipedProvider(http: http, instances: instances(.piped, http, ["https://bad.test", "https://good.test"]))
        let r = try await p.sources(for: sampleTrack)
        #expect(r.first?.id == "vid00000001")
        #expect((r.first?.confidence ?? 0) > 0.9)
    }

    @Test func invidiousMapping() async throws {
        let search = #"[{"type":"video","title":"Lose Yourself","videoId":"vid00000002","author":"Eminem - Topic","lengthSeconds":326,"videoThumbnails":[{"quality":"medium","url":"https://t/1.jpg"}]},{"type":"channel","author":"x"}]"#
        let video = #"{"adaptiveFormats":[{"type":"audio/webm; codecs=\"opus\"","url":"/videoplayback?id=1&expire=1900000000","bitrate":"130000","audioSampleRate":"48000"},{"type":"video/mp4; codecs=\"avc1\"","url":"https://v","bitrate":"500000"},{"type":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://i/a","bitrate":"128000"}]}"#
        let http = stubHTTP { req in (200, (req.url?.path ?? "").contains("/search") ? search : video) }
        let p = InvidiousProvider(http: http, instances: instances(.invidious, http, ["https://inv.test"]))
        let src = try #require(try await p.sources(for: sampleTrack).first)
        #expect(src.id == "vid00000002" && src.durationMs == 326_000 && src.thumbnails.first?.url == "https://t/1.jpg")
        let streams = try await p.streams(for: src)
        #expect(streams.count == 2)
        #expect(streams[0].url.hasPrefix("https://inv.test/videoplayback"))
        #expect(streams[0].bitrate == 130 && streams[0].sampleRate == 48000 && streams[0].codec == "opus")
    }

    @Test func youTubeMusicSongParsing() {
        let json = """
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":[
        {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"vid00000003"},
          "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/1","width":60,"height":60}]}}},
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Lose Yourself"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
              {"text":"Eminem","navigationEndpoint":{"browseEndpoint":{"browseId":"UCedvOgsKFzcK3hA5taf3KoQ"}}},
              {"text":" \\u2022 "},
              {"text":"8 Mile","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_abc"}}},
              {"text":" \\u2022 "},{"text":"5:26"}]}}}]}}]}}]}}}}]}}}
        """
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        let songs = YouTubeMusicProvider.parseSongs(obj ?? [:])
        #expect(songs.count == 1)
        #expect(songs.first?.durationMs == 326_000)
        #expect(songs.first?.artistLine == "Eminem")
        #expect(songs.first?.album?.title == "8 Mile")
    }

    @Test func youTubeMusicSkipsCipheredFormats() {
        let obj: [String: Any] = ["streamingData": ["adaptiveFormats": [
            ["mimeType": "audio/webm; codecs=\"opus\"", "signatureCipher": "s=abc&url=x", "bitrate": 100_000],
            ["mimeType": "audio/webm; codecs=\"opus\"", "url": "https://g/a?expire=1900000000", "bitrate": 130_000, "averageBitrate": 120_000]]]]
        let s = YouTubeMusicProvider.parseStreams(obj, headers: [:])
        #expect(s.count == 1 && s[0].bitrate == 120)
    }
}

@Suite struct MusicTextMatchTests {
    private func score(_ title: String, _ channel: String?, _ ms: Int64?) -> Float {
        MusicTextMatch.score(trackTitle: "Lose Yourself", artists: ["Eminem"], durationMs: 326_000,
                             candidateTitle: title, candidateArtist: channel, candidateDurationMs: ms)
    }

    @Test func officialBeatsLiveAndCover() {
        let official = score("Lose Yourself", "Eminem - Topic", 326_000)
        let officialAudio = score("Eminem - Lose Yourself (Official Audio)", "EminemVEVO", 327_000)
        let live = score("Eminem - Lose Yourself (Live)", "Eminem", 330_000)
        let cover = score("Lose Yourself (Cover)", "Some Guy", 326_000)
        #expect(official > 0.9)
        #expect(officialAudio > live)
        #expect(official > live)
        #expect(official > cover)
    }

    @Test func durationWindow() {
        let inside = score("Lose Yourself", "Eminem", 329_000)
        let near = score("Lose Yourself", "Eminem", 340_000)
        let far = score("Lose Yourself", "Eminem", 480_000)
        #expect(inside > near)
        #expect(near > far)
        #expect(MusicTextMatch.durationScore(326_000, 331_000) == 1)
    }

    @Test func markersCountOnlyWhenTrackLacksThem() {
        let plain = MusicTextMatch.score(trackTitle: "Song", artists: ["A"], durationMs: 200_000, candidateTitle: "Song (Sped Up)", candidateArtist: "A", candidateDurationMs: 200_000)
        let wanted = MusicTextMatch.score(trackTitle: "Song (Sped Up)", artists: ["A"], durationMs: 200_000, candidateTitle: "Song (Sped Up)", candidateArtist: "A", candidateDurationMs: 200_000)
        #expect(wanted > plain)
        #expect(MusicTextMatch.markers(in: "Song (Live at Wembley)").contains(.live))
    }

    @Test func normalisingIgnoresAccentsAndFeatTails() {
        #expect(MusicTextMatch.normalize("Beyoncé – Halo!") == "beyonce halo")
        #expect(MusicTextMatch.coreTokens("Halo (feat. X) [Remastered]") == ["halo"])
        #expect(MusicTextMatch.coreTokens("Halo feat. Someone") == ["halo"])
    }
}
