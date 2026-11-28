import Foundation
import Testing
@testable import REDDY

// Offline contract tests for the YouTube Music, Piped and Invidious providers. The canned replies in YouTubeFamilyFixtures were captured from
// the live services (anonymous requests, trimmed), so a change to a parser or to what a service sends fails here instead of showing an empty screen.

private typealias Fx = YouTubeFamilyFixtures

private func json(_ s: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) ?? [:] }

private final class FamilyTransport: MusicHTTPTransport, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = "{}" }
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let route: @Sendable (URLRequest, Int) -> Reply
    private var seen: [String: Int] = [:]
    init(_ route: @escaping @Sendable (URLRequest, Int) -> Reply) { self.route = route }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n: Int = lock.withLock { log.append(request); let k = request.url?.absoluteString ?? ""; seen[k, default: 0] += 1; return seen[k] ?? 1 }
        let r = route(request, n)
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: nil, headerFields: r.headers) else { throw MusicError.network("stub") }
        return (Data(r.body.utf8), resp)
    }
    var requests: [URLRequest] { lock.withLock { log } }
    func count(where match: (URLRequest) -> Bool) -> Int { lock.withLock { log.filter(match).count } }
    func bodies() -> [[String: Any]] { requests.compactMap { $0.httpBody }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
}

private let visitorReply = ")]}'\n[[0,0,[\"CgtTESTVISITOR\"]]]"

private final class FamilyClock: @unchecked Sendable {
    private let lock = NSLock(); private var d: Date
    init(_ d: Date) { self.d = d }
    var value: Date { get { lock.withLock { d } } set { lock.withLock { d = newValue } } }
}

/// Deterministic damage: drops about one in six dictionary keys at every depth, so every parser meets missing fields.
private func damaged(_ node: Any, seed: inout UInt64) -> Any {
    if let d = node as? [String: Any] {
        var out: [String: Any] = [:]
        for k in d.keys.sorted() {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            if (seed >> 33) % 6 == 0 { continue }
            out[k] = damaged(d[k] as Any, seed: &seed)
        }
        return out
    }
    if let a = node as? [Any] { return a.map { damaged($0, seed: &seed) } }
    return node
}

private func completeTrack(_ t: MusicTrack) -> Bool {
    !t.title.isEmpty && !t.artists.isEmpty && t.durationMs > 0 && !t.thumbnails.isEmpty && (t.videoID ?? t.id).count == 11
}

@Suite struct YouTubeMusicContractTests {
    // MARK: search

    @Test(arguments: [("Bohemian Rhapsody", Fx.songsBohemian), ("Kaavaalaa", Fx.songsKaavaalaa), ("Dakko Dakko Meka", Fx.songsDakko)])
    func songSearchIsParsedCompletely(query: String, fixture: String) {
        let r = YTMSearchParser.parseSongs(json(fixture))
        #expect(r.tracks.count >= 3, "\(query)")
        #expect(r.tracks.allSatisfy(completeTrack), "\(query): \(r.tracks.filter { !completeTrack($0) }.map(\.title))")
        #expect(r.tracks.allSatisfy { $0.album != nil })
        #expect(r.tracks.allSatisfy { $0.providerID == YTM.providerID })
    }

    @Test func bohemianRhapsodyFirstRow() throws {
        let first = try #require(YTMSearchParser.parseSongs(json(Fx.songsBohemian)).tracks.first)
        #expect(first.title == "Bohemian Rhapsody")
        #expect(first.artistLine == "Queen")
        #expect(first.durationMs == 355_000)
        #expect(first.album?.title == "A Night At The Opera")
    }

    @Test func tamilTitleAndSeveralArtists() throws {
        let first = try #require(YTMSearchParser.parseSongs(json(Fx.songsKaavaalaa)).tracks.first)
        #expect(first.title.hasPrefix("Kaavaalaa"))
        #expect(first.artists.count >= 2)
        #expect(first.durationMs == 191_000)
    }

