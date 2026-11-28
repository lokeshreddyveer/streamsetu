import Foundation
import Testing
@testable import REDDY

// Offline tests for the YouTube Music client. Every fixture is canned JSON built from the field paths the parsers read; none of it has
// been compared with live replies.

private final class StubTransport: MusicHTTPTransport, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = Data(); var error: Error? = nil }
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> Reply
    private var counts: [String: Int] = [:]
    init(_ h: @escaping @Sendable (URLRequest, Int) -> Reply) { handler = h }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n: Int = lock.withLock {
            requests.append(request)
            let k = request.url?.path ?? ""
            counts[k, default: 0] += 1
            return counts[k] ?? 1
        }
        let r = handler(request, n)
        if let e = r.error { throw e }
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: nil, headerFields: r.headers) else { throw MusicError.network("stub") }
        return (r.body, resp)
    }
    func bodies() -> [[String: Any]] {
        lock.withLock { requests.compactMap { $0.httpBody }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
    }
    func last(path: String) -> URLRequest? { lock.withLock { requests.last { ($0.url?.path ?? "").hasSuffix(path) } } }
    var count: Int { lock.withLock { requests.count } }
}

private func ok(_ json: String) -> StubTransport.Reply { StubTransport.Reply(body: Data(json.utf8)) }
private func parse(_ json: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:] }

private actor SleepLog { var values: [TimeInterval] = []; func add(_ v: TimeInterval) { values.append(v) } }

private final class FixedSession: YouTubeMusicSession, @unchecked Sendable {
    let snap: YouTubeMusicSessionSnapshot
    init(_ s: YouTubeMusicSessionSnapshot) { snap = s }
    func snapshot() async -> YouTubeMusicSessionSnapshot { snap }
    func updateVisitorData(_ value: String) async {}
    func merge(rotatedCookies: [(name: String, value: String)]) async {}
}

private let signedIn = YouTubeMusicSessionSnapshot(cookieHeader: "SID=s; SAPISID=abc123", visitorData: "CgtVISITOR", dataSyncID: "sync1")

// MARK: fixtures

