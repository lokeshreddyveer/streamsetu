import Testing
import Foundation
@testable import REDDY

private final class MotionStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse())
    }
}

private let albumsJSON = """
{"results":{"albums":{"data":[
 {"id":"1","type":"albums","attributes":{"name":"Short n' Sweet (Deluxe)","artistName":"Sabrina Carpenter","url":"https://music.apple.com/us/album/short-n-sweet-deluxe/1795512297",
  "editorialVideo":{"motionDetailTall":{"video":"https://mvod.itunes.apple.com/a/tall.m3u8"},
   "motionDetailSquare":{"previewFrame":{"bgColor":"151213"},"video":"https://mvod.itunes.apple.com/a/square.m3u8"},
   "motionSquareVideo1x1":{"video":"https://mvod.itunes.apple.com/a/square2.m3u8"}}}},
 {"id":"2","type":"albums","attributes":{"name":"Today's Hits Playlist","artistName":"Apple Music","editorialVideo":{"motionDetailSquare":{"video":"https://mvod.itunes.apple.com/a/x.m3u8"}}}},
 {"id":"3","type":"albums","attributes":{"name":"Short n' Sweet","artistName":"Sabrina Carpenter","url":"https://music.apple.com/us/album/short-n-sweet/1750307020"}}
]}}}
"""

private let songsJSON = """
{"results":{"songs":{"data":[
 {"id":"s1","type":"songs","attributes":{"name":"Blinding Lights (Remix)","artistName":"The Weeknd & ROSALIA","albumName":"Blinding Lights (Remix)","url":"https://music.apple.com/us/album/blinding-lights-remix/1542842760?i=1542842761"}},
 {"id":"s2","type":"songs","attributes":{"name":"Blinding Lights","artistName":"The Weeknd","albumName":"After Hours","url":"https://music.apple.com/us/album/blinding-lights/1488408555?i=1488408568"},
  "relationships":{"albums":{"data":[{"id":"1488408555","type":"albums"}]}}}
]}}}
"""

@Suite struct MotionArtworkTests {

    // MARK: parsing