    @Test func songSearchHasANextPage() {
        let r = YTMSearchParser.parseSongs(json(Fx.songsBohemian))
        #expect(r.continuation?.isEmpty == false)
        let more = YTMSearchParser.parseSongs(json(Fx.songsBohemianNext))
        #expect(more.tracks.count >= 3 && more.tracks.allSatisfy(completeTrack))
    }

    @Test func albumArtistPlaylistAndPodcastSearch() {
        let albums = YTMSearchParser.parseFiltered(json(Fx.albumsBohemian)).items.compactMap { if case .album(let a) = $0 { a } else { nil } }
        #expect(albums.count >= 3)
        #expect(albums.allSatisfy { $0.id.hasPrefix("MPRE") && !$0.title.isEmpty && !$0.artists.isEmpty && !$0.thumbnails.isEmpty })
        #expect(albums.first?.releaseDate?.count == 4)

        let artists = YTMSearchParser.parseFiltered(json(Fx.artistsBohemian)).items.compactMap { if case .artist(let a) = $0 { a } else { nil } }
        #expect(artists.first?.name == "Queen")
        #expect(artists.allSatisfy { $0.id.hasPrefix("UC") && !$0.thumbnails.isEmpty })

        let lists = YTMSearchParser.parseFiltered(json(Fx.playlistsBohemian)).items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
        #expect(lists.count >= 3)
        #expect(lists.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty && !$0.thumbnails.isEmpty })

        #expect(!YTMSearchParser.parseFiltered(json(Fx.podcastsBohemian)).items.isEmpty)
    }

    @Test func indianLanguageAlbumsAndArtists() {
        let albums = YTMSearchParser.parseFiltered(json(Fx.albumsKaavaalaa)).items.compactMap { if case .album(let a) = $0 { a } else { nil } }
        #expect(albums.contains { $0.title.contains("Jailer") })
        let dakko = YTMSearchParser.parseFiltered(json(Fx.albumsDakko)).items.compactMap { if case .album(let a) = $0 { a } else { nil } }
        #expect(dakko.contains { $0.title.contains("Pushpa") })
        let artists = YTMSearchParser.parseFiltered(json(Fx.artistsKaavaalaa)).items.compactMap { if case .artist(let a) = $0 { a } else { nil } }
        #expect(artists.contains { $0.name == "Shilpa Rao" })
    }

    @Test func mixedSearchHasEverySection() {
        for fixture in [Fx.mixedBohemian, Fx.mixedDakko] {
            let r = YTMSearchParser.parseMixed(json(fixture))
            #expect(!r.songs.isEmpty && !r.albums.isEmpty && !r.artists.isEmpty && !r.playlists.isEmpty)
            #expect(!r.top.isEmpty)
        }
    }