private func songRow(_ vid: String, title: String = "Song A", sub: String? = nil, olak: String? = nil, type: String = "MUSIC_VIDEO_TYPE_ATV") -> String {
    let subtitle = sub ?? #"{"text":"Song"},{"text":" • "},{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}},{"text":" • "},{"text":"Album Y","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_album1"}}},{"text":" • "},{"text":"3:02"}"#
    let pl = olak.map { #","playlistId":"\#($0)""# } ?? ""
    return #"""
    {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\#(vid)"},
    "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/a.jpg","width":60,"height":60},{"url":"https://i/b.jpg","width":120,"height":120}]}}},
    "overlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"\#(vid)"\#(pl),"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#(type)"}}}}}}}},
    "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\#(title)"}]}}},
    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\#(subtitle)]}}}]}}
    """#
}

private func albumCard(_ id: String, title: String) -> String {
    #"""
    {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"\#(title)"}]},"subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}},{"text":" • "},{"text":"2020"}]},
    "navigationEndpoint":{"browseEndpoint":{"browseId":"\#(id)"}},"thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/c.jpg","width":226,"height":226}]}}}}}
    """#
}

private func shelf(_ title: String, more: String? = nil, _ items: [String]) -> String {
    let m = more.map { #","moreContentButton":{"buttonRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"\#($0)"}}}}"# } ?? ""
    return #"{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\#(title)"}]}\#(m)}},"contents":[\#(items.joined(separator: ","))]}}"#
}

private func client(_ t: StubTransport, session: YouTubeMusicSession = GuestYouTubeMusicSession(visitorData: "CgtGUEST"), log: SleepLog? = nil) -> YouTubeMusicClient {
    YouTubeMusicClient(http: MusicHTTP(transport: t), session: session, sleep: { await log?.add($0) })
}

// MARK: request building

@Suite struct YouTubeMusicRequestTests {
    @Test func guestRequestCarriesNoAccountData() async throws {
        let t = StubTransport { _, _ in ok("{}") }
        _ = try await client(t).browse("FEmusic_home")
        let req = try #require(t.last(path: "browse"))
        #expect(req.url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(req.value(forHTTPHeaderField: "x-youtube-client-name") == "67")
        #expect(req.value(forHTTPHeaderField: "x-goog-visitor-id") == "CgtGUEST")
        #expect(req.value(forHTTPHeaderField: "cookie") == nil && req.value(forHTTPHeaderField: "authorization") == nil)
        let body = try #require(t.bodies().first)
        let ctx = try #require(body["context"] as? [String: Any])
        #expect((ctx["user"] as? [String: Any])?["onBehalfOfUser"] == nil)
        let c = try #require(ctx["client"] as? [String: Any])
        #expect(c["clientName"] as? String == "WEB_REMIX" && c["hl"] as? String == "en" && c["gl"] as? String == "US")
        #expect(body["browseId"] as? String == "FEmusic_home")
    }

    @Test func signedInSessionSendsCookieHashAndIdentityOnlyToLoginClients() async throws {
        let t = StubTransport { _, _ in ok("{}") }
        let c = client(t, session: FixedSession(signedIn))
        _ = try await c.browse("FEmusic_home")
        let web = try #require(t.last(path: "browse"))
        #expect(web.value(forHTTPHeaderField: "cookie") == "SID=s; SAPISID=abc123")
        #expect(web.value(forHTTPHeaderField: "authorization")?.hasPrefix("SAPISIDHASH ") == true)
        let ctx = try #require(t.bodies().last?["context"] as? [String: Any])
        #expect((ctx["user"] as? [String: Any])?["onBehalfOfUser"] as? String == "sync1")

        _ = try await c.player(videoID: "vid00000001", client: .visionOS, signatureTimestamp: 1, poToken: nil)
        let vr = try #require(t.last(path: "player"))
        #expect(vr.value(forHTTPHeaderField: "cookie") == nil && vr.value(forHTTPHeaderField: "authorization") == nil)
        let vctx = try #require(t.bodies().last?["context"] as? [String: Any])
        #expect((vctx["user"] as? [String: Any])?["onBehalfOfUser"] == nil)
    }

    @Test func identityIsNeverSentWithoutACookie() {
        let snap = YouTubeMusicSessionSnapshot(cookieHeader: nil, visitorData: "v", dataSyncID: "sync1")
        let ctx = YTMContext.build(client: YTMClientTable.builtIn[.webRemix]!, locale: YTMLocale(), session: snap)
        #expect((ctx["user"] as? [String: Any])?["onBehalfOfUser"] == nil)
    }

    @Test func sapisidHashIsSha1OfEpochSapisidOrigin() {
        let h = YTMContext.sapisidHash(sapisid: "abc", now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(h.hasPrefix("SAPISIDHASH 1700000000_"))
        #expect(h.count == "SAPISIDHASH 1700000000_".count + 40)
    }

    @Test func visitorIdRetriesSoonAfterAFailedFetchNotAfterAMinute() async {
        // The visitor id is what lets a guest play (VISIONOS is refused without it). A launch-time network blip must not leave the app
        // identity-less for a whole minute, so a failed fetch is retried after a few seconds and a success clears the failure.
        let t = StubTransport { _, n in n <= 1 ? StubTransport.Reply(error: URLError(.notConnectedToInternet)) : ok(#"[["","",["CgtTESTVISITOR"]]]"#) }
        let http = MusicHTTP(transport: t)
        let boot = YTMVisitorBootstrap()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // First fetch fails on the network.
        #expect(await boot.value(http: http, now: t0) == nil)
        let afterFirst = t.count
        // Within the short retry window it does not even hit the network again.
        #expect(await boot.value(http: http, now: t0.addingTimeInterval(YTMVisitorBootstrap.retryAfterFailure - 1)) == nil)
        #expect(t.count == afterFirst)
        // Past the window it tries again and now succeeds.
        #expect(await boot.value(http: http, now: t0.addingTimeInterval(YTMVisitorBootstrap.retryAfterFailure + 1)) == "CgtTESTVISITOR")
        // The id is then remembered.
        #expect(await boot.value(http: http, now: t0.addingTimeInterval(1000)) == "CgtTESTVISITOR")
    }

    @Test func localeAcceptsOnlySafeLanguageCodes() {
        #expect(YTMLocale(hl: "de").acceptLanguage == "de,en;q=0.5")
        #expect(YTMLocale(hl: "en").acceptLanguage == "en-US,en;q=0.9")
        #expect(YTMLocale(hl: "bad value!").hl == "en")
        #expect(YTMLocale(hl: "pt-BR").hl == "pt-BR")
    }

    @Test func oldAndroidVRAndIPhoneAppVersionsAreNotInTheTable() {
        let all = YTMClientTable.builtIn.values
        #expect(!all.contains { $0.clientVersion == "1.60.19" || $0.clientVersion == "19.45.4" })
    }

    @Test func visitorDataIsScrapedAndSent() async throws {
        let sw = ")]}'\n[[\"x\",1,[\"junk\",\"CgtREALID123\",\"other\"]]]"
        #expect(YouTubeMusicClient.parseVisitorData(Data(sw.utf8)) == "CgtREALID123")
        let t = StubTransport { req, _ in req.url?.path == "/sw.js_data" ? ok(sw) : ok("{}") }
        _ = try await client(t, session: GuestYouTubeMusicSession()).browse("FEmusic_home")
        #expect(t.last(path: "browse")?.value(forHTTPHeaderField: "x-goog-visitor-id") == "CgtREALID123")
    }
}

// MARK: retry and rate limits

@Suite struct YouTubeMusicRetryTests {
    @Test func timeoutsRetryThreeTimesWithHalfAndOneSecond() async throws {
        let log = SleepLog()
        let t = StubTransport { _, n in n < 3 ? StubTransport.Reply(error: URLError(.timedOut)) : ok("{\"ok\":1}") }
        let r = try await client(t, log: log).browse("x")
        #expect(r.dict["ok"] as? Int == 1)
        #expect(await log.values == [0.5, 1.0])
        #expect(t.requests.filter { $0.url?.path.hasSuffix("browse") == true }.count == 3)
    }

    @Test func givesUpAfterThreeAttempts() async {
        let log = SleepLog()
        let t = StubTransport { _, _ in StubTransport.Reply(error: URLError(.cannotConnectToHost)) }
        await #expect(throws: (any Error).self) { _ = try await client(t, log: log).browse("x") }
        #expect(await log.values.count == 2)
    }

    @Test func rateLimitHonoursRetryAfterAndCapsIt() async throws {
        let log = SleepLog()
        let t = StubTransport { _, n in n == 1 ? StubTransport.Reply(status: 429, headers: ["Retry-After": "2"]) : ok("{}") }
        _ = try await client(t, log: log).browse("x")
        #expect(await log.values == [2.0])

        let t2 = StubTransport { _, _ in StubTransport.Reply(status: 429, headers: ["Retry-After": "600"]) }
        await #expect(throws: MusicError.self) { _ = try await client(t2, log: log).browse("x") }
        #expect(t2.requests.count == 1)
    }

    @Test func rateLimitWithoutHeaderBacksOffAndServerErrorsRetry() async throws {
        let log = SleepLog()
        let t = StubTransport { _, n in n == 1 ? StubTransport.Reply(status: 429) : (n == 2 ? StubTransport.Reply(status: 503) : ok("{}")) }
        _ = try await client(t, log: log).browse("x")
        #expect(await log.values == [1.5, 1.0])
    }

    @Test func clientErrorsAreFinal() async {
        let log = SleepLog()
        let t = StubTransport { _, _ in StubTransport.Reply(status: 404) }
        await #expect(throws: MusicError.notFound) { _ = try await client(t, log: log).browse("x") }
        #expect(await log.values.isEmpty)
    }
}

// MARK: home, search, typeahead

@Suite struct YouTubeMusicHomeSearchTests {
    @Test func homeHasChipsClassifiedShelvesAndContinuation() {
        let json = #"""
        {"contents":{"chips":[{"chipCloudChipRenderer":{"text":{"runs":[{"text":"Relax"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_home","params":"PARAMX"}}}},
        {"chipCloudChipRenderer":{"text":{"runs":[{"text":"Clear"}]}}}],
        "shelves":[\#(shelf("Quick picks", [songRow("vid00000001")])),\#(shelf("Fresh", more: "FEmusic_new_releases_albums", [albumCard("MPREb_z", title: "Album Z")])),\#(shelf("Empty", []))],
        "tail":{"continuations":[{"nextContinuationData":{"continuation":"HOMETOKEN"}}]}}}
        """#
        let page = YTMHomeParser.parseHome(parse(json))
        #expect(page.chips == [YTMChip(title: "Relax", params: "PARAMX")])
        #expect(page.shelves.map(\.kind) == [.quickPicks, .newReleases])
        #expect(page.shelves[1].moreBrowseID == "FEmusic_new_releases_albums")
        #expect(page.continuation == "HOMETOKEN")
        if case .album(let a) = page.shelves[1].items[0] { #expect(a.id == "MPREb_z" && a.releaseDate == "2020" && a.artists.first?.id == "UCartist1") } else { Issue.record("expected album") }
    }

    @Test func songRowFollowsTheStructuralRules() throws {
        let row = try #require(YTMItems.songRows(parse("[\(songRow("vid00000001"))]")).first)
        #expect(row.track.title == "Song A" && row.track.durationMs == 182_000)
        #expect(row.track.artists.map(\.id) == ["UCartist1"] && row.track.album?.id == "MPREb_album1")
        #expect(row.track.thumbnails.best(minSide: 100) == "https://i/b.jpg" && !row.isVideo)
        let video = try #require(YTMItems.songRows(parse("[\(songRow("vid00000002", type: "MUSIC_VIDEO_TYPE_OMV"))]")).first)
        #expect(video.isVideo)
        // Artist omitted: two fields, the second a duration; the type label is dropped by structure.
        let noArtist = try #require(YTMItems.songRows(parse("[\(songRow("vid00000003", sub: #"{"text":"Videoo"},{"text":" • "},{"text":"4:10"}"#))]")).first)
        #expect(noArtist.track.artists.isEmpty && noArtist.track.durationMs == 250_000)
    }

    @Test func moodsParseColorsAndParams() {
        let json = #"""
        {"g":{"gridRenderer":{"header":{"gridHeaderRenderer":{"title":{"runs":[{"text":"Moods"}]}}},"items":[
        {"musicNavigationButtonRenderer":{"buttonText":{"runs":[{"text":"Chill"}]},"solid":{"leftStripeColor":4278190335},"clickCommand":{"browseEndpoint":{"browseId":"FEmusic_moods_and_genres_category","params":"CHILLP"}}}}]}}}
        """#
        let s = YTMHomeParser.parseMoods(parse(json))
        #expect(s.first?.tiles == [YTMMoodTile(title: "Chill", params: "CHILLP", colorHex: "#0000ff")])
    }

    @Test func mixedSearchBucketsTopAndRows() {
        let json = #"""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
        {"musicCardShelfRenderer":{"title":{"runs":[{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}}]},"subtitle":{"runs":[{"text":"Artist"}]},"thumbnail":{"thumbnails":[{"url":"https://i/t.jpg"}]},"contents":[\#(songRow("vid00000001"))]}},
        {"itemSectionRenderer":{"contents":[\#(songRow("vid00000002", title: "Song B")),
        {"musicResponsiveListItemRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_alb"}},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Album Q"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Album"},{"text":" • "},{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}}]}}}]}}]}}]}}}}]}}}
        """#
        let r = YTMSearchParser.parseMixed(parse(json))
        #expect(r.top.count == 2)
        if case .artist(let a) = r.top[0] { #expect(a.id == "UCartist1") } else { Issue.record("top should be the artist") }
        #expect(r.songs.map(\.id) == ["vid00000002"] && r.albums.map(\.id) == ["MPREb_alb"])
    }

    @Test func filterTokensAreTheDocumentedOnes() {
        #expect(YTMSearchFilter.songs.params == "EgWKAQIIAWoKEAkQBRAKEAMQBA==")
        #expect(YTMSearchFilter.albums.params == "EgWKAQIYAWoKEAkQChAFEAMQBA==")
        #expect(YTMSearchFilter.artists.params == "EgWKAQIgAWoKEAkQChAFEAMQBA==")
        #expect(YTMSearchFilter.communityPlaylists.params == "EgeKAQQoAEABagoQAxAEEAoQCRAF")
    }

    @Test func searchContinuationUsesTheTokenEndpoint() async throws {
        let t = StubTransport { req, _ in
            req.url?.query?.contains("ctoken=") == true ? ok("{\"x\":[\(songRow("vid00000009"))]}") :
                ok("{\"x\":[\(songRow("vid00000001"))],\"c\":{\"continuationCommand\":{\"token\":\"TOK/+=\"}}}")
        }
        let p = YouTubeMusicFullProvider(client: client(t), resolver: YouTubeMusicStreamResolver(client: client(t)))
        let first = try await p.searchTracks("abc", page: nil)
        #expect(first.items.map(\.id) == ["vid00000001"])
        guard case .continuation(let tok)? = first.next else { Issue.record("no continuation"); return }
        let second = try await p.searchTracks("abc", page: .continuation(tok))
        #expect(second.items.map(\.id) == ["vid00000009"])
        let q = try #require(t.last(path: "search")?.url?.absoluteString)
        #expect(q.contains("ctoken=TOK%2F%2B%3D") && q.contains("type=next"))
    }

    @Test func typeaheadStaysAnonymousEvenWhenSignedIn() async throws {
        let json = #"""
        {"contents":[{"searchSuggestionsSectionRenderer":{"contents":[
        {"searchSuggestionRenderer":{"suggestion":{"runs":[{"text":"daft ","bold":true},{"text":"punk"}]},"navigationEndpoint":{"searchEndpoint":{"query":"daft punk"}}}},
        {"historySuggestionRenderer":{"suggestion":{"runs":[{"text":"daft past"}]}}},
        \#(songRow("vid00000001"))]}}]}
        """#
        let t = StubTransport { _, _ in ok(json) }
        let p = YouTubeMusicFullProvider(client: client(t, session: FixedSession(signedIn)), resolver: YouTubeMusicStreamResolver(client: client(t)))
        let s = try await p.suggestions("  da ")
        #expect(s.queries == [YTMSuggestion(text: "daft punk", isHistory: false), YTMSuggestion(text: "daft past", isHistory: true)])
        #expect(s.items.count == 1)
        let req = try #require(t.last(path: "get_search_suggestions"))
        #expect(req.value(forHTTPHeaderField: "cookie") == nil && req.value(forHTTPHeaderField: "authorization") == nil)
        let ctx = try #require(t.bodies().last?["context"] as? [String: Any])
        #expect((ctx["user"] as? [String: Any])?["onBehalfOfUser"] == nil)
        // Fewer than two characters never reaches the network.
        let before = t.count
        _ = try await p.suggestions("d")
        #expect(t.count == before)
    }

    @Test func submittedSearchUsesTheAccountButPerTypeSearchDoesNot() async throws {
        let t = StubTransport { _, _ in ok("{}") }
        let p = YouTubeMusicFullProvider(client: client(t, session: FixedSession(signedIn)), resolver: YouTubeMusicStreamResolver(client: client(t)))
        _ = try await p.search("abc", types: [.track, .album])
        #expect(t.last(path: "search")?.value(forHTTPHeaderField: "cookie") != nil)
        _ = try await p.searchAlbums("abc", page: nil)
        #expect(t.last(path: "search")?.value(forHTTPHeaderField: "cookie") == nil)
    }
}

// MARK: pages

@Suite struct YouTubeMusicPageParserTests {
    @Test func artistPage() throws {
        let json = #"""
        {"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"Artist X"}]},"description":{"runs":[{"text":"Bio"}]},
        "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/hero.jpg","width":1000}]}}},
        "foregroundThumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/avatar.jpg","width":200}]}}},
        "monthlyListenerCount":{"runs":[{"text":"1M monthly audience"}]},
        "startRadioButton":{"buttonRenderer":{"navigationEndpoint":{"watchPlaylistEndpoint":{"playlistId":"RDEMabc"}}}},
        "subscriptionButton":{"subscribeButtonRenderer":{"channelId":"UCartist1","subscribed":false,"longSubscriberCountText":{"runs":[{"text":"32M subscribers"}]}}}}},
        "contents":[{"musicShelfRenderer":{"bottomEndpoint":{"browseEndpoint":{"browseId":"VLPLtop1"}},"contents":[\#(songRow("vid00000001", sub: #"{"text":"Song"},{"text":" • "},{"text":"1M plays"}"#))]}},
        \#(shelf("Albums", more: "MPAD", [albumCard("MPREb_a1", title: "One")])),\#(shelf("Empty", []))]}
        """#
        let p = YTMPageParser.parseArtist(parse(json), browseID: "UCartist1")
        #expect(p.artist.name == "Artist X" && p.artist.thumbnails.first?.url == "https://i/avatar.jpg" && p.artist.bio == "Bio")
        #expect(p.radioPlaylistID == "RDEMabc" && p.topSongsPlaylistID == "PLtop1" && p.subscriberText == "32M subscribers")
        #expect(p.topTracks.count == 1 && p.topTracks[0].artists.first?.name == "Artist X")
        #expect(p.shelves.count == 1 && p.shelves[0].moreBrowseID == "MPAD")
    }

    @Test func albumPageFillsArtistCoverAlbumAndAudioPlaylist() throws {
        let emptyArtist = #"{"text":"Song"},{"text":" • "},{"text":"3:02"}"#
        let json = #"""
        {"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Album Y"}]},"subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"2026"}]},
        "secondSubtitle":{"runs":[{"text":"2 songs"},{"text":" • "},{"text":"7 minutes"}]},
        "straplineTextOne":{"runs":[{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}}]},
        "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i/cover.jpg","width":544}]}}}}},
        "rows":[\#(songRow("vid00000001", sub: emptyArtist, olak: "OLAK5uy_abc")),\#(songRow("vid00000002", sub: emptyArtist))],
        "more":\#(shelf("Other", [albumCard("MPREb_self", title: "Album Y"), albumCard("MPREb_other", title: "Other")]))}
        """#
        let p = YTMPageParser.parseAlbum(parse(json), browseID: "MPREb_self")
        #expect(p.album.title == "Album Y" && p.album.releaseDate == "2026" && p.album.totalTracks == 2 && p.album.albumType == "Album")
        #expect(p.rows.count == 2 && p.audioPlaylistID == "OLAK5uy_abc")
        #expect(p.tracks.allSatisfy { $0.artists.first?.id == "UCartist1" && $0.album?.id == "MPREb_self" && $0.thumbnails.first?.url == "https://i/cover.jpg" })
        #expect(p.tracks.map(\.trackNumber) == [1, 2])
        #expect(p.shelves.first?.items.count == 1)
    }

    @Test func playlistPageUsesShelfScopedTokenAndDoesNotDoubleRows() {
        let nested = songRow("vid00000001").dropFirst().dropLast()  // the row's own inner object
        _ = nested
        let json = #"""
        {"header":{"musicEditablePlaylistDetailHeaderRenderer":{"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Mine"}]},"secondSubtitle":{"runs":[{"text":"1,234 songs"}]}}}}},
        "contents":{"musicPlaylistShelfRenderer":{"contents":[\#(songRow("vid00000001")),\#(songRow("vid00000002"))],
        "continuations":[{"nextContinuationData":{"continuation":"PLTOKEN"}}]}},
        "suggestions":{"continuations":[{"nextContinuationData":{"continuation":"SUGGEST"}}]}}
        """#
        let p = YTMPageParser.parsePlaylist(parse(json), playlistID: "PLmine")
        #expect(p.rows.count == 2 && p.continuation == "PLTOKEN" && p.owned && !p.collaborative)
        #expect(p.playlist.name == "Mine" && p.playlist.trackCount == 1234)
    }

    @Test func shallowRowWalkIgnoresEmbeddedCopies() {
        let inner = #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"vid00000001"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"T"}]}}}]}}"#
        let outer = #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"vid00000001"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"T"}]}}}],"menu":{"copy":\#(inner)}}}"#
        #expect(YTMItems.songRows(parse("[\(outer)]"), shallow: true).count == 1)
        #expect(YTMItems.songRows(parse("[\(outer)]"), shallow: false).count == 2)
    }

    @Test func nextTakesOnlyPrimaryRowsAndReadsAutomixAndLyricsId() {
        func panel(_ id: String, _ t: String) -> String {
            #"{"playlistPanelVideoRenderer":{"videoId":"\#(id)","title":{"runs":[{"text":"\#(t)"}]},"longBylineText":{"runs":[{"text":"Artist X","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}},{"text":" • "},{"text":"Album Y","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_album1"}}},{"text":" • "},{"text":"2020"}]},"lengthText":{"runs":[{"text":"3:10"}]},"thumbnail":{"thumbnails":[{"url":"https://i/p.jpg","width":50}]}}}"#
        }
        let json = #"""
        {"a":[{"playlistPanelVideoWrapperRenderer":{"primaryRenderer":\#(panel("vid00000001", "One")),"counterpart":[{"counterpartRenderer":\#(panel("vid0000000V", "One (video)"))}]}},
        \#(panel("vid00000002", "Two")),{"automixPreviewVideoRenderer":{"content":{"automixPlaylistVideoRenderer":{"navigationEndpoint":{"watchPlaylistEndpoint":{"playlistId":"RDAMVMvid00000001"}}}}}}],
        "tabs":{"endpoint":{"browseEndpoint":{"browseId":"MPLYt_abc","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_LYRICS"}}}}}}
        """#
        let n = YTMPageParser.parseNext(parse(json))
        #expect(n.tracks.map(\.id) == ["vid00000001", "vid00000002"])
        #expect(n.tracks[0].durationMs == 190_000 && n.tracks[0].album?.id == "MPREb_album1" && n.tracks[0].artists.first?.id == "UCartist1")
        #expect(n.automixPlaylistID == "RDAMVMvid00000001" && n.lyricsBrowseID == "MPLYt_abc")
    }

    @Test func deadRadioEscalatesThroughAutomix() async throws {
        let seedOnly = #"{"x":[{"playlistPanelVideoRenderer":{"videoId":"vid00000001","title":{"runs":[{"text":"One"}]}}}]}"#
        let two = #"{"x":[{"playlistPanelVideoRenderer":{"videoId":"vid00000001","title":{"runs":[{"text":"One"}]}}},{"playlistPanelVideoRenderer":{"videoId":"vid00000002","title":{"runs":[{"text":"Two"}]}}}]}"#
        let bare = #"{"x":[{"playlistPanelVideoRenderer":{"videoId":"vid00000001","title":{"runs":[{"text":"One"}]}}},{"automixPreviewVideoRenderer":{"playlistId":"RDAMauto"}}]}"#
        let t = StubTransport { req, _ in
            let b = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]
            switch b?["playlistId"] as? String {
            case "RDAMVMvid00000001": return ok(seedOnly)
            case "RDAMauto": return ok(two)
            default: return ok(bare)
            }
        }
        let p = YouTubeMusicFullProvider(client: client(t), resolver: YouTubeMusicStreamResolver(client: client(t)))
        let recs = try await p.recommendations(seedTrackIDs: ["vid00000001"], limit: 10)
        #expect(recs.map(\.id) == ["vid00000002"])
    }

    @Test func lyricsParsing() {
        let timed = #"{"x":{"timedLyricsData":[{"lyricLine":"B","cueRange":{"startTimeMilliseconds":"2000"}},{"lyricLine":"A","cueRange":{"startTimeMilliseconds":"1000"}},{"lyricLine":"credits"}]}}"#
        #expect(YTMPageParser.parseTimedLyrics(parse(timed)) == [MusicLyricLine(timeMs: 1000, text: "A"), MusicLyricLine(timeMs: 2000, text: "B")])
        let plain = #"{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"la la"}]},"footer":{"runs":[{"text":"Source: Musixmatch"}]}}}"#
        #expect(YTMPageParser.parsePlainLyrics(parse(plain))?.source == "Source: Musixmatch")
    }

    @Test func historyAndLibraryGrids() {
        let h = #"{"a":[{"musicShelfRenderer":{"title":{"runs":[{"text":"Today"}]},"contents":[\#(songRow("vid00000001"))]}},{"musicShelfRenderer":{"title":{"runs":[{"text":"Empty"}]},"contents":[]}}]}"#
        #expect(YTMPageParser.parseHistory(parse(h)).map(\.title) == ["Today"])
        let g = #"{"a":[\#(albumCard("MPREb_1", title: "A")),\#(albumCard("MPREb_1", title: "A again"))],"c":{"nextContinuationData":{"continuation":"N"}}}"#
        let r = YTMPageParser.parseLibraryGrid(parse(g))
        #expect(r.items.count == 1 && r.next == "N")
    }

    @Test func libraryCallsNeedASession() async {
        let t = StubTransport { _, _ in ok("{}") }
        let p = YouTubeMusicFullProvider(client: client(t), resolver: YouTubeMusicStreamResolver(client: client(t)))
        await #expect(throws: MusicError.notSignedIn("YouTube Music")) { _ = try await p.savedAlbums(page: nil) }
        await #expect(throws: MusicError.notSignedIn("YouTube Music")) { _ = try await p.history() }
        #expect(t.count == 0)
    }
}

// MARK: playlist paging

@Suite struct YouTubeMusicPagingTests {
    private func makeToken(position: Int, style: YTMB64Style = YTMB64Style(percent: true, urlSafe: false, padded: true)) -> String {
        let pt = YTMProto.encode([.init(number: 1, varint: UInt64(position)), .init(number: 4, bytes: Array("anchorSetVideoId".utf8))])
        let ptText = "PT:" + YTMB64Style(percent: false, urlSafe: true, padded: false).encode(pt)
        let params = YTMProto.encode([.init(number: 15, bytes: Array(ptText.utf8)), .init(number: 18, varint: 1), .init(number: 30, bytes: [1, 2, 3])])
        let inner = YTMProto.encode([.init(number: 2, bytes: Array("VLPLabc".utf8)), .init(number: 3, bytes: Array(style.encode(params).utf8)), .init(number: 35, bytes: Array("PLabc".utf8))])
        return style.encode(YTMProto.encode([.init(number: YTMPlaylistToken.outerField, bytes: inner)]))
    }

    @Test func tokenRoundTripsAndRewritesPosition() throws {
        let tok = makeToken(position: 100)
        let parsed = try #require(YTMPlaylistToken(tok))
        #expect(parsed.position == 100)
        let moved = try #require(YTMPlaylistToken(parsed.rewritten(position: 300)))
        #expect(moved.position == 300)
        let same = parsed.rewritten(position: 100)
        #expect(YTMPlaylistToken(same)?.position == 100)
    }

    @Test func unknownTokenShapesAreNotRewritten() {
        #expect(YTMPlaylistToken("not a token") == nil)
        let other = YTMB64Style().encode(YTMProto.encode([.init(number: 5, bytes: [1, 2])]))
        #expect(YTMPlaylistToken(other) == nil)
    }

    private func rows(_ ids: [String]) -> [YTMRow] {
        ids.map { YTMRow(track: MusicTrack(id: $0, providerID: "ytmusic", title: $0, durationMs: 0, artists: []), setVideoID: "s" + $0) }
    }

    @Test func joinAcceptsOverlapAndRejectsGapsAndRepeats() {
        var acc = rows(["a", "b", "c"])
        #expect(YTMPlaylistJoin.join(&acc, prevEnd: 3, page: .init(start: 2, rows: rows(["c", "d", "e"]), nextToken: "t", nextPosition: 5)))
        #expect(acc.map(\.track.id) == ["a", "b", "c", "d", "e"])
        var gap = rows(["a", "b"])
        #expect(!YTMPlaylistJoin.join(&gap, prevEnd: 2, page: .init(start: 5, rows: rows(["x"]), nextToken: nil, nextPosition: nil)))
        var repeated = rows(["a", "b", "c"])
        #expect(!YTMPlaylistJoin.join(&repeated, prevEnd: 3, page: .init(start: 3, rows: rows(["d", "a"]), nextToken: nil, nextPosition: nil)))
        var empty = rows(["a"])
        #expect(!YTMPlaylistJoin.join(&empty, prevEnd: 1, page: .init(start: 1, rows: [], nextToken: nil, nextPosition: nil)))
    }
}

// MARK: streams

@Suite struct YouTubeMusicStreamTests {
    private func fmt(_ q: String, _ mime: String, _ bitrate: Int, ch: Int = 2, track: Bool = false, dubbed: Bool = false, def: Bool = true) -> [String: Any] {
        var f: [String: Any] = ["itag": 1, "url": "https://rr1.googlevideo.com/videoplayback?x=\(bitrate)", "mimeType": mime, "bitrate": bitrate, "contentLength": "1000", "audioQuality": q, "audioChannels": ch]
        if track { f["audioTrack"] = ["audioIsDefault": def, "isAutoDubbed": dubbed] }
        return f
    }

    @Test func highQualityPrefersQualityThenChannelsThenCodecThenBitrate() {
        let sd: [String: Any] = ["adaptiveFormats": [
            fmt("AUDIO_QUALITY_MEDIUM", "audio/webm; codecs=\"opus\"", 160_000),
            fmt("AUDIO_QUALITY_HIGH", "audio/mp4; codecs=\"mp4a.40.2\"", 130_000),
            fmt("AUDIO_QUALITY_HIGH", "audio/webm; codecs=\"opus\"", 120_000),
            fmt("AUDIO_QUALITY_HIGH", "audio/webm; codecs=\"opus\"", 250_000, track: true, dubbed: true, def: false),
            ["itag": 2, "url": "https://x", "mimeType": "video/webm", "bitrate": 9, "width": 100] as [String: Any]]]
        let p = YTMFormatPicker.parse(sd)
        let ranked = YTMFormatPicker.ranked(adaptive: p.adaptive, progressive: p.progressive, low: false)
        // WebM cannot be opened by the system player, so the AAC format wins whenever there is one.
        #expect(ranked.first?.bitrate == 130_000)
        #expect(!ranked.contains { $0.isVideo })
        let low = YTMFormatPicker.ranked(adaptive: p.adaptive, progressive: p.progressive, low: true)
        #expect(low.first?.bitrate == 130_000)
    }

    @Test func progressiveAudioIsTheFallbackForPodcastFeeds() {
        let sd: [String: Any] = ["formats": [["itag": 1, "url": "https://feeds.example/ep.mp3", "mimeType": "audio/mpeg", "bitrate": 64_000, "contentLength": "0"] as [String: Any]]]
        let p = YTMFormatPicker.parse(sd)
        #expect(YTMFormatPicker.ranked(adaptive: p.adaptive, progressive: p.progressive, low: false).count == 1)
    }

    @Test func hlsChoosesLowestAacLcVariantOrTheMaster() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=60000,CODECS="mp4a.40.5"
        https://m/144.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=140000,CODECS="mp4a.40.2"
        https://m/240.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="mp4a.40.2"
        https://m/720.m3u8
        """
        #expect(YTMHLS.choose(master: master, low: false, masterURL: "https://m/master") == "https://m/240.m3u8")
        #expect(YTMHLS.choose(master: master, low: true, masterURL: "https://m/master") == "https://m/144.m3u8")
        #expect(YTMHLS.choose(master: "#EXT-X-MEDIA:TYPE=AUDIO\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://m/a", low: false, masterURL: "https://m/master") == "https://m/master")
    }

    private func resolverSetup(visionOS: @escaping @Sendable () -> StubTransport.Reply, now: @escaping @Sendable () -> Date = { Date() }) -> (StubTransport, YouTubeMusicStreamResolver) {
        let t = StubTransport { req, _ in
            switch req.url?.path ?? "" {
            case "/youtubei/v1/player": return visionOS()
            case "/youtubei/v1/navigation/resolve_url": return ok("{}")
            default: return StubTransport.Reply(status: 206, body: Data())
            }
        }
        let c = YouTubeMusicClient(http: MusicHTTP(transport: t), session: GuestYouTubeMusicSession(visitorData: "CgtV"), sleep: { _ in })
        let solver = YTMStreamURLSolver(http: MusicHTTP(transport: t), runner: nil, useRegistry: { false }, cacheDirectory: nil)
        return (t, YouTubeMusicStreamResolver(client: c, solver: solver, now: now))
    }

    private func playerReply(expires: Int = 21540, url: String = "https://rr1---sn.googlevideo.com/videoplayback?id=1") -> StubTransport.Reply {
        ok(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"\#(expires)","adaptiveFormats":[{"itag":251,"url":"\#(url)","mimeType":"audio/webm; codecs=\"opus\"","bitrate":130000,"contentLength":"5000","audioQuality":"AUDIO_QUALITY_HIGH","audioChannels":2}]}}"#)
    }

    @Test func resolverUsesVisionOSFirstWithoutPoTokenAndProbesTheTail() async throws {
        let (t, r) = resolverSetup { playerReply() }
        let s = try await r.resolve(videoID: "vid00000001", title: "T", quality: .high, durationSeconds: 200)
        #expect(s.clientKey == "VISIONOS" && s.streams.count == 1 && s.streams[0].codec == "opus")
        let player = try #require(t.last(path: "player"))
        #expect(player.value(forHTTPHeaderField: "x-youtube-client-name") == "101")
        // The opening, middle and tail probes are sent at the same time (a task group in YouTubeMusicStreams.validate), so which one the stub records last is not
        // fixed. The test checks the whole set: every probe is a GET with identity encoding and the ranges are exactly the ones the product plans for this length.
        let probes = t.requests.filter { $0.url?.host?.hasSuffix("googlevideo.com") == true }
        let planned = Set(YTMClientOrder.probeRanges(length: 5000).map { "bytes=\($0.lowerBound)-\($0.upperBound)" })
        #expect(Set(probes.compactMap { $0.value(forHTTPHeaderField: "Range") }) == planned && planned.contains("bytes=4744-4999"))
        #expect(probes.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
        #expect(t.requests.filter { $0.url?.path.hasSuffix("player") == true }.count == 1)
    }

    @Test func formatsWithoutLengthAreProbedWithHead() async throws {
        let (t, r) = resolverSetup { ok(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[{"itag":1,"url":"https://rr1.googlevideo.com/videoplayback?id=2","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000}]}}"#) }
        _ = try await r.resolve(videoID: "vid00000002", title: "T", quality: .high, durationSeconds: 10)
        #expect(t.requests.last { $0.url?.host?.hasSuffix("googlevideo.com") == true }?.httpMethod == "HEAD")
    }

    @Test func cacheRuleNeedsExpiryBeyondNowPlusSixtyPlusDuration() async throws {
        let clock = Clock0()
        let (t, r) = resolverSetup(visionOS: { playerReply(expires: 1000) }, now: { clock.value })
        _ = try await r.resolve(videoID: "vid00000003", title: "T", quality: .high, durationSeconds: 100)
        _ = try await r.resolve(videoID: "vid00000003", title: "T", quality: .high, durationSeconds: 100)
        #expect(t.requests.filter { $0.url?.path.hasSuffix("player") == true }.count == 1)
        // 1000 s of life left minus 60 minus a 950 s track is not enough: resolve again.
        _ = try await r.resolve(videoID: "vid00000003", title: "T", quality: .high, durationSeconds: 950)
        #expect(t.requests.filter { $0.url?.path.hasSuffix("player") == true }.count == 2)
        clock.advance(2000)
        _ = try await r.resolve(videoID: "vid00000003", title: "T", quality: .high, durationSeconds: 1)
        #expect(t.requests.filter { $0.url?.path.hasSuffix("player") == true }.count == 3)
    }

    @Test func playbackFailureEvictsTheCache() async throws {
        let (t, r) = resolverSetup { playerReply() }
        _ = try await r.resolve(videoID: "vid00000004", title: "T", quality: .high, durationSeconds: 1)
        await r.reportPlaybackFailure(videoID: "vid00000004")
        _ = try await r.resolve(videoID: "vid00000004", title: "T", quality: .high, durationSeconds: 1)
        #expect(t.requests.filter { $0.url?.path.hasSuffix("player") == true }.count == 2)
    }

    @Test func uploadsNeedAnAccountAndAreNeverCached() async {
        let (_, r) = resolverSetup { playerReply() }
        await #expect(throws: MusicError.notSignedIn("YouTube Music")) {
            _ = try await r.resolve(videoID: "vid00000005", title: "T", quality: .high, durationSeconds: 1, isUpload: true)
        }
    }

    @Test func loginRequiredFromEveryGuestClientIsUnavailableNotASignInTask() async {
        let (_, r) = resolverSetup { ok(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}"#) }
        await #expect(throws: MusicError.noPlayableSource("T")) {
            _ = try await r.resolve(videoID: "vid00000006", title: "T", quality: .high, durationSeconds: 1)
        }
    }

    @Test func noAnswerAtAllIsANetworkError() async {
        let (_, r) = resolverSetup { StubTransport.Reply(error: URLError(.notConnectedToInternet)) }
        do { _ = try await r.resolve(videoID: "vid00000007", title: "T", quality: .high, durationSeconds: 1); Issue.record("expected failure") }
        catch let e as MusicError { if case .network = e {} else { Issue.record("wrong error \(e)") } }
        catch { Issue.record("wrong error") }
    }

    /// Routes every `/player` by the client it came from, so a reply can depend on the client. The resolver is signed in.
    private func signedInResolver(_ route: @escaping @Sendable (String) -> StubTransport.Reply) -> (StubTransport, YouTubeMusicStreamResolver) {
        let t = StubTransport { req, _ in
            (req.url?.path ?? "") == "/youtubei/v1/player"
                ? route(req.value(forHTTPHeaderField: "x-youtube-client-name") ?? "")
                : StubTransport.Reply(status: 206, body: Data())
        }
        let c = YouTubeMusicClient(http: MusicHTTP(transport: t), session: FixedSession(signedIn), sleep: { _ in })
        let solver = YTMStreamURLSolver(http: MusicHTTP(transport: t), runner: nil, useRegistry: { false }, cacheDirectory: nil)
        return (t, YouTubeMusicStreamResolver(client: c, solver: solver, verifier: nil))
    }

    @Test func signedInRoutesANormalTrackThroughALoginBearingTVClientFirst() async throws {
        // Every guest client is given the "not a bot" refusal; only the login-bearing TV client (clientID 7) is served a stream. So the
        // track plays only because sign-in now routes it through a client that carries the account cookie and SAPISIDHASH.
        let (t, r) = signedInResolver { clientName in
            clientName == "7"
                ? ok(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[{"itag":140,"url":"https://stream.test/ok.m4a","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000}]}}"#)
                : ok(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#)
        }
        let s = try await r.resolve(videoID: "vid00000010", title: "T", quality: .high, durationSeconds: 200)
        #expect(s.clientKey == "TVHTML5")
        // The very first /player request is the login-bearing TV client, and it carries the real cookie + SAPISIDHASH.
        let firstPlayer = try #require(t.requests.first { ($0.url?.path ?? "").hasSuffix("/player") })
        #expect(firstPlayer.value(forHTTPHeaderField: "x-youtube-client-name") == "7")
        #expect(firstPlayer.value(forHTTPHeaderField: "cookie") == "SID=s; SAPISID=abc123")
        #expect(firstPlayer.value(forHTTPHeaderField: "authorization")?.hasPrefix("SAPISIDHASH ") == true)
    }

    @Test func aGuestNormalTrackNeverReachesALoginBearingClient() async {
        // The same refusal for a guest: no login-bearing TV client is ever in a guest's chain, so there is nothing to carry a cookie and the
        // bot check stands. This is the gap sign-in now closes.
        let (t, r) = signedInResolverGuest { ok(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#) }
        _ = try? await r.resolve(videoID: "vid00000011", title: "T", quality: .high, durationSeconds: 1)
        #expect(!t.requests.contains { ($0.url?.path ?? "").hasSuffix("/player") && $0.value(forHTTPHeaderField: "x-youtube-client-name") == "7" })
    }

    /// A guest copy of `signedInResolver` (no account), to show which clients a guest's chain uses.
    private func signedInResolverGuest(_ route: @escaping @Sendable () -> StubTransport.Reply) -> (StubTransport, YouTubeMusicStreamResolver) {
        let t = StubTransport { req, _ in
            (req.url?.path ?? "") == "/youtubei/v1/player" ? route() : StubTransport.Reply(status: 206, body: Data())
        }
        let c = YouTubeMusicClient(http: MusicHTTP(transport: t), session: GuestYouTubeMusicSession(visitorData: "CgtV"), sleep: { _ in })
        let solver = YTMStreamURLSolver(http: MusicHTTP(transport: t), runner: nil, useRegistry: { false }, cacheDirectory: nil)
        return (t, YouTubeMusicStreamResolver(client: c, solver: solver, verifier: nil))
    }
}

private final class Clock0: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var value: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

// MARK: cache and registry

@Suite struct YouTubeMusicCacheTests {
    @Test func entriesExpireAfterFiveMinutes() {
        let c = Clock0()
        let cache = YouTubeMusicPageCache(now: { c.value })
        cache.set("album:1", "page")
        #expect(cache.get("album:1", as: String.self) == "page")
        c.advance(299)
        #expect(cache.get("album:1", as: String.self) == "page")
        c.advance(2)
        #expect(cache.get("album:1", as: String.self) == nil)
    }

    @Test func capacityIsEightyEvictingTheOldestInsertion() {
        let cache = YouTubeMusicPageCache()
        for i in 0..<85 { cache.set("k\(i)", i) }
        #expect(cache.count == 80)
        #expect(cache.get("k0", as: Int.self) == nil && cache.get("k4", as: Int.self) == nil && cache.get("k5", as: Int.self) == 5)
        cache.set("k5", 55)   // refreshing moves it to the back
        for i in 100..<104 { cache.set("k\(i)", i) }
        #expect(cache.get("k5", as: Int.self) == 55 && cache.get("k6", as: Int.self) == nil)
    }

    @Test func invalidateByPrefixDropsEveryVariant() {
        let cache = YouTubeMusicPageCache()
        cache.set("playlist:PL1", 1); cache.set("playlist:PL1:title:desc", 2); cache.set("playlist:PL10", 3)
        cache.invalidate(prefix: "playlist:PL1")
        #expect(cache.get("playlist:PL1", as: Int.self) == nil && cache.get("playlist:PL1:title:desc", as: Int.self) == nil)
        #expect(cache.get("playlist:PL10", as: Int.self) == 3)
    }
}

@Suite struct YouTubeCipherRegistryTests {
    private let doc = #"""
    {"schemaVersion":1,"players":{
    "abcd1234":{"sig":"Xy(12,34,INPUT)","nClass":"Qz","sts":20123,"aliases":["deadbeef","NOTAHASH!"]},
    "1111aaaa":{"sig":"alert(1);Xy(1,2,INPUT)","nClass":"Qz"},
    "2222bbbb":{"sig":"Xy(1,2,INPUT)","nClass":"Q z; evil()"},
    "../etc":{"sig":"Xy(1,2,INPUT)","nClass":"Qz"}}}
    """#

    @Test func onlyStrictShapesAreAccepted() {
        let t = YouTubeCipherRegistry.parse(Data(doc.utf8))
        #expect(Set(t.keys) == ["abcd1234", "deadbeef"])
        #expect(t["deadbeef"]?.sts == 20123 && t["abcd1234"]?.sig == "Xy(12,34,INPUT)")
    }

    @Test func fetchMergesLaterRegistryOverEarlierAndCaches() async throws {
        let first = #"{"schemaVersion":1,"players":{"abcd1234":{"sig":"A(1,2,INPUT)","nClass":"Q"}}}"#
        let second = #"{"schemaVersion":1,"players":{"abcd1234":{"sig":"B(1,2,INPUT)","nClass":"Q"},"cafe0001":{"sig":"C(1,2,INPUT)","nClass":"Q"}}}"#
        let t = StubTransport { req, _ in ok(req.url?.absoluteString.contains("MetrolistGroup") == true ? second : first) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ytm-registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let reg = YouTubeCipherRegistry(http: MusicHTTP(transport: t), cacheFile: file)
        #expect(await reg.entry(forHash: "abcd1234")?.sig == "B(1,2,INPUT)")
        #expect(await reg.entry(forHash: "cafe0001") != nil)
        #expect(await reg.entry(forHash: "not-a-hash") == nil)
        let reg2 = YouTubeCipherRegistry(http: MusicHTTP(transport: StubTransport { _, _ in StubTransport.Reply(status: 500) }), cacheFile: file)
        #expect(await reg2.entry(forHash: "cafe0001") != nil)
    }

    @Test func registrySettingDefaultsToOn() {
        let d = UserDefaults(suiteName: "ytm-test-\(UUID().uuidString)")!
        #expect(YouTubeMusicSettings.useCipherRegistry(d))
        YouTubeMusicSettings.setUseCipherRegistry(false, defaults: d)
        #expect(!YouTubeMusicSettings.useCipherRegistry(d))
    }

    @Test func exportsAreInsertedBeforeTheClosingMarker() {
        let e = YTMCipherEntry(sig: "Xy(1,2,INPUT)", nClass: "Qz", sts: nil)
        let s = YTMPlayerExports.inject(into: "(function(g){var a=1;})(_yt_player);", entry: e)
        #expect(s.range(of: "__ytmSig")!.lowerBound < s.range(of: "})(_yt_player);")!.lowerBound)
        #expect(YTMPlayerExports.inject(into: "var a=1;", entry: e).contains("__ytmN"))
    }
}
