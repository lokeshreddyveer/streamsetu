import Testing
import Foundation
@testable import REDDY

private final class RouteStub: MusicHTTPTransport, @unchecked Sendable {
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

private func obj(_ s: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(s.utf8)) }
private func dict(_ s: String) throws -> [String: Any] { try #require(try obj(s) as? [String: Any]) }

// MARK: HTTP error mapping

@Suite struct MusicHTTPRefusalTests {
    private func call(_ code: Int, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async -> MusicError? {
        let http = MusicHTTP(transport: RouteStub { _ in (code, "{}") })
        do { _ = try await http.send(url: URL(string: "https://guest.example/x")!, method: method, query: [:], headers: headers, body: body); return nil }
        catch { return error as? MusicError }
    }

    @Test func aGuestRequestRefusedIsNeverASignInProblem() async {
        #expect(await call(401) == .refused("guest.example"))
        #expect(await call(403) == .refused("guest.example"))
    }

    @Test func onlyACallThatSentCredentialsMeansSignIn() async {
        #expect(await call(401, headers: ["Authorization": "Bearer t"]) == .notSignedIn("guest.example"))
        #expect(await call(403, headers: ["Cookie": "SID=1"]) == .notSignedIn("guest.example"))
        #expect(await call(403, headers: ["x-goog-authuser": "0"]) == .notSignedIn("guest.example"))
        #expect(await call(403, method: "POST", body: Data("method=x&sk=abc&format=json".utf8)) == .notSignedIn("guest.example"))
        #expect(await call(403, method: "POST", body: Data("method=x&format=json".utf8)) == .refused("guest.example"))
    }

    @Test func otherStatusesKeepTheirMeaning() async {
        #expect(await call(404) == .notFound)
        #expect(await call(500) == .network("HTTP 500"))
        #expect(await call(200) == nil)
    }

    @Test func refusedReadsAsUnavailableAndFallsThroughAsAnOrdinaryFailure() {
        #expect(MusicError.refused("h").errorDescription?.localizedCaseInsensitiveContains("sign in") == false)
        #expect(MusicFailureKind.classify(MusicError.refused("h")) == .thisTrack)
        #expect(MusicStreamResolver.reason(MusicError.refused("h"), provider: "Audius") == "Audius failed")
    }
}

// MARK: Library signed out

@Suite struct SignedOutLibraryTests {
    @Test func signedOutThereIsOnlyYourLibrary() {
        let list = MusicLibrarySources.available(youTubeAccount: nil, spotifySignedIn: false)
        #expect(list == [.local])
        #expect(MusicLibrarySource.local.title == "Your library")
        #expect(!MusicLibrarySource.local.title.localizedCaseInsensitiveContains("local"))
        #expect(!MusicLibrarySource.local.playlistsTitle.localizedCaseInsensitiveContains("local"))
        #expect(MusicLibrarySource.local.isAccountBacked == false)
    }

    @Test func accountTabsAppearOnlyWhileConnected() {
        let yt = YTMAccountSummary(id: "a1", name: "Me", subtitle: nil, thumbnail: nil, isActive: true, selectionPending: false, hasMultipleChannels: false)
        #expect(MusicLibrarySources.available(youTubeAccount: yt, spotifySignedIn: false) == [.local, .youTubeMusic(accountID: "a1")])
        #expect(MusicLibrarySources.available(youTubeAccount: yt, spotifySignedIn: true).map(\.title) == ["Your library", "YouTube Music", "Spotify"])
        // A remembered account tab that is gone falls back to Your library.
        #expect(MusicLibrarySources.resolve(saved: .spotify, available: [.local]) == .local)
    }

    @Test func likesAndPlaylistsStayInYourLibraryWithoutAnAccount() {
        let wished = MusicPlacementPolicy(likes: .account, playlists: .account)
        #expect(wished.resolved(accountAvailable: false) == MusicPlacementPolicy())
        #expect(MusicPlacement.device.title == "Your library")
    }

    @MainActor @Test func likingAndPlaylistsNeedNoAccount() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("music-so-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = MusicLibrary(directory: dir, debounce: .milliseconds(10))
        let t = MusicTrack(id: "1", providerID: "audius", title: "T", durationMs: 1000, artists: [])
        lib.toggleLike(t)
        let p = lib.createPlaylist(name: "Mix", tracks: [t])
        #expect(lib.isLiked(t) && lib.playlists.first?.id == p.id)
    }
}

// MARK: Home composition

@Suite struct HomeCompositionTests {

    @Test func theChartCountryStartsAsWorldwideAndTheSystemRegionOnlyServesSearches() {
        let d = UserDefaults(suiteName: "region-default-\(UUID().uuidString)")!
        #expect(MusicDiscoveryRegion.current(defaults: d, locale: Locale(identifier: "en_IN")) == MusicDiscoveryRegion.worldwide, "no country is chosen on first run, whatever the system region")
        d.set("fr", forKey: MusicDiscoveryRegion.defaultsKey)
        #expect(MusicDiscoveryRegion.current(defaults: d) == "fr")
        d.set("zz-not-a-country", forKey: MusicDiscoveryRegion.defaultsKey)
        #expect(MusicDiscoveryRegion.current(defaults: d) == MusicDiscoveryRegion.worldwide)
        #expect(MusicDiscoveryRegion.systemDefault(locale: Locale(identifier: "en_IN")) == "in")
        #expect(MusicDiscoveryRegion.systemDefault(locale: Locale(identifier: "fr_FR")) == "fr")
        #expect(ITunesChartsDiscoveryProvider.cleanRegion("../x") == "us")
    }

    @MainActor @Test func discoverySourcesFeedHomeButNeverBecomeTheBrowsingSource() {
        let r = MusicRegistry(defaults: UserDefaults(suiteName: "disc.\(UUID().uuidString)") ?? .standard)
        MusicDiscoveryBuiltIns.register(into: r)
        r.register(AudiusProvider())
        for p in r.all { r.setEnabled(true, id: p.id) }
        #expect(r.activeMetadataID == "audius")
        #expect(r.metadata.map(\.id) == ["audius"])
        #expect(Set(r.discovery.map(\.id)) == ["discover-deezer", "discover-itunes-charts", "discover-audius", "discover-listenbrainz", "discover-jiosaavn", "discover-soundcloud"])
        let browseOnly = r.discovery.allSatisfy { (p: any MusicMetadataProvider) in p.capabilities.contains(.browse) && !p.capabilities.contains(.search) && !p.capabilities.contains(.audio) && !p.info.requiresSignIn }
        #expect(browseOnly, Comment(rawValue: r.discovery.map { "\($0.id) \($0.capabilities.rawValue) \($0.info.requiresSignIn)" }.joined(separator: ",")))
        #expect(MusicSetupPresets.defaultSet(registry: r).isSuperset(of: Set(r.discovery.map(\.id))))
    }
}

// MARK: discovery parsers (canned live replies)

@Suite struct DiscoveryParserTests {
    @Test func deezerChartsMapToMetadataOnlyItems() throws {
        let t = DeezerDiscoveryProvider.tracks(try dict(DiscoveryFixtures.deezerTracks))
        #expect(t.count == 2 && t[0].providerID == "discover-deezer" && t[0].title == "Dracula (with JENNIE)")
        #expect(t[0].artistLine == "Tame Impala" && t[0].durationMs == 209_000 && t[0].explicit)
        #expect(t[0].directStreams == nil && t[0].album?.title == "Dracula (with JENNIE)" && !t[0].thumbnails.isEmpty)
        let al = DeezerDiscoveryProvider.albums(try dict(DiscoveryFixtures.deezerAlbums))
        #expect(al.first?.title == "10,000 Days" && al.first?.artists.first?.name == "TOOL" && al.first?.thumbnails.first?.width == 250)
        let ar = DeezerDiscoveryProvider.artists(try dict(DiscoveryFixtures.deezerArtists))
        #expect(ar.map(\.name) == ["Bad Bunny", "Drake"])
        let pl = DeezerDiscoveryProvider.playlists(try dict(DiscoveryFixtures.deezerPlaylists))
        #expect(pl.first?.name == "GTA VI (Soundtrack 2026 GTA 6)" && pl.first?.trackCount == 54)
    }

    @Test func deezerFeaturedBuildsFourShelvesAndSurvivesOneFailing() async throws {
        let stub = RouteStub { r in
            let p = r.url?.path ?? ""
            if p.hasSuffix("/tracks") { return (200, DiscoveryFixtures.deezerTracks) }
            if p.hasSuffix("/albums") { return (200, DiscoveryFixtures.deezerAlbums) }
            if p.hasSuffix("/artists") { return (200, DiscoveryFixtures.deezerArtists) }
            return (500, "")
        }
        let s = try await DeezerDiscoveryProvider(http: MusicHTTP(transport: stub)).featured()
        #expect(s.map(\.id) == ["deezer-tracks", "deezer-albums", "deezer-artists"])
        let down = RouteStub { _ in (500, "") }
        await #expect(throws: MusicError.self) { _ = try await DeezerDiscoveryProvider(http: MusicHTTP(transport: down)).featured() }
    }

    @Test func deezerErrorBodyIsNotFound() async {
        let stub = RouteStub { _ in (200, #"{"error":{"type":"DataException","code":800}}"#) }
        await #expect(throws: MusicError.notFound) { _ = try await DeezerDiscoveryProvider(http: MusicHTTP(transport: stub)).album(id: "1") }
    }

    @Test func itunesChartsReuseTheCatalogueProviderForDetails() throws {
        let songs = ITunesChartsDiscoveryProvider.songs(try obj(DiscoveryFixtures.itunesSongs))
        #expect(songs.count == 2 && songs[0].providerID == "itunes" && songs[0].id == "6812477273")
        #expect(songs[0].title == "Flower In A Hurricane" && songs[0].artistLine.hasPrefix("Justice"))
        #expect(songs[0].album?.id == "6812476961" && songs[0].album?.title == "Grand Theft Auto VI: The Album")
        #expect(songs[0].thumbnails.last?.url.contains("600x600bb") == true)
        let albums = ITunesChartsDiscoveryProvider.albums(try obj(DiscoveryFixtures.itunesAlbums))
        #expect(albums.first?.providerID == "itunes" && albums.first?.id == "6835557871" && albums.first?.totalTracks == 22)
        #expect(albums.first?.releaseDate == "2026-11-20")
        #expect(ITunesChartsDiscoveryProvider.songs(["feed": [String: Any]()]).isEmpty)
    }

    @Test func itunesFeaturedAsksTheChosenCountryAndNamesIt() async throws {
        let stub = RouteStub { r in (200, (r.url?.path ?? "").contains("topsongs") ? DiscoveryFixtures.itunesSongs : DiscoveryFixtures.itunesAlbums) }
        let p = ITunesChartsDiscoveryProvider(http: MusicHTTP(transport: stub))
        let s = try await p.featured(region: "IN")
        #expect(s.map(\.title) == ["Top songs in India", "Top albums in India"])
        #expect(stub.requests.allSatisfy { $0.url?.path.contains("/in/") == true })
    }

    @Test func audiusTrendingKeepsTheAudiusProviderIdAndSkipsUnstreamable() throws {
        var d = try dict(DiscoveryFixtures.audiusTrending)
        var rows = try #require(d["data"] as? [[String: Any]])
        let tracks = AudiusTrendingDiscoveryProvider.tracks(d)
        #expect(tracks.count == 2 && tracks[0].providerID == "audius" && tracks[0].title == "Beneath the Lily" && tracks[0].durationMs == 188_000)
        #expect(tracks[0].thumbnails.map(\.width) == [150, 480, 1000] && tracks[0].externalURL == "https://audius.co/parasoxmusic/beneath-the-lily")
        rows[0]["is_streamable"] = false; d["data"] = rows
        #expect(AudiusTrendingDiscoveryProvider.tracks(d).count == 1)
    }

    @Test func listenBrainzFreshReleasesNeedCoverArtAndOpenThroughMusicBrainz() async throws {
        let albums = ListenBrainzDiscoveryProvider.albums(try obj(DiscoveryFixtures.lbFresh))
        #expect(albums.map(\.title) == ["20261118A", "Rococo"])
        #expect(albums[0].thumbnails.first?.url == "https://coverartarchive.org/release/2678136d-5a47-4489-8a0d-a3dfbcd0ab43/front-500")   // the 500-pixel image, not the full-size original
        #expect(albums[0].providerID == "discover-listenbrainz")
        let stub = RouteStub { _ in (200, DiscoveryFixtures.mbRelease) }
        let page = try await ListenBrainzDiscoveryProvider(http: MusicHTTP(transport: stub)).albumTracks(id: "a541dba4-7a78-4f88-a115-8fb469c4e963", page: nil)
        #expect(page.items.count == 1 && page.items[0].title == "LIGHT UP THE WORLD" && page.items[0].durationMs == 201_000)
        #expect(stub.requests.first?.url?.path == "/ws/2/release/a541dba4-7a78-4f88-a115-8fb469c4e963")
    }
}