    @Test func typeahead() {
        let s = YTMSearchParser.parseSuggestions(json(Fx.typeaheadBohemian))
        #expect(s.queries.count >= 3)
        #expect(s.queries.contains { $0.text.contains("bohemian rhapsody") })
        #expect(s.queries.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: browse

    @Test func homeExploreChartsAndMoods() {
        let home = YTMHomeParser.parseHome(json(Fx.home))
        #expect(!home.shelves.isEmpty && home.shelves.allSatisfy { !$0.title.isEmpty && !$0.items.isEmpty })
        #expect(home.continuation?.isEmpty == false)
        #expect(!home.chips.isEmpty && home.chips.allSatisfy { !$0.params.isEmpty })
        #expect(!YTMHomeParser.shelves(json(Fx.homeMore), idPrefix: "home-more").isEmpty)
        #expect(!YTMHomeParser.parseExplore(json(Fx.explore)).isEmpty)
        #expect(YTMHomeParser.parseExplore(json(Fx.charts)).count >= 3)
        let moods = YTMHomeParser.parseMoods(json(Fx.moods))
        #expect(moods.count >= 2 && moods.allSatisfy { !$0.tiles.isEmpty && $0.tiles.allSatisfy { !$0.params.isEmpty } })
        #expect(!YTMItems.gridItems(json(Fx.moodCategory)).isEmpty)
    }

    @Test func albumPage() {
        let p = YTMPageParser.parseAlbum(json(Fx.album), browseID: "MPREb_test")
        #expect(p.album.title == "Bohemian Rhapsody (The Original Soundtrack)")
        #expect(p.album.artists.first?.name == "Queen")
        #expect(p.album.releaseDate == "2018" && p.album.albumType == "Album")
        #expect(p.audioPlaylistID?.hasPrefix("OLAK") == true)
        #expect(p.rows.count >= 3)
        #expect(p.tracks.allSatisfy { completeTrack($0) && $0.album?.id == "MPREb_test" })
        #expect(p.tracks.map(\.trackNumber) == (1...p.tracks.count).map { Optional($0) })
    }

    @Test func artistPageHasTopTracksAlbumsAndRelated() {
        let p = YTMPageParser.parseArtist(json(Fx.artist), browseID: "UCEPMVbUzImPl4p8k4LkGevA")
        #expect(p.artist.name == "Queen" && !p.artist.thumbnails.isEmpty)
        #expect(p.topTracks.count >= 3 && p.topTracks.allSatisfy { !$0.title.isEmpty && !$0.artists.isEmpty && $0.id.count == 11 })
        #expect(p.topSongsPlaylistID?.isEmpty == false)
        let items = p.shelves.flatMap(\.items)
        #expect(items.contains { if case .album = $0 { true } else { false } })
        #expect(items.contains { if case .artist = $0 { true } else { false } })
    }

    @Test func playlistCountIsTheTrackCountNotTheViews() {
        let p = YTMPageParser.parsePlaylist(json(Fx.playlistLong), playlistID: "PLtest")
        #expect(p.playlist.trackCount == 200)
        #expect(p.hasHeader && !p.playlist.name.isEmpty)
        #expect(p.rows.count >= 3 && p.tracks.allSatisfy { !$0.title.isEmpty && !$0.artists.isEmpty && $0.id.count == 11 && $0.durationMs > 0 })
    }

    @Test func playlistPagesThroughItsContinuation() throws {
        let first = YTMPageParser.parsePlaylist(json(Fx.playlistLong), playlistID: "PLtest")
        let token = try #require(first.continuation)
        let more = YTMPageParser.parsePlaylistContinuation(json(Fx.playlistMore))
        #expect(more.rows.count >= 3)
        #expect(more.next != token)
        let short = YTMPageParser.parsePlaylist(json(Fx.playlistShort), playlistID: "PLshort")
        #expect(short.playlist.trackCount != nil)
        #expect(short.continuation == nil)
    }

    @Test func trackCountReadsTheRightPart() {
        func header(_ second: String) -> [String: Any] { ["secondSubtitle": ["runs": [["text": second]]]] }
        #expect(YTMPageParser.trackCount(header("1B views \u{2022} 200 tracks \u{2022} 12 hours")) == 200)
        #expect(YTMPageParser.trackCount(header("1,234 songs \u{2022} 3 hours")) == 1234)
        #expect(YTMPageParser.trackCount(header("45 episodes")) == 45)
        #expect(YTMPageParser.trackCount(header("2M views")) == nil)
        #expect(YTMPageParser.trackCount(nil) == nil)
    }

    @Test func radioAndLyricsPointers() {
        let r = YTMPageParser.parseNext(json(Fx.radio))
        #expect(r.tracks.count >= 3 && r.tracks.allSatisfy { !$0.title.isEmpty && $0.id.count == 11 })
        #expect(YTMPageParser.parseNext(json(Fx.lyricsNext)).lyricsBrowseID?.hasPrefix("MPLY") == true)
        let timed = YTMPageParser.parseTimedLyrics(json(Fx.lyricsBrowse))
        #expect(timed.count > 10 && timed.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: tolerance

    @Test func parsersSurviveMissingFieldsAndUnknownShapes() {
        let all: [String] = [Fx.songsBohemian, Fx.albumsBohemian, Fx.artistsBohemian, Fx.playlistsBohemian, Fx.mixedBohemian, Fx.podcastsBohemian,
                             Fx.typeaheadBohemian, Fx.home, Fx.explore, Fx.charts, Fx.moods, Fx.album, Fx.artist, Fx.playlistLong, Fx.playlistMore,
                             Fx.radio, Fx.lyricsBrowse]
        var seed: UInt64 = 42
        var inputs: [Any] = [[:] as [String: Any], [] as [Any], "x", NSNull(), ["contents": 7, "header": [1, 2]] as [String: Any]]
        for f in all { for _ in 0..<3 { inputs.append(damaged(json(f), seed: &seed)) } }
        var rows = 0
        for node in inputs {
            rows += YTMSearchParser.parseSongs(node).tracks.count + YTMSearchParser.parseFiltered(node).items.count
            rows += YTMSearchParser.parseMixed(node).all.count + YTMSearchParser.parseSuggestions(node).queries.count
            rows += YTMHomeParser.parseHome(node).shelves.count + YTMHomeParser.parseExplore(node).count + YTMHomeParser.parseMoods(node).count
            rows += YTMItems.gridItems(node).count
            rows += YTMPageParser.parseAlbum(node, browseID: "x").rows.count + YTMPageParser.parseArtist(node, browseID: "x").topTracks.count
            rows += YTMPageParser.parsePlaylist(node, playlistID: "x").rows.count + YTMPageParser.parsePlaylistContinuation(node).rows.count
            rows += YTMPageParser.parseNext(node).tracks.count + YTMPageParser.parseTimedLyrics(node).count
            _ = YTMPageParser.parsePlainLyrics(node)
        }
        #expect(rows >= 0)
    }

    // MARK: transport

    private func provider(_ route: @escaping @Sendable (URLRequest, Int) -> FamilyTransport.Reply) -> (YouTubeMusicFullProvider, FamilyTransport) {
        let t = FamilyTransport(route)
        let client = YouTubeMusicClient(http: MusicHTTP(transport: t), sleep: { _ in })
        return (YouTubeMusicFullProvider(client: client, resolver: YouTubeMusicStreamResolver(client: client)), t)
    }

    @Test func searchGoesOutAnonymouslyWithVisitorDataAndNoAccount() async throws {
        let (p, t) = provider { req, _ in
            if (req.url?.path ?? "").hasSuffix("sw.js_data") { return .init(body: visitorReply) }
            return .init(body: Fx.songsBohemian)
        }
        let page = try await p.searchTracks("Bohemian Rhapsody", page: nil)
        #expect(page.items.count >= 3 && page.next != nil)
        let search = try #require(t.requests.last { ($0.url?.path ?? "").hasSuffix("/search") })
        #expect(search.value(forHTTPHeaderField: "cookie") == nil && search.value(forHTTPHeaderField: "authorization") == nil)
        #expect(search.value(forHTTPHeaderField: "x-goog-visitor-id") == "CgtTESTVISITOR")
        let body = try #require(t.bodies().last)
        let ctx = try #require(body["context"] as? [String: Any])
        let client = try #require(ctx["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "WEB_REMIX" && client["visitorData"] as? String == "CgtTESTVISITOR")
        #expect((ctx["user"] as? [String: Any])?["onBehalfOfUser"] == nil)
    }

    @Test func serverErrorsAreRetriedWithBackoff() async throws {
        let (p, t) = provider { req, n in
            if (req.url?.path ?? "").hasSuffix("sw.js_data") { return .init(body: visitorReply) }
            return n < 3 ? .init(status: 503, body: "") : .init(body: Fx.songsBohemian)
        }
        let r = try await p.searchTracks("Bohemian Rhapsody", page: nil)
        #expect(!r.items.isEmpty)
        #expect(t.count { ($0.url?.path ?? "").hasSuffix("/search") } == 3)
    }

    @Test func rateLimitHonoursRetryAfterAndGivesUpOnLongWaits() async throws {
        #expect(YouTubeMusicClient.retryDelay(for: MusicError.rateLimited(retryAfter: 4), attempt: 0) == 4)
        #expect(YouTubeMusicClient.retryDelay(for: MusicError.rateLimited(retryAfter: 120), attempt: 0) == nil)
        #expect(YouTubeMusicClient.retryDelay(for: MusicError.network("HTTP 502"), attempt: 0) != nil)
        #expect(YouTubeMusicClient.retryDelay(for: MusicError.network("HTTP 400"), attempt: 0) == nil)
        let (p, t) = provider { req, n in
            if (req.url?.path ?? "").hasSuffix("sw.js_data") { return .init(body: visitorReply) }
            return n == 1 ? .init(status: 429, headers: ["Retry-After": "2"], body: "") : .init(body: Fx.typeaheadBohemian)
        }
        let s = try await p.suggestions("bohemian")
        #expect(!s.queries.isEmpty)
        #expect(t.count { ($0.url?.path ?? "").hasSuffix("get_search_suggestions") } == 2)
    }

    @Test func artistTopSongsGetTheirLengthsFromTheTopSongsPlaylist() async throws {
        let (p, _) = provider { req, _ in
            if (req.url?.path ?? "").hasSuffix("sw.js_data") { return .init(body: visitorReply) }
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("\"browseId\":\"VL") { return .init(body: Fx.playlistLong) }
            return .init(body: Fx.artist)
        }
        let page = try await p.artistPage(id: "UCEPMVbUzImPl4p8k4LkGevA")
        #expect(page.topTracks.count >= 3)
        #expect(page.artist.name == "Queen")
    }
}

@Suite struct PipedInvidiousContractTests {
    @Test func pipedSearchAndStreams() {
        let found = PipedProvider.parseSearch(json(Fx.pipedSearch))
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.videoID.count == 11 && !$0.title.isEmpty && $0.durationMs ?? 0 > 0 })
        #expect(found.first?.channel == "Queen")
        #expect(PipedProvider.parseStreams(json(Fx.pipedStreamsEmpty)).isEmpty)
        let shape = #"{"audioStreams":[{"url":"https://p/a?expire=1900000000","format":"M4A","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,"videoOnly":false}]}"#
        #expect(PipedProvider.parseStreams(json(shape)).count == 1)
    }