    @Test func albumReplyGivesSquareClipWithFallbackAndTall() throws {
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(albumsJSON.utf8)))
        let best = try #require(AppleMotionArtworkProvider.bestAlbum(in: obj, wanted: "Short n' Sweet", artists: ["Sabrina Carpenter"]))
        let clip = try #require(AppleMotionArtworkProvider.clip(fromAlbum: best))
        #expect(clip.masterURL.absoluteString == "https://mvod.itunes.apple.com/a/square.m3u8")
        #expect(clip.fallbackURL?.absoluteString == "https://mvod.itunes.apple.com/a/square2.m3u8")
        #expect(clip.portraitURL?.absoluteString == "https://mvod.itunes.apple.com/a/tall.m3u8")
        #expect(clip.source == "apple-motion" && clip.album == "Short n' Sweet (Deluxe)")
    }

    @Test func albumWithoutVideoAndPlainHttpGiveNothing() {
        #expect(AppleMotionArtworkProvider.clip(fromAlbum: ["attributes": ["name": "A"]]) == nil)
        let http: [String: Any] = ["attributes": ["editorialVideo": ["motionDetailSquare": ["video": "http://mvod.itunes.apple.com/a.m3u8"]]]]
        #expect(AppleMotionArtworkProvider.clip(fromAlbum: http) == nil)
        let local: [String: Any] = ["attributes": ["editorialVideo": ["motionDetailSquare": ["video": "https://192.168.1.4/a.m3u8"]]]]
        #expect(AppleMotionArtworkProvider.clip(fromAlbum: local) == nil)
    }

    @Test func songReplyGivesAlbumIDFromRelationshipOrAddress() throws {
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(songsJSON.utf8)))
        #expect(AppleMotionArtworkProvider.bestSongAlbumID(in: obj, title: "Blinding Lights", artists: ["The Weeknd"], album: nil) == "1488408555")
        #expect(AppleMotionArtworkProvider.albumID(ofSong: ["attributes": ["url": "https://music.apple.com/us/album/x/1542842760?i=1"]]) == "1542842760")
        #expect(AppleMotionArtworkProvider.albumID(ofSong: ["attributes": ["url": "https://music.apple.com/us/album/x/pl.u-123"]]) == nil)
    }

    // MARK: scoring

    @Test func scoringPrefersTheRightAlbumAndRejectsCompilations() {
        let exact = MusicMotionScoring.album(hitName: "After Hours", hitArtist: "The Weeknd", wanted: "After Hours", artists: ["The Weeknd"])
        let deluxe = MusicMotionScoring.album(hitName: "After Hours (Deluxe)", hitArtist: "The Weeknd", wanted: "After Hours", artists: ["The Weeknd"])
        #expect((exact ?? 0) > (deluxe ?? 0) && (deluxe ?? 0) >= MusicMotionScoring.minimum)
        #expect(MusicMotionScoring.album(hitName: "Today's Hits Playlist", hitArtist: "Apple Music", wanted: "Today's Hits", artists: ["x"]) == nil)
        let wrong = MusicMotionScoring.album(hitName: "Unrelated", hitArtist: "Other", wanted: "After Hours", artists: ["The Weeknd"])
        #expect((wrong ?? 0) < MusicMotionScoring.minimum)
        // A film album credited to its composer still wins by name.
        let film = MusicMotionScoring.album(hitName: "Pushpa 2 (Original Motion Picture Soundtrack) - TELUGU - EP", hitArtist: "Devi Sri Prasad", wanted: "Pushpa 2 (Original Motion Picture Soundtrack) - TELUGU - EP", artists: ["Singer One"])
        #expect((film ?? 0) >= MusicMotionScoring.minimum)
    }

    @Test func songScoringNeedsACreditedArtist() {
        #expect(MusicMotionScoring.song(hitTitle: "Blinding Lights", hitArtist: "Somebody Else", hitAlbum: nil, title: "Blinding Lights", artists: ["The Weeknd"], album: nil) == nil)
        let a = MusicMotionScoring.song(hitTitle: "Blinding Lights", hitArtist: "The Weeknd", hitAlbum: "After Hours", title: "Blinding Lights", artists: ["The Weeknd"], album: "After Hours")
        let b = MusicMotionScoring.song(hitTitle: "Blinding Lights (Remix)", hitArtist: "The Weeknd", hitAlbum: "Remixes", title: "Blinding Lights", artists: ["The Weeknd"], album: "After Hours")
        #expect((a ?? 0) > (b ?? 0))
    }

    @Test func recheckFoldsAccentsAndSplitsArtists() {
        let clip = MusicMotionClip(masterURL: URL(string: "https://x.example/a.m3u8")!, artist: "Beyoncé & Jay-Z", album: "Everything Is Love", source: "apple-motion")
        #expect(MusicMotionMatch.matches(clip, query: MusicMotionQuery(title: "t", artists: ["Beyonce"], album: "Everything Is Love")))
        #expect(!MusicMotionMatch.matches(clip, query: MusicMotionQuery(title: "t", artists: ["Someone"], album: nil)))
        #expect(!MusicMotionMatch.matches(clip, query: MusicMotionQuery(title: "t", artists: ["Beyonce"], album: "Lemonade")))
        #expect(MusicMotionMatch.matches(clip, query: MusicMotionQuery(title: "t", artists: ["Beyonce"], album: nil)))
    }

    // MARK: query

    @Test func queryReadsAppleAlbumIDOnlyFromTrustedPlaces() {
        let fromITunes = MusicTrack(id: "1", providerID: "itunes", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "A")], album: MusicAlbumRef(id: "1488408555", title: "After Hours"))
        #expect(MusicMotionQuery(track: fromITunes).catalogAlbumID == "1488408555")
        let other = MusicTrack(id: "1", providerID: "audius", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "A")], album: MusicAlbumRef(id: "12345", title: "X"))
        #expect(MusicMotionQuery(track: other).catalogAlbumID == nil)
        let linked = MusicTrack(id: "1", providerID: "spotify", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "A")], album: MusicAlbumRef(id: "z", title: "X", externalURL: "https://music.apple.com/us/album/x/987"))
        #expect(MusicMotionQuery(track: linked).catalogAlbumID == "987")
        #expect(MusicMotionQuery(title: "t", artists: [], storefront: "../x").storefront == "us" && MusicMotionQuery(title: "t", artists: [], storefront: "IN").storefront == "in")
    }

    // MARK: cache

    @Test func answerCacheKeepsSixtyFourAndDropsTheLeastRecentlyUsed() {
        var c = MusicMotionAnswerCache()
        let now = Date()
        let clip = MusicMotionClip(masterURL: URL(string: "https://x.example/a.m3u8")!, source: "t")
        for i in 0..<64 { c.store(clip, key: "k\(i)", now: now, knowsAlbum: true) }
        #expect(c.count == 64)
        #expect(c.lookup("k0", now: now, knowsAlbum: true) == .hit(clip))      // k0 is now the newest
        c.store(clip, key: "new", now: now, knowsAlbum: true)
        #expect(c.count == 64)
        #expect(c.lookup("k1", now: now, knowsAlbum: true) == .unknown)
        #expect(c.lookup("k0", now: now, knowsAlbum: true) == .hit(clip))
    }

    @Test func missesAreRememberedForSixHoursAndAlbumlessOnesRetryOnce() {
        var c = MusicMotionAnswerCache()
        let t0 = Date()
        c.store(nil, key: "a", now: t0, knowsAlbum: true)
        #expect(c.lookup("a", now: t0.addingTimeInterval(3600), knowsAlbum: true) == .miss)
        #expect(c.lookup("a", now: t0.addingTimeInterval(6 * 3600 + 1), knowsAlbum: true) == .unknown)
        c.store(nil, key: "b", now: t0, knowsAlbum: false)
        #expect(c.lookup("b", now: t0, knowsAlbum: false) == .miss)
        #expect(c.lookup("b", now: t0, knowsAlbum: true) == .unknown)           // the album arrived: ask again
        c.store(nil, key: "b", now: t0, knowsAlbum: true)
        #expect(c.lookup("b", now: t0, knowsAlbum: true) == .miss)               // and that answer is final
    }

    // MARK: playlists and URL policy

    private let master = """
    #EXTM3U
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=503700,CODECS="avc1.64001f",RESOLUTION=486x486,URI="https://mvod.itunes.apple.com/i.m3u8"
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2000000,BANDWIDTH=2400000,CODECS="avc1.64001f",RESOLUTION=768x768
    https://mvod.itunes.apple.com/v/768.m3u8
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=260000,BANDWIDTH=293000,CODECS="avc1.64001f",RESOLUTION=360x360
    https://mvod.itunes.apple.com/v/360.m3u8
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=760000,BANDWIDTH=880000,CODECS="avc1.64001f",RESOLUTION=486x486
    rel/486.m3u8
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=300000,BANDWIDTH=310000,CODECS="hvc1.2.20000000.L123.B0",RESOLUTION=486x486
    https://mvod.itunes.apple.com/v/h.m3u8
    """

    @Test func playlistPicksTheLightestSharpEnoughH264Rendition() throws {
        let base = URL(string: "https://mvod.itunes.apple.com/clip/master.m3u8")!
        let v = MusicMotionPlaylist.variants(in: master, base: base)
        #expect(v.count == 4)
        let pick = try #require(MusicMotionPlaylist.pick(v))
        #expect(pick.url.absoluteString == "https://mvod.itunes.apple.com/clip/rel/486.m3u8")
    }

    @Test func mediaPlaylistGivesTheOneFile() {
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="clip-.mp4",BYTERANGE="897@0"
        #EXTINF:4.5,
        #EXT-X-BYTERANGE:719754@897
        clip-.mp4
        #EXTINF:3.8,
        #EXT-X-BYTERANGE:539135@720651
        clip-.mp4
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://mvod.itunes.apple.com/clip/486.m3u8")!
        #expect(MusicMotionPlaylist.mediaFile(in: media, base: base)?.absoluteString == "https://mvod.itunes.apple.com/clip/clip-.mp4")
        #expect(MusicMotionPlaylist.mediaFile(in: media + "\nother.mp4", base: base) == nil)
    }

    @Test func loaderRefusesPlainHttpAndPrivateAddressesAndBigFiles() async throws {
        let loader = MusicMotionClipLoader(fetch: { _, _ in Data(repeating: 1, count: 10) })
        for bad in ["http://mvod.itunes.apple.com/a.mp4", "https://192.168.1.2/a.mp4", "https://localhost/a.mp4", "https://nas.local/a.mp4", "file:///etc/passwd"] {
            await #expect(throws: MusicError.self) { _ = try await loader.data(for: URL(string: bad)!) }
        }
        let ok = try await loader.data(for: URL(string: "https://mvod.itunes.apple.com/a.mp4")!)
        #expect(ok.count == 10)
        let big = MusicMotionClipLoader(fetch: { _, _ in Data(count: MusicMotionClipCache.maxClipBytes + 1) })
        await #expect(throws: MusicError.self) { _ = try await big.data(for: URL(string: "https://mvod.itunes.apple.com/a.mp4")!) }
        // A private address named inside a playlist is refused too.
        let evil = MusicMotionClipLoader(fetch: { url, _ in
            url.pathExtension == "m3u8" ? Data("#EXTM3U\nhttps://10.0.0.5/x.mp4\n".utf8) : Data(count: 5)
        })
        await #expect(throws: MusicError.self) { _ = try await evil.data(for: URL(string: "https://mvod.itunes.apple.com/a.m3u8")!) }
    }

    // MARK: disk cache

    @Test func diskCacheTrimsOldestFirstAndRefusesOversizeClips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motion-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MusicMotionClipCache(folder: folder, limit: 2500)
        let t = Date()
        #expect(cache.store(Data(count: 1000), forKey: "a", now: t.addingTimeInterval(-300)) != nil)
        #expect(cache.store(Data(count: 1000), forKey: "b", now: t.addingTimeInterval(-200)) != nil)
        _ = cache.existing(forKey: "a", now: t.addingTimeInterval(-100))        // a is newer than b now
        #expect(cache.store(Data(count: 1000), forKey: "c", now: t) != nil)
        #expect(cache.existing(forKey: "b") == nil)
        #expect(cache.existing(forKey: "a") != nil && cache.existing(forKey: "c") != nil)
        #expect(cache.store(Data(count: MusicMotionClipCache.maxClipBytes + 1), forKey: "big") == nil)
        #expect((try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true)
        #expect(MusicMotionClipCache.limitBytes == 150 * 1024 * 1024)
    }

    @Test func victimsRemoveLeastRecentlyUsedUntilItFits() {
        let d = Date()
        let items = [("a", 5, 0.0), ("b", 5, 1.0), ("c", 5, 2.0)].map { MusicMotionClipCache.Item(url: URL(fileURLWithPath: "/\($0.0)"), size: $0.1, used: d.addingTimeInterval($0.2)) }
        #expect(MusicMotionClipCache.victims(items, limit: 10).map(\.url.lastPathComponent) == ["a"])
        #expect(MusicMotionClipCache.victims(items, limit: 4).count == 3)
        #expect(MusicMotionClipCache.victims(items, limit: 15).isEmpty)
    }

    // MARK: service

    private struct FakeProvider: MusicMotionArtworkProvider {
        let counter: MotionCounter
        let result: MusicMotionClip?
        var info: MusicProviderInfo { MusicProviderInfo(id: "fake", name: "Fake", summary: "") }
        func clip(for query: MusicMotionQuery) async throws -> MusicMotionClip? { counter.bump(); return result }
    }
    private final class MotionCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func serviceFetchesNothingWhenOffAndRemembersMisses() async {
        let counter = MotionCounter()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motion-svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let on = MotionFlag()
        let svc = MusicMotionArtworkService(providers: [FakeProvider(counter: counter, result: nil)], clips: MusicMotionClipCache(folder: folder),
                                            loader: MusicMotionClipLoader(fetch: { _, _ in Data() }), allowed: { on.value })
        let q = MusicMotionQuery(title: "T", artists: ["A"], album: "Al")
        #expect(await svc.clip(for: q) == nil)
        #expect(counter.value == 0)
        on.value = true
        #expect(await svc.clip(for: q) == nil)
        #expect(await svc.clip(for: q) == nil)
        #expect(counter.value == 1)
    }

    @Test func serviceDownloadsOnceAndReusesTheFile() async {
        let counter = MotionCounter()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motion-svc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = MusicMotionClip(masterURL: URL(string: "https://mvod.itunes.apple.com/clip.mp4")!, artist: "A", album: "Al", source: "fake")
        let fetches = MotionCounter()
        let svc = MusicMotionArtworkService(providers: [FakeProvider(counter: counter, result: clip)], clips: MusicMotionClipCache(folder: folder),
                                            loader: MusicMotionClipLoader(fetch: { _, _ in fetches.bump(); return Data(count: 64) }), allowed: { true })
        let q = MusicMotionQuery(title: "T", artists: ["A"], album: "Al")
        let a = await svc.file(for: q), b = await svc.file(for: q)
        #expect(a != nil && a == b)
        #expect(fetches.value == 1 && counter.value == 1)
        // A clip that belongs to another album is not used.
        let wrong = MusicMotionQuery(title: "T", artists: ["A"], album: "Different")
        #expect(await svc.clip(for: wrong) == nil)
    }

    private final class MotionFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    @Test func providerSendsTheTokenAndStopsAtNothingFound() async throws {
        let stub = MotionStub { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/search") { return (200, albumsJSON) }
            return (404, "")
        }
        let p = AppleMotionArtworkProvider(http: MusicHTTP(transport: stub), token: { _, _ in "tok" }, resetToken: {})
        let clip = try await p.clip(for: MusicMotionQuery(title: "Espresso", artists: ["Sabrina Carpenter"], album: "Short n' Sweet", storefront: "us"))
        #expect(clip?.masterURL.lastPathComponent == "square.m3u8")
        let req = try #require(stub.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.url?.host == "amp-api.music.apple.com" && req.url?.query?.contains("extend=editorialVideo") == true)
    }

    // MARK: view rules

    @Test func playbackRulesFollowPlayScreenAndMotionSettings() {
        typealias R = MusicMotionPlaybackRules
        #expect(R.shouldPlay(isPlaying: true, onScreen: true, appActive: true, reduceMotion: false))
        #expect(!R.shouldPlay(isPlaying: false, onScreen: true, appActive: true, reduceMotion: false))
        #expect(!R.shouldPlay(isPlaying: true, onScreen: false, appActive: true, reduceMotion: false))
        #expect(!R.shouldPlay(isPlaying: true, onScreen: true, appActive: false, reduceMotion: false))
        #expect(!R.shouldPlay(isPlaying: true, onScreen: true, appActive: true, reduceMotion: true))
        #expect(!R.shouldFetch(enabled: false, isPlaying: true, onScreen: true, reduceMotion: false))
        #expect(!R.shouldFetch(enabled: true, isPlaying: false, onScreen: true, reduceMotion: false))
        #expect(R.shouldFetch(enabled: true, isPlaying: true, onScreen: true, reduceMotion: false))
        #expect(R.coverDrifts(setting: true, shouldPlay: true, clipShowing: false))
        #expect(!R.coverDrifts(setting: true, shouldPlay: true, clipShowing: true) && !R.coverDrifts(setting: false, shouldPlay: true, clipShowing: false))
    }

    @Test func driftStartsAtRestAndStaysGentle() {
        #expect(MusicCoverDriftMath.zoom(at: 0) == 1 && MusicCoverDriftMath.offset(at: 0).x == 0 && MusicCoverDriftMath.offset(at: 0).y == 0)
        for t in stride(from: 0.0, to: 120.0, by: 1.7) {
            #expect(MusicCoverDriftMath.zoom(at: t) >= 1 && MusicCoverDriftMath.zoom(at: t) <= 1.0701)
            #expect(abs(MusicCoverDriftMath.offset(at: t).x) <= 0.0121)
        }
    }

    @Test func prefsAreOffByDefaultAndMeteredNeedsItsOwnYes() {
        let d = UserDefaults(suiteName: "motion-prefs-\(UUID().uuidString)")!
        #expect(!MusicMotionPrefs.isOn(d) && !MusicMotionPrefs.overCellular(d))   // off until the person switches it on, as the setting says
        #expect(MusicMotionPrefs.mayFetch(enabled: true, metered: false, cellularAllowed: false))
        #expect(!MusicMotionPrefs.mayFetch(enabled: true, metered: true, cellularAllowed: false))
        #expect(MusicMotionPrefs.mayFetch(enabled: true, metered: true, cellularAllowed: true))
        #expect(!MusicMotionPrefs.mayFetch(enabled: false, metered: false, cellularAllowed: true))
        #expect(MusicDefaultsKeys.deviceSettings.isSuperset(of: [MusicMotionPrefs.motionKey, MusicMotionPrefs.cellularKey, MusicMotionPrefs.coverMotionKey]))
    }
}
