import Foundation
import Testing
@testable import REDDY

// Contract tests for Spotify with no account: the embed page shapes below are trimmed copies of what open.spotify.com/embed/<kind>/<id> returned
// in November 2026, with titles and ids made up. No test touches the network.

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL?) { lock.lock(); if let u { urls.append(u) }; lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    func hosts() -> Set<String> { Set(all.compactMap(\.host)) }
}

private struct RouteTransport: MusicHTTPTransport {
    let calls: Calls
    let handler: @Sendable (URLRequest) -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.add(request.url)
        let (code, body) = handler(request)
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private func http(_ calls: Calls = Calls(), _ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> MusicHTTP {
    MusicHTTP(transport: RouteTransport(calls: calls, handler: handler))
}

private func page(_ entityJSON: String) -> String {
    "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"state\":{\"data\":{\"entity\":\(entityJSON)},\"settings\":{\"session\":{\"accessToken\":\"anonymous-web-token\",\"isAnonymous\":true}}}}}}</script></body></html>"
}

private let nbsp = "\u{00A0}"

private let trackEntity = """
{"type":"track","name":"Song One","uri":"spotify:track:1111111111111111111111","id":"1111111111111111111111","title":"Song One",
 "artists":[{"name":"Band A","uri":"spotify:artist:2222222222222222222222"},{"name":"Band B","uri":"spotify:artist:3333333333333333333333"}],
 "releaseDate":{"isoString":"1987-11-12T00:00:00Z"},"duration":213573,"isExplicit":true,"audioPreview":{"url":"https://p.scdn.co/mp3-preview/x"},
 "visualIdentity":{"image":[{"url":"https://img/300","maxWidth":300,"maxHeight":300},{"url":"https://img/640","maxWidth":640,"maxHeight":640},{"url":"https://img/64","maxWidth":64,"maxHeight":64}]}}
"""

private func rows(_ n: Int) -> String {
    (0..<n).map { i in
        let id = String(format: "%022d", i)
        return "{\"uri\":\"spotify:track:\(id)\",\"title\":\"Song \(i)\",\"subtitle\":\"Band A,\(nbsp)Tyler, The Creator\",\"isExplicit\":\(i == 0),\"duration\":\(200_000 + i),\"entityType\":\"track\"}"
    }.joined(separator: ",")
}

private func playlistEntity(rows n: Int, extra: String = "") -> String {
    "{\"type\":\"playlist\",\"name\":\"Road Mix\",\"id\":\"pl1\",\"subtitle\":\"Some Owner\",\"coverArt\":{\"sources\":[{\"url\":\"https://img/pl\",\"width\":null,\"height\":null}]},\"trackList\":[\(rows(n))\(extra)],\"visualIdentity\":{\"image\":[{\"url\":\"https://img/pl64\",\"maxWidth\":64,\"maxHeight\":64}]}}"
}

private let albumEntity = """
{"type":"album","name":"Big Album","id":"al1","subtitle":"Band A","releaseDate":null,"trackList":[
 {"uri":"spotify:track:aaaaaaaaaaaaaaaaaaaaaa","title":"Opener (feat. Guest)","subtitle":"Band A,\(nbsp)Guest","isExplicit":true,"duration":85400,"entityType":"track"},
 {"uri":"spotify:track:bbbbbbbbbbbbbbbbbbbbbb","title":"Closer","subtitle":"Band A","isExplicit":false,"duration":180000,"entityType":"track"}],
 "visualIdentity":{"image":[{"url":"https://img/a300","maxWidth":300,"maxHeight":300},{"url":"https://img/a640","maxWidth":640,"maxHeight":640}]}}
"""

private let artistEntity = """
{"type":"artist","name":"Band A","id":"ar1","subtitle":"Top tracks","trackList":[
 {"uri":"spotify:track:cccccccccccccccccccccc","title":"Hit","subtitle":"Band A","isExplicit":false,"duration":300000,"entityType":"track"}],
 "visualIdentity":{"image":[{"url":"https://img/ar320","maxWidth":320,"maxHeight":320},{"url":"https://img/ar640","maxWidth":640,"maxHeight":640}]}}
"""

private let notFoundPage = "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"status\":404,\"title\":\"Page not found\"}}}</script>"

private func embedHandler(_ req: URLRequest) -> (Int, String) {
    guard let u = req.url, u.host == "open.spotify.com" else { return (500, "") }
    let p = u.path
    if p.hasPrefix("/embed/track/") { return p.hasSuffix("0000000000000000000000") ? (200, notFoundPage) : (200, page(trackEntity)) }
    if p.hasPrefix("/embed/album/") { return (200, page(albumEntity)) }
    if p.hasPrefix("/embed/artist/") { return (200, page(artistEntity)) }
    if p.hasPrefix("/embed/playlist/") { return (200, page(playlistEntity(rows: 3))) }
    return (404, "")
}

private func signedOutProvider(_ calls: Calls = Calls(), store: MemorySpotifySecretStore = MemorySpotifySecretStore(),
                               handler: @escaping @Sendable (URLRequest) -> (Int, String) = embedHandler) -> SpotifyProvider {
    let h = http(calls, handler)
    return SpotifyProvider(http: h, auth: SpotifyAuth(http: h, store: store))
}

@Suite struct SpotifySignedOutLinkTests {
    @Test func linksInEveryShape() {
        let id = "4cOdK2wGLETKBW3PvgPWqT"
        #expect(SpotifyLink.parse("https://open.spotify.com/track/\(id)?si=abc") == SpotifyLink(kind: .track, id: id))
        #expect(SpotifyLink.parse("https://open.spotify.com/intl-de/track/\(id)")?.kind == .track)
        #expect(SpotifyLink.parse("open.spotify.com/artist/\(id)")?.kind == .artist)
        #expect(SpotifyLink.parse("spotify:album:\(id)")?.kind == .album)
        #expect(SpotifyLink.parse("spotify:user:someone:playlist:\(id)") == SpotifyLink(kind: .playlist, id: id))
        #expect(SpotifyLink.parse("https://open.spotify.com/embed/playlist/\(id)")?.kind == .playlist)
    }

    @Test func shareTextAndWrappedLinks() {
        let id = "4cOdK2wGLETKBW3PvgPWqT"
        #expect(SpotifyLink.parse("Listen to Song on Spotify: https://open.spotify.com/track/\(id)?si=zz.")?.id == id)
        #expect(SpotifyLink.parse("<https://open.spotify.com/album/\(id)>")?.kind == .album)
        #expect(SpotifyLink.parse("my favourite (spotify:playlist:\(id)) ever")?.kind == .playlist)
        #expect(SpotifyLink.parse("no link here, just words about spotify.com") == nil)
        #expect(SpotifyLink.parse("https://example.com/track/\(id)") == nil)
        #expect(SpotifyLink.parse("https://open.spotify.com/show/\(id)") == nil)
    }

    @Test func creditLinesSplitOnTheNoBreakSpace() {
        #expect(SpotifyEmbedPage.names(fromCredit: "A,\(nbsp)B,\(nbsp)Tyler, The Creator") == ["A", "B", "Tyler, The Creator"])
        #expect(SpotifyEmbedPage.names(fromCredit: "A, B") == ["A", "B"])
        #expect(SpotifyEmbedPage.names(fromCredit: nil).isEmpty)
    }
}

@Suite struct SpotifySignedOutBrowseTests {
    @Test func capabilitiesAreHonestWithNothingSetUp() async {
        let p = signedOutProvider()
        #expect(!p.capabilities.contains(.search) && !p.capabilities.contains(.library) && !p.capabilities.contains(.browse))
        #expect(p.capabilities.isSuperset(of: [.tracks, .albums, .artists, .playlists]))
        #expect(p.emptyHint == "Paste a link to open a Spotify playlist, album or song")
        #expect(await p.isSignedIn == false)
        #expect(p.info.requiresSignIn == false)
    }

    @Test func trackPageGivesMetadataOnlyTrack() async throws {
        let calls = Calls()
        let p = signedOutProvider(calls)
        let t = try await p.track(id: "1111111111111111111111")
        #expect(t.uid == "spotify:1111111111111111111111" && t.title == "Song One" && t.durationMs == 213_573 && t.explicit)
        #expect(t.artists.map(\.name) == ["Band A", "Band B"] && t.artists.map(\.id) == ["2222222222222222222222", "3333333333333333333333"])
        #expect(t.thumbnails.best(minSide: 600) == "https://img/640")
        #expect(t.directStreams == nil && t.isrc == nil)
        // The embed page's 30 s preview is captured as previewURL; it is a preview clip, not a full stream, so directStreams stays nil.
        #expect(t.previewURL == "https://p.scdn.co/mp3-preview/x")
        #expect(calls.hosts() == ["open.spotify.com"])
    }

    @Test func albumAndItsTracksCarryTheCover() async throws {
        let p = signedOutProvider()
        let a = try await p.album(id: "al1")
        #expect(a.title == "Big Album" && a.artists.map(\.name) == ["Band A"] && a.totalTracks == 2 && a.thumbnails.best(minSide: 600) == "https://img/a640")
        let t = try await p.albumTracks(id: "al1", page: nil)
        #expect(t.items.map(\.title) == ["Opener (feat. Guest)", "Closer"] && t.items[0].artists.map(\.name) == ["Band A", "Guest"])
        #expect(t.items.allSatisfy { $0.album?.id == "al1" && $0.album?.title == "Big Album" } && t.next == nil && t.totalCount == 2)
        #expect(t.items[0].explicit && t.items[0].durationMs == 85_400)
    }

    @Test func artistPageGivesTopTracksAndPhoto() async throws {
        let p = signedOutProvider()
        let a = try await p.artist(id: "ar1")
        #expect(a.name == "Band A" && a.thumbnails.best(minSide: 600) == "https://img/ar640")
        #expect(try await p.artistTopTracks(id: "ar1").map(\.title) == ["Hit"])
        // Albums and related artists need a developer key: empty, not an error.
        #expect(try await p.artistAlbums(id: "ar1", page: nil).items.isEmpty)
        #expect(try await p.relatedArtists(id: "ar1").isEmpty)
        let overview = try await p.artistOverview(id: "ar1")
        #expect(overview.topTracks.count == 1 && overview.albums.isEmpty)
    }

    @Test func playlistPagesSliceTheEmbedRows() async throws {
        let p = signedOutProvider()
        let pl = try await p.playlist(id: "pl1")
        #expect(pl.name == "Road Mix" && pl.owner == "Some Owner" && pl.trackCount == 3 && pl.thumbnails.best(minSide: 600) == "https://img/pl")
        let first = try await p.playlistTracks(id: "pl1", page: .offset(offset: 0, limit: 2))
        #expect(first.items.count == 2 && first.totalCount == 3 && first.next == .offset(offset: 2, limit: 2))
        let last = try await p.playlistTracks(id: "pl1", page: first.next)
        #expect(last.items.count == 1 && last.next == nil)
        let t = first.items[0]
        #expect(t.artists.map(\.name) == ["Band A", "Tyler, The Creator"] && t.explicit && t.durationMs == 200_000 && t.id == String(format: "%022d", 0))
    }

    @Test func playlistWithOneHundredRowsIsMarkedPossiblyLonger() throws {
        let html = Data(page(playlistEntity(rows: 100)).utf8)
        let e = try SpotifyEmbedEntity.parse(html: html, link: SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(e.rows.count == 100 && e.mayBeTruncated && e.playlistModel.trackCount == nil)
        let short = try SpotifyEmbedEntity.parse(html: Data(page(playlistEntity(rows: 99)).utf8), link: SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(!short.mayBeTruncated && short.playlistModel.trackCount == 99)
    }

    @Test func episodesAndBrokenRowsAreSkipped() throws {
        let extra = ",{\"uri\":\"spotify:episode:e1\",\"title\":\"Pod\",\"subtitle\":\"X\",\"entityType\":\"episode\"},{\"uri\":\"spotify:track:zzzzzzzzzzzzzzzzzzzzzz\",\"title\":\"  \",\"subtitle\":\"Y\",\"entityType\":\"track\"}"
        let e = try SpotifyEmbedEntity.parse(html: Data(page(playlistEntity(rows: 2, extra: extra)).utf8), link: SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(e.rows.count == 2)
    }

    @Test func privateOrMissingItemsAreNotFoundNotErrorsAboutSignIn() async {
        let p = signedOutProvider()
        await #expect(throws: MusicError.notFound) { _ = try await p.track(id: "0000000000000000000000") }
        let gone = signedOutProvider { _ in (404, "") }
        await #expect(throws: MusicError.notFound) { _ = try await gone.album(id: "al1") }
    }

    @Test func aChangedPageIsANetworkProblemNotASignInError() async {
        let p = signedOutProvider { _ in (200, "<html>nothing</html>") }
        do { _ = try await p.track(id: "t1"); Issue.record("expected an error") }
        catch let e as MusicError { if case .network = e {} else { Issue.record("wrong error \(e)") } }
        catch { Issue.record("wrong error") }
    }

    @Test func searchSkipsQuietlyWithoutAKey() async throws {
        let calls = Calls()
        let p = signedOutProvider(calls)
        #expect(try await p.search("hello", types: [.track, .album]).isEmpty)
        #expect(try await p.searchTracks("hello", page: nil).items.isEmpty)
        #expect(try await p.searchPlaylists("hello", page: nil).items.isEmpty)
        #expect(try await p.featured().isEmpty)
        #expect(try await p.genres().isEmpty)
        #expect(try await p.browse(genreID: "pop", page: nil).items.isEmpty)
        #expect(try await p.recommendations(seedTrackIDs: ["a"], limit: 5).isEmpty)
        #expect(try await p.savedTracks(page: nil).items.isEmpty)
        #expect(try await p.savedPlaylists(page: nil).items.isEmpty)
        #expect(try await p.isSaved(trackIDs: ["a", "b"]) == [false, false])
        #expect(calls.all.isEmpty)
    }

    @Test func aPastedLinkInTheSearchBoxOpensThatItem() async throws {
        let p = signedOutProvider()
        let r = try await p.search("Have a listen https://open.spotify.com/album/al1?si=abc", types: [.track])
        guard case .album(let a)? = r.first, r.count == 1 else { Issue.record("expected the album"); return }
        #expect(a.title == "Big Album")
        let t = try await p.searchTracks("spotify:track:1111111111111111111111", page: nil)
        #expect(t.items.map(\.title) == ["Song One"])
    }

    @Test func playlistRowArtistsKnownOnlyByNameStillRoundTrip() {
        let id = SpotifyMapper.nameID("Tyler, The Creator")
        #expect(SpotifyMapper.name(fromID: id) == "Tyler, The Creator")
        #expect(id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(SpotifyMapper.name(fromID: "2222222222222222222222") == nil)
    }

    @Test func theAnonymousWebPlayerTokenIsNeverUsed() async throws {
        let calls = Calls()
        let seen = SeenHeaders()
        let p = signedOutProvider(calls) { req in
            seen.add(req)
            return embedHandler(req)
        }
        _ = try await p.playlistTracks(id: "pl1", page: nil)
        _ = try await p.track(id: "1111111111111111111111")
        #expect(seen.authorization.isEmpty)
        #expect(calls.all.allSatisfy { $0.host == "open.spotify.com" })
    }
}

private final class SeenHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ r: URLRequest) { if let a = r.value(forHTTPHeaderField: "Authorization") { lock.lock(); values.append(a); lock.unlock() } }
    var authorization: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

// MARK: app-only mode

@Suite struct SpotifyAppOnlyTests {
    private let tokenJSON = #"{"access_token":"app-token","token_type":"Bearer","expires_in":3600}"#

    private func handler(_ calls: Calls) -> @Sendable (URLRequest) -> (Int, String) {
        let token = tokenJSON
        return { req in
            guard let u = req.url else { return (500, "") }
            if u.host == "accounts.spotify.com" {
                let basic = req.value(forHTTPHeaderField: "Authorization") ?? ""
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                let expect = "Basic " + Data("the-id:the-secret".utf8).base64EncodedString()
                return basic == expect && body == "grant_type=client_credentials" ? (200, token) : (400, #"{"error":"invalid_client"}"#)
            }
            if u.host == "api.spotify.com" {
                guard req.value(forHTTPHeaderField: "Authorization") == "Bearer app-token" else { return (401, "{}") }
                if u.path == "/v1/search" {
                    return (200, #"{"tracks":{"total":1,"next":null,"items":[{"id":"t1","name":"Found","duration_ms":1000,"external_ids":{"isrc":"USAAA0000001"},"artists":[{"id":"a1","name":"Band"}],"album":{"id":"al1","name":"Alb","images":[{"url":"https://i/1","width":300,"height":300}]}}]}}"#)
                }
                if u.path == "/v1/playlists/pl1/items" { return (403, "{}") }
                if u.path == "/v1/artists/ar1/top-tracks" { return (403, "{}") }
                if u.path == "/v1/browse/new-releases" { return (404, "{}") }
                if u.path == "/v1/browse/categories" { return (404, "{}") }
                if u.path == "/v1/artists/ar1/albums" {
                    return (200, #"{"total":1,"next":null,"items":[{"id":"al1","name":"Alb","album_type":"album","artists":[{"id":"ar1","name":"Band"}]}]}"#)
                }
                return (404, "{}")
            }
            return embedHandler(req)
        }
    }

    private func keyed(_ calls: Calls = Calls()) -> SpotifyProvider {
        signedOutProvider(calls, store: MemorySpotifySecretStore(["spotify.clientID": "the-id", "spotify.clientSecret": "the-secret"]), handler: handler(calls))
    }

    @Test func keysEnableSearchAndBrowseButNotTheLibrary() async {
        let p = keyed()
        #expect(p.capabilities.contains(.search) && p.capabilities.contains(.browse) && !p.capabilities.contains(.library))
        #expect(p.emptyHint == nil)
        #expect(await p.isSignedIn == false)
    }

    @Test func searchUsesTheClientCredentialsToken() async throws {
        let calls = Calls()
        let p = keyed(calls)
        let r = try await p.searchTracks("anything", page: nil)
        #expect(r.items.map(\.title) == ["Found"] && r.items[0].isrc == "USAAA0000001")
        #expect(calls.hosts() == ["accounts.spotify.com", "api.spotify.com"])
        let limit = calls.all.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value }
        #expect(limit == "10")
    }

    @Test func refusedApiCallsFallBackToTheEmbedPage() async throws {
        let p = keyed()
        // The API says 403 for these (removed or not owned), the embed page still answers.
        #expect(try await p.playlistTracks(id: "pl1", page: nil).items.count == 3)
        #expect(try await p.artistTopTracks(id: "ar1").map(\.title) == ["Hit"])
        #expect(try await p.featured().isEmpty)
        #expect(try await p.genres().isEmpty)
        #expect(try await p.artistAlbums(id: "ar1", page: nil).items.map(\.title) == ["Alb"])
    }

    @Test func wrongKeysAreQuietAndKeepTheEmbedPath() async throws {
        let calls = Calls()
        let wrong = signedOutProvider(calls, store: MemorySpotifySecretStore(["spotify.clientID": "x", "spotify.clientSecret": "y"]), handler: handler(calls))
        #expect(try await wrong.search("q", types: [.track]).isEmpty)
        #expect(try await wrong.track(id: "1111111111111111111111").title == "Song One")
    }

    @Test func setAppKeysChecksThemAndUpdatesCapabilities() async {
        let calls = Calls()
        let store = MemorySpotifySecretStore()
        let p = signedOutProvider(calls, store: store, handler: handler(calls))
        #expect(!p.capabilities.contains(.search))
        let bad = await p.setAppKeys(clientID: "nope", secret: "nope")
        #expect(!bad)
        let ok = await p.setAppKeys(clientID: " the-id ", secret: " the-secret ")
        #expect(ok && p.capabilities.contains(.search))
        #expect(store.read("spotify.clientSecret") == "the-secret")
        await p.clearAppKeys()
        #expect(!p.capabilities.contains(.search) && store.read("spotify.clientSecret") == nil)
    }

    @Test func secretsAreNotEmbeddedInTheApp() throws {
        // The client id and secret exist only in the Keychain; the sources hold no key-looking constant.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Services/Music")
        let files = ["Providers/SpotifyAuth.swift", "Providers/SpotifyProvider.swift", "Providers/SpotifyEmbed.swift"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            #expect(text.range(of: "[0-9a-f]{32}", options: .regularExpression) == nil)
        }
    }
}

func apiPage(_ from: Int, _ n: Int, total: Int) -> String {
    let items = (from..<(from + n)).map { i in "{\"item\":{\"type\":\"track\",\"id\":\"\(String(format: "%022d", i))\",\"name\":\"Song \(i)\",\"duration_ms\":1000,\"artists\":[{\"name\":\"Band A\"}],\"album\":{\"name\":\"Alb\"}}}" }
    return "{\"total\":\(total),\"items\":[\(items.joined(separator: ","))]}"
}

@Suite struct SpotifyImportReaderTests {
    @Test func embedPageBecomesAnImportList() throws {
        let list = try SpotifyEmbedParser.parse(html: Data(page(playlistEntity(rows: 3)).utf8), link: SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(list.name == "Road Mix" && list.owner == "Some Owner" && list.kind == .playlist && list.coverURL == "https://img/pl" && list.shareURL?.hasSuffix("/playlist/pl1") == true)
        #expect(list.tracks.count == 3 && !list.truncated)
        #expect(list.tracks[0].artists == ["Band A", "Tyler, The Creator"] && list.tracks[0].explicit == true && list.tracks[0].durationMs == 200_000)
        #expect(list.tracks[0].spotifyID == String(format: "%022d", 0))
    }

    @Test func albumListNamesTheAlbumOnEachRow() throws {
        let list = try SpotifyEmbedParser.parse(html: Data(page(albumEntity).utf8), link: SpotifyLink(kind: .album, id: "al1"))
        #expect(list.kind == .album && list.tracks.allSatisfy { $0.album == "Big Album" } && list.tracks[0].artists == ["Band A", "Guest"])
    }

    @Test func hundredRowsWithoutAKeyStayTruncatedAndFlagged() async throws {
        let h = http { req in
            if req.url?.host == "open.spotify.com" { return (200, page(playlistEntity(rows: 100))) }
            return (500, "")
        }
        let list = try await SpotifyLinkReader(http: h).read(SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(list.tracks.count == 100 && list.truncated)
    }

    @Test func aDeveloperKeyReadsTheRestOfALongPlaylist() async throws {
        let h = http { req in
            guard let u = req.url else { return (500, "") }
            if u.host == "accounts.spotify.com" { return (200, #"{"access_token":"app-token","expires_in":3600}"#) }
            if u.host == "api.spotify.com" {
                let off = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
                return (200, apiPage(off, min(50, 120 - off), total: 120))
            }
            return (200, page(playlistEntity(rows: 100)))
        }
        let auth = SpotifyAuth(http: h, store: MemorySpotifySecretStore(["spotify.clientID": "id", "spotify.clientSecret": "secret"]))
        var reader = SpotifyLinkReader(http: h, auth: auth)
        reader.pageDelay = {}
        let list = try await reader.read(SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(list.tracks.count == 120 && !list.truncated)
    }

    @Test func aRefusedApiKeepsTheFirstHundred() async throws {
        let h = http { req in
            guard let u = req.url else { return (500, "") }
            if u.host == "accounts.spotify.com" { return (200, #"{"access_token":"app-token","expires_in":3600}"#) }
            if u.host == "api.spotify.com" { return (403, "{}") }
            return (200, page(playlistEntity(rows: 100)))
        }
        let auth = SpotifyAuth(http: h, store: MemorySpotifySecretStore(["spotify.clientID": "id", "spotify.clientSecret": "secret"]))
        var reader = SpotifyLinkReader(http: h, auth: auth)
        reader.pageDelay = {}
        let list = try await reader.read(SpotifyLink(kind: .playlist, id: "pl1"))
        #expect(list.tracks.count == 100 && list.truncated)
    }

    @Test func privateListsAreReportedAsPrivate() async {
        let h = http { _ in (200, notFoundPage) }
        await #expect(throws: ImportError.private) { _ = try await SpotifyLinkReader(http: h).read(SpotifyLink(kind: .playlist, id: "p")) }
        let gone = http { _ in (404, "") }
        await #expect(throws: ImportError.private) { _ = try await SpotifyLinkReader(http: gone).read(SpotifyLink(kind: .album, id: "p")) }
    }

    @Test func playlistApiPagesParseLocalFilesAndSkips() throws {
        let json = #"{"total":3,"items":[{"item":{"type":"track","id":"aaaaaaaaaaaaaaaaaaaaaa","name":"One","duration_ms":5,"artists":[{"name":"A"}]}},{"item":{"is_local":true,"uri":"spotify:local:Me:Alb:Local+Song:60"}},{"item":{"type":"episode","id":"e"}},null]}"#
        let p = try SpotifyPlaylistAPI.parsePage(Data(json.utf8))
        #expect(p.total == 3 && p.tracks.map(\.title) == ["One", "Local Song"] && p.skipped == 1)
        #expect(throws: ImportError.spotifyChanged) { try SpotifyPlaylistAPI.parsePage(Data(#"{"nothing":1}"#.utf8)) }
    }
}