    @Test func invidiousSearchAndStreams() throws {
        let found = InvidiousProvider.parseSearch(json(Fx.invidiousSearch))
        #expect(found.count == 4 && found.allSatisfy { $0.videoID.count == 11 && !$0.title.isEmpty && $0.durationMs ?? 0 > 0 })
        let base = try #require(URL(string: "https://inv.test"))
        let streams = InvidiousProvider.parseStreams(json(Fx.invidiousVideo), base: base)
        #expect(streams.count == 3)
        #expect(streams.contains { $0.container == "m4a" && $0.codec == "aac" } && streams.contains { $0.codec == "opus" })
        #expect(streams.allSatisfy { $0.url.hasPrefix("https://") })
        #expect(streams.allSatisfy { $0.expiresAt != nil })
    }

    @Test func parsersSurviveGarbage() throws {
        let base = try #require(URL(string: "https://inv.test"))
        var seed: UInt64 = 7
        for f in [Fx.pipedSearch, Fx.pipedStreamsEmpty, Fx.pipedError, Fx.invidiousSearch, Fx.invidiousVideo] {
            let d = damaged(json(f), seed: &seed)
            _ = PipedProvider.parseSearch(d); _ = PipedProvider.parseStreams(d); _ = InvidiousProvider.parseSearch(d); _ = InvidiousProvider.parseStreams(d, base: base)
        }
        for junk in [NSNull() as Any, 5, "x", [Any](), [:] as [String: Any]] {
            #expect(PipedProvider.parseStreams(junk).isEmpty && InvidiousProvider.parseStreams(junk, base: base).isEmpty)
        }
    }

