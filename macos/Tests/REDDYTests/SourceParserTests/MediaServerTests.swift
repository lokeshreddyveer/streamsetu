import Testing
import Foundation
@testable import REDDY

private func obj(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }
private func list(_ s: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] ?? [] }

@Suite struct MediaServerTests {
    private let source = PlaylistSource(name: "Home", type: .jellyfin, baseURL: "http://nas:8096")

    @Test func jellyfinMoviesAndSeries() {
        let m = MediaServerMapper(source: source, base: "http://nas:8096")
        let movies = m.movies(list(#"[{"Id":"abc","Name":"Dune (2021)","ProductionYear":2021,"Overview":"Sand.","CommunityRating":8.1,"RunTimeTicks":91800000000,"Genres":["Sci-Fi"],"Container":"mkv,mp4","ImageTags":{"Primary":"t"},"DateCreated":"2024-05-01T10:20:30.1234567Z"},{"Name":"No id"}]"#))
        #expect(movies.count == 1)
        #expect(movies[0].releaseYear == 2021 && movies[0].durationSeconds == 9180 && movies[0].rating == "8.1")
        #expect(movies[0].streamRef == "abc.mkv" && movies[0].categoryName == "Sci-Fi")
        #expect(movies[0].posterURL == "http://nas:8096/Items/abc/Images/Primary?maxHeight=450")
        #expect(movies[0].addedAt != nil)
    }

    @Test func jellyfinEpisodesGroupBySeasonInNumericOrder() {
        let m = MediaServerMapper(source: source, base: "http://nas:8096")
        let s = m.series(list(#"[{"Id":"s1","Name":"Dexter"}]"#))[0]
        let r = m.episodes(list(#"[{"Id":"e10","ParentIndexNumber":1,"IndexNumber":10,"Name":"Ten"},{"Id":"e2","ParentIndexNumber":1,"IndexNumber":2,"Name":"Two"},{"Id":"e1","ParentIndexNumber":2,"IndexNumber":1,"Name":"S2"}]"#), series: s)
        #expect(r.seasons.map(\.number) == [1, 2])
        #expect(r.episodes.map(\.providerEpisodeID) == ["e2", "e10", "e1"])
    }

    @Test func jellyfinExtrasCarryTrailerCastAndTMDB() {
        let m = MediaServerMapper(source: source, base: "http://nas:8096")
        let e = m.extras(obj(#"{"People":[{"Name":"A","Type":"Actor"},{"Name":"D","Type":"Director"}],"RemoteTrailers":[{"Url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}],"ProviderIds":{"Tmdb":"438631"},"OfficialRating":"PG-13"}"#))
        #expect(e?.trailerKey == "dQw4w9WgXcQ" && e?.cast == ["A"] && e?.directors == ["D"] && e?.tmdbID == 438631 && e?.ageRating == "PG-13")
    }

    @Test func sessionRoundTrips() {
        let s = MediaSession(token: "tok", userID: "u1")
        #expect(MediaSession(encoded: s.encoded) == s)
        #expect(MediaSession(encoded: nil) == nil && MediaSession(encoded: "nopipe") == nil)
    }

    @Test func jellyfinStreamUrlNeedsASessionAndCarriesTheContainer() throws {
        let p = MediaServerProvider(source: source, flavor: .jellyfin, user: "u", pass: "p", session: MediaSession(token: "tok", userID: "u1"), http: HTTPClient(), credentials: InMemoryCredentialStore())
        let url = try p.streamURL(kind: .movie, ref: "abc.mkv")
        #expect(url.path == "/Videos/abc/stream.mkv" && url.query?.contains("api_key=tok") == true)
        #expect(StreamCapabilities.container(for: url) == .mkv)
        let none = MediaServerProvider(source: source, flavor: .emby, user: "u", pass: "p", session: nil, http: HTTPClient(), credentials: InMemoryCredentialStore())
        #expect(throws: SourceError.self) { try none.streamURL(kind: .movie, ref: "abc.mp4") }
    }

    @Test func plexMoviesUseThePartKeyAndToken() throws {
        let src = PlaylistSource(name: "Plex", type: .plex, baseURL: "http://plex:32400")
        let m = PlexMapper(source: src, base: "http://plex:32400", token: "TT")
        let movies = m.movies(list(#"[{"ratingKey":"12","title":"Alien","year":1979,"summary":"Space.","rating":8.4,"duration":7020000,"thumb":"/library/metadata/12/thumb/1","Genre":[{"tag":"Horror"}],"Media":[{"Part":[{"key":"/library/parts/55/1/file.mkv","container":"mkv"}]}],"addedAt":1700000000},{"ratingKey":"13","title":"No media"}]"#))
        #expect(movies.count == 1 && movies[0].durationSeconds == 7020 && movies[0].categoryName == "Horror")
        #expect(movies[0].posterURL == "http://plex:32400/library/metadata/12/thumb/1")        // no token in a stored address
        let p = PlexProvider(source: src, token: "TT", http: HTTPClient())
        #expect(try p.streamURL(kind: .movie, ref: movies[0].streamRef).absoluteString == "http://plex:32400/library/parts/55/1/file.mkv?X-Plex-Token=TT")
    }

    @Test func plexEpisodesAndExtras() {
        let src = PlaylistSource(name: "Plex", type: .plex, baseURL: "http://plex:32400")
        let m = PlexMapper(source: src, base: "http://plex:32400", token: "TT")
        let s = m.series(list(#"[{"ratingKey":"7","title":"Show"}]"#))[0]
        let eps = m.episodes(list(#"[{"ratingKey":"71","index":2,"parentIndex":1,"title":"B","Media":[{"Part":[{"key":"/library/parts/2/1/f.mp4","container":"mp4"}]}]}]"#), series: s, seasonNumber: 1)
        #expect(eps.count == 1 && eps[0].episodeNumber == 2 && eps[0].streamRef == "/library/parts/2/1/f.mp4")
        let e = m.extras(obj(#"{"Role":[{"tag":"X"}],"Director":[{"tag":"Y"}],"contentRating":"TV-MA","Guid":[{"id":"tmdb://1399"}]}"#))
        #expect(e?.cast == ["X"] && e?.directors == ["Y"] && e?.tmdbID == 1399)
    }
}

@Suite struct StalkerTests {
    private let source = PlaylistSource(name: "Portal", type: .stalker, baseURL: "http://portal.example/c/")

    @Test func portalAddresses() {
        #expect(StalkerProvider.portalBase("http://host/stalker_portal/c/") == "http://host/stalker_portal")
        #expect(StalkerProvider.portalBase("http://host:8080/c") == "http://host:8080")
        #expect(StalkerProvider.portalBase("http://host/") == "http://host")
        #expect(StalkerProvider.candidateEndpoints(portal: "http://h").first == "http://h/server/load.php")
    }

    @Test func macAddresses() {
        #expect(StalkerMapper.normalizedMAC("00:1a:79:aa:bb:cc") == "00:1A:79:AA:BB:CC")
        #expect(StalkerMapper.normalizedMAC("001A79AABBCC") == "00:1A:79:AA:BB:CC")
        #expect(StalkerMapper.normalizedMAC("not a mac") == nil)
        #expect(StalkerMapper.deviceID(mac: "00:1A:79:AA:BB:CC") == StalkerMapper.deviceID(mac: "00:1a:79:aa:bb:cc"))
    }

    @Test func commandsYieldTheStreamAddress() {
        #expect(StalkerMapper.address(fromCommand: "ffmpeg http://s/live/1.ts") == "http://s/live/1.ts")
        #expect(StalkerMapper.address(fromCommand: "ffrt4 http://localhost/ch/12") == "http://localhost/ch/12")
        #expect(StalkerMapper.address(fromCommand: "ffmpeg") == nil)
    }

    @Test func channelsAndGenres() {
        let m = StalkerMapper(source: source)
        let g = m.genres(try? JSONSerialization.jsonObject(with: Data(#"[{"id":"1","title":"News"},{"id":"*","title":"All"}]"#.utf8)))
        #expect(g == ["1": "News"])
        let ch = m.channels(list(#"[{"id":"101","name":"BBC One","cmd":"ffrt http://localhost/ch/101","tv_genre_id":"1","number":"5","logo":"http://l/1.png","xmltv_id":"bbc1"},{"id":"2","name":"Broken"}]"#), genres: g)
        #expect(ch.count == 1 && ch[0].categoryName == "News" && ch[0].sortOrder == 5 && ch[0].epgID == "bbc1" && ch[0].streamRef == "ffrt http://localhost/ch/101")
    }

    @Test func portalLinksRoundTripAndPlayerSeesAStandIn() throws {
        let u = try #require(PortalLink.make(kind: .channel, ref: "ffrt http://localhost/ch/101#x=1"))
        #expect(u.scheme == PortalLink.scheme)
        let back = try #require(PortalLink.parse(u))
        #expect(back.kind == .channel && back.ref == "ffrt http://localhost/ch/101#x=1")
        #expect(PortalLink.parse(URL(string: "http://x/y")!) == nil)
        let p = StalkerProvider(source: source, mac: "00:1A:79:AA:BB:CC", http: HTTPClient())
        #expect(try p.streamURL(kind: .movie, ref: "cmd").scheme == PortalLink.scheme)
    }

    @Test func moviesSkipSeriesAndSeriesDetailListsEpisodes() {
        let m = StalkerMapper(source: source)
        let movies = m.movies(list(#"[{"id":"1","name":"Film (2020)","cmd":"/media/1.mpg","year":"2020","category_id":"4"},{"id":"2","name":"A Show","cmd":"x","is_series":"1"}]"#), genres: ["4": "Drama"], portal: "http://portal.example")
        #expect(movies.count == 1 && movies[0].categoryName == "Drama")
        let s = m.series(list(#"[{"id":"2","name":"A Show"}]"#), genres: [:], portal: "http://portal.example")[0]
        let d = m.detail(try! JSONSerialization.jsonObject(with: Data(#"{"cmd":"/media/s2","series":[1,2,3]}"#.utf8)) as! [String: Any], series: s)
        #expect(d.episodes.count == 3 && d.episodes[2].streamRef == "/media/s2#series=3")
    }
}

@Suite struct ProxyAndAuthTests {
    @Test func proxyDictionaries() {
        #expect(ProxyConfig().connectionDictionary == nil && !ProxyConfig().isActive)
        let http = ProxyConfig(kind: .http, host: "10.0.0.2", port: 8080)
        #expect(http.isActive && http.mpvValue == "http://10.0.0.2:8080" && http.connectionDictionary?["HTTPProxy"] as? String == "10.0.0.2")
        let socks = ProxyConfig(kind: .socks5, host: "p", port: 1080)
        #expect(socks.connectionDictionary?["SOCKSPort"] as? Int == 1080 && socks.mpvValue == nil)
        #expect(!ProxyConfig(kind: .http, host: "", port: 80).isActive && !ProxyConfig(kind: .http, host: "h", port: 0).isActive)
    }

    @Test func httpAuthHeaders() {
        #expect(SourceManager.authorization(for: Credentials(username: "u", password: "p")) == "Basic dTpw")
        #expect(SourceManager.authorization(for: Credentials(username: nil, password: "tok")) == "Bearer tok")
        #expect(SourceManager.authorization(for: Credentials(username: nil, password: nil, url: "http://x")) == nil)
    }

    @Test func aPlexTokenGoesOnlyToItsOwnServer() throws {
        let db = try TestSupport.makeDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let store = InMemoryCredentialStore()
        try store.save(Credentials(username: nil, password: "TT", url: nil), ref: "plex-ref")
        try catalog.save(source: PlaylistSource(name: "Plex", type: .plex, baseURL: "http://plex.local:32400", credentialRef: "plex-ref"))
        let manager = SourceManager(catalog: catalog, credentials: store, http: HTTPClient())
        #expect(manager.artworkHeaders(for: URL(string: "http://plex.local:32400/library/metadata/1/thumb")!) == ["X-Plex-Token": "TT"])
        #expect(manager.artworkHeaders(for: URL(string: "http://elsewhere.example:32400/x.jpg")!).isEmpty)
        #expect(manager.artworkHeaders(for: URL(string: "http://plex.local:8080/x.jpg")!).isEmpty)       // same name, another port: not the server
    }
}

@Suite struct PlexTokenCleanupTests {
    @Test func aStoredPictureAddressLosesItsTokenAndOthersAreLeftAlone() throws {
        let db = try TestSupport.makeDB()
        let source = try TestSupport.makeSource(db, name: "Plex", type: .plex)
        var withToken = TestSupport.movie(source, "1", "Alien"); withToken.posterURL = "http://plex:32400/library/metadata/1/thumb/9?X-Plex-Token=SECRET"
        var clean = TestSupport.movie(source, "2", "Heat"); clean.posterURL = "http://img.example/heat.jpg"
        let catalog = SQLiteCatalogRepository(db: db)
        try db.write { c in
            for m in [withToken, clean] { try c.execute("INSERT INTO movies(id, source_id, provider_id, title, normalized_title, poster_url, stream_ref, created_at, updated_at, last_seen_at) VALUES(?,?,?,?,?,?,?,?,?,?)", [m.id, m.sourceID, m.providerID, m.title, m.normalizedTitle, m.posterURL, m.streamRef, Date(), Date(), Date()]) }
        }
        try PlexTokenCleanup.run(db)
        #expect(try catalog.movie(id: withToken.id)?.posterURL == "http://plex:32400/library/metadata/1/thumb/9")
        #expect(try catalog.movie(id: clean.id)?.posterURL == "http://img.example/heat.jpg")
        try PlexTokenCleanup.run(db)                                    // running it again changes nothing
        #expect(try catalog.movie(id: withToken.id)?.posterURL == "http://plex:32400/library/metadata/1/thumb/9")
    }
}