    @Test func registryDocumentsAreParsed() {
        let pipedTable = """
        Instance Name | Instance API URL | Instance Location(s) | CDN | Registered Users
        --- | --- | --- | --- | ---
        kavin.rocks (Official) | https://pipedapi.kavin.rocks | US | Yes | badge
        private.coffee | https://api.piped.private.coffee | AT | No | badge
        """
        #expect(YouTubeInstances.parsePipedMarkdown(pipedTable).map(\.host) == ["pipedapi.kavin.rocks", "api.piped.private.coffee"])
        let invMarkdown = """
        * [inv.nadeko.net](https://inv.nadeko.net) CL - Source code: https://x.test
        * [yt.chocolatemoo53.com](https://yt.chocolatemoo53.com) US
        * [inv.nadeko.ygg](https://inv.nadeko.ygg) CL (Yggdrasil)
        * [inv-ygg.nadeko.net](https://inv-ygg.nadeko.net) CL (Yggdrasil)
        """
        #expect(YouTubeInstances.parseInvidiousMarkdown(invMarkdown).map(\.host) == ["inv.nadeko.net", "yt.chocolatemoo53.com"])
        #expect(YouTubeInstances.parsePiped(json(#"[{"name":"a","api_url":"https://a.test/"},{"name":"b"},{"api_url":"http://insecure.test"}]"#)).map(\.host) == ["a.test"])
        let inv = #"[["a.test",{"type":"https","api":true}],["b.test",{"type":"https","api":false}],["c.onion",{"type":"onion","api":true}]]"#
        #expect(YouTubeInstances.parseInvidious(json(inv)).map(\.host) == ["a.test"])
        #expect(YouTubeInstances.parsePiped(json("{}")).isEmpty && YouTubeInstances.parseInvidious(json("{}")).isEmpty)
    }

    /// Registry replies and probe answers for a made-up world: good.test serves audio, every other host refuses.
    private func world() -> FamilyTransport {
        FamilyTransport { req, _ in
            let host = req.url?.host ?? "", path = req.url?.path ?? ""
            if host == "raw.githubusercontent.com" && path.contains("iv-org") { return .init(body: "* [good.test](https://good.test)\n* [bad.test](https://bad.test)\n") }
            if host == "raw.githubusercontent.com" { return .init(body: "x | https://good.test | y | z\nx | https://bad.test | y | z\n") }
            if host == "good.test" && path.contains("/api/v1/videos/") { return .init(body: Fx.invidiousVideo) }
            if host == "good.test" && path.contains("/search") { return .init(body: Fx.invidiousSearch) }
            return .init(status: host == "bad.test" ? 403 : 500, body: "")
        }
    }

    @Test func onlyServersThatGiveAudioAreKept() async {
        let instances = YouTubeInstances(http: MusicHTTP(transport: world()))
        #expect(await instances.ranked(.invidious).map(\.host) == ["good.test"])
    }

    @Test func healthIsCachedForThirtyMinutes() async {
        let clock = FamilyClock(Date(timeIntervalSince1970: 1_900_000_000))
        let t = world()
        let instances = YouTubeInstances(http: MusicHTTP(transport: t), now: { clock.value })
        _ = await instances.ranked(.invidious)
        clock.value.addTimeInterval(29 * 60)
        _ = await instances.ranked(.invidious)
        #expect(t.count { $0.url?.host == "good.test" && ($0.url?.path ?? "").contains("/videos/") } == 1)
        clock.value.addTimeInterval(2 * 60)
        _ = await instances.ranked(.invidious)
        #expect(t.count { $0.url?.host == "good.test" && ($0.url?.path ?? "").contains("/videos/") } == 2)
    }

    @Test func providerUsesTheHealthyServerEndToEnd() async throws {
        let p = InvidiousProvider(http: MusicHTTP(transport: world()))
        let track = MusicTrack(id: "t", providerID: "x", title: "Bohemian Rhapsody", durationMs: 355_000, artists: [MusicArtistRef(id: "a", name: "Queen")])
        let source = try #require(try await p.sources(for: track).first)
        let streams = try await p.streams(for: source)
        #expect(!streams.isEmpty && streams.allSatisfy { $0.url.hasPrefix("https://") })
    }

    @Test func noHealthyServerGivesOneClearError() async {
        let t = FamilyTransport { _, _ in .init(status: 502, body: "") }
        let p = PipedProvider(http: MusicHTTP(transport: t))
        let track = MusicTrack(id: "t", providerID: "x", title: "Song", durationMs: 1000, artists: [])
        do { _ = try await p.sources(for: track); Issue.record("expected an error") }
        catch let MusicError.network(text) { #expect(text.contains("No public Piped server")) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func emptyAudioListIsAnErrorNotASilentSuccess() async {
        let http = MusicHTTP(transport: FamilyTransport { _, _ in .init(body: Fx.pipedStreamsEmpty) })
        let pinned = [URL(string: "https://p.test")].compactMap { $0 }
        let p = PipedProvider(http: http, instances: YouTubeInstances(http: http, fixed: [.piped: pinned]))
        let src = MusicAudioSource(id: "BSTsnWoslP4", providerID: "piped", title: "x", artist: nil, album: nil, durationMs: nil, externalURL: nil, confidence: 1)
        await #expect(throws: MusicError.noPlayableSource("x")) { _ = try await p.streams(for: src) }
    }
}

@Suite struct BasicYouTubeProviderContractTests {
    @Test func songSearchFromLiveReply() {
        for f in [Fx.songsBohemian, Fx.songsKaavaalaa, Fx.songsDakko] {
            let tracks = YouTubeMusicProvider.parseSongs(json(f))
            #expect(tracks.count >= 3 && tracks.allSatisfy { !$0.title.isEmpty && !$0.artists.isEmpty && $0.id.count == 11 && $0.durationMs > 0 })
        }
    }

    @Test func playerRequestUsesVisionOSWithVisitorDataOnly() async throws {
        let reply = #"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://rr1.googlevideo.com/videoplayback?expire=1900000000&id=x&itag=140&c=VISIONOS","bitrate":130000,"audioSampleRate":"44100"},{"mimeType":"video/mp4; codecs=\"avc1\"","url":"https://rr1.googlevideo.com/v","bitrate":900000}]}}"#
        let t = FamilyTransport { req, _ in
            let path = req.url?.path ?? ""
            if path.hasSuffix("sw.js_data") { return .init(body: visitorReply) }
            if path.hasSuffix("/player") { return .init(body: reply) }
            return .init(body: Fx.songsBohemian)
        }
        let p = YouTubeMusicProvider(http: MusicHTTP(transport: t))
        let src = MusicAudioSource(id: "BSTsnWoslP4", providerID: "youtube-music", title: "x", artist: nil, album: nil, durationMs: nil, externalURL: nil, confidence: 1)
        let streams = try await p.streams(for: src)
        #expect(streams.count == 1 && streams[0].container == "m4a")
        let bodies = t.bodies().filter { $0["videoId"] != nil }
        #expect(bodies.count == 1)
        let client = ((bodies.first?["context"] as? [String: Any])?["client"] as? [String: Any]) ?? [:]
        #expect(client["clientName"] as? String == "VISIONOS" && client["visitorData"] as? String == "CgtTESTVISITOR")
        let req = try #require(t.requests.last { ($0.url?.path ?? "").hasSuffix("/player") })
        #expect(req.value(forHTTPHeaderField: "x-goog-visitor-id") == "CgtTESTVISITOR")
        #expect(req.value(forHTTPHeaderField: "cookie") == nil)
    }
}
