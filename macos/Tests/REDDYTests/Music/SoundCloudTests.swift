import Testing
import Foundation
@testable import REDDY

private final class SCStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [String] { lock.withLock { urls } }
    func count(containing s: String) -> Int { requests.filter { $0.contains(s) }.count }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { urls.append(request.url?.absoluteString ?? "") }
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse())
    }
}

private final class SCClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    func read() -> Date { lock.withLock { now } }
    func advance(_ s: TimeInterval) { lock.withLock { now = now.addingTimeInterval(s) } }
}

private func url(_ r: URLRequest) -> String { r.url?.absoluteString ?? "" }

/// A site that serves the home page, one script with the key, and whatever `api` answers for api-v2 addresses.
private func site(api: @escaping @Sendable (URLRequest) -> (Int, String)) -> SCStub {
    SCStub { r in
        let u = url(r)
        if u.hasPrefix("https://soundcloud.com") { return (200, SoundCloudFixtures.homePage) }
        if u.contains("a-v2.sndcdn.com/assets/1-bbb.js") { return (200, SoundCloudFixtures.bundleWithKey) }
        if u.contains("a-v2.sndcdn.com") { return (200, SoundCloudFixtures.bundleWithoutKey) }
        return api(r)
    }
}

private func makeClient(_ stub: SCStub, clock: SCClock = SCClock()) -> (SoundCloudClient, SoundCloudHealth) {
    let http = MusicHTTP(transport: stub)
    let health = SoundCloudHealth(clock: { clock.read() })
    let defaults = UserDefaults(suiteName: "sc-test-" + UUID().uuidString)!
    let ids = SoundCloudClientID(http: http, health: health, defaults: defaults, clock: { clock.read() })
    return (SoundCloudClient(http: http, health: health, ids: ids), health)
}

private func scTrack(_ json: String) -> SCTrack { SoundCloudJSON.track(SoundCloudJSON.object(Data(json.utf8)))! }

@Suite struct SoundCloudTests {

    // MARK: mapping

    @Test func searchRowsMapToTracksWithArtwork() throws {
        let obj = SoundCloudJSON.any(Data(SoundCloudFixtures.search().utf8))
        let rows = SoundCloudJSON.rows(obj)
        let tracks = rows.compactMap { SoundCloudJSON.track($0) }.compactMap(SoundCloudMapping.track)
        #expect(tracks.count == 2)   // the user row inside the list is not a track
        let t = try #require(tracks.first)
        #expect(t.uid == "soundcloud:1001")
        #expect(t.durationMs == 245_000)
        #expect(t.artists.first?.name == "Nova FM")
        #expect(t.externalURL == "https://soundcloud.com/nova-fm/night-drive")
        #expect(t.thumbnails.last?.url == "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")
        #expect(t.directStreams == nil)
        #expect(SoundCloudJSON.nextHref(obj)?.contains("offset=2") == true)
    }

    @Test func artworkUpgradeKeepsOtherAddresses() {
        #expect(SoundCloudMapping.upgraded("https://i1.sndcdn.com/a-large.png") == "https://i1.sndcdn.com/a-t500x500.png")
        #expect(SoundCloudMapping.upgraded("https://i1.sndcdn.com/a-t120x120.jpg") == "https://i1.sndcdn.com/a-t500x500.jpg")
        #expect(SoundCloudMapping.upgraded("https://example.com/cover.jpg") == "https://example.com/cover.jpg")
        #expect(SoundCloudMapping.upgraded(nil) == nil)
    }

    @Test func labelUploadCreditsTheNamedArtist() throws {
        let t = try #require(SoundCloudMapping.track(scTrack(SoundCloudFixtures.labelUpload)))
        #expect(t.artists.first?.name == "Luna Park")
    }

    @Test func unknownShapesNeverCrash() {
        #expect(SoundCloudJSON.track(["id": 5, "media": "nonsense", "user": 7]) != nil)
        #expect(SoundCloudJSON.track(["title": "no id"]) == nil)
        #expect(SoundCloudJSON.playlist(["id": 1]) == nil)
        #expect(SoundCloudJSON.rows("text").isEmpty)
        #expect(SoundCloudJSON.resolved(["kind": "station"]) == nil)
    }

    @Test func playlistStubsAreRecognised() throws {
        let p = try #require(SoundCloudJSON.playlist(SoundCloudJSON.object(Data(SoundCloudFixtures.playlist.utf8))))
        #expect(p.tracks.count == 3)
        #expect(p.tracks.filter(\.isStub).count == 2)
        #expect(!p.isAlbum)
        let a = try #require(SoundCloudJSON.playlist(SoundCloudJSON.object(Data(SoundCloudFixtures.album.utf8))))
        #expect(a.isAlbum)
        #expect(SoundCloudMapping.album(a).releaseDate == "2024-03-01")
    }

    @Test func savedTrackCarriesNoStreamAddress() throws {
        let t = try #require(SoundCloudMapping.track(scTrack(SoundCloudFixtures.plainTrack)))
        let json = String(data: try JSONEncoder().encode(t), encoding: .utf8) ?? ""
        #expect(!json.contains("m3u8"))
        #expect(!json.contains("/stream/"))
    }

    // MARK: transcodings

    @Test func pickerPrefersProgressiveThenHLSAAC() {
        let t = scTrack(SoundCloudFixtures.plainTrack)
        let order = SoundCloudStreams.candidates(from: t.transcodings).map(\.preset)
        #expect(order == ["mp3_0_0", "aac_160k", "aac_96k"])   // the adaptive master playlist is left out
        #expect(SoundCloudStreams.candidates(from: t.transcodings).first?.proto == "progressive")
    }

    @Test func hlsOnlyTrackUsesHLS() {
        let t = scTrack(SoundCloudFixtures.hlsOnlyTrack)
        let c = SoundCloudStreams.candidates(from: t.transcodings)
        #expect(c.count == 1 && c[0].proto == "hls")
        let s = SoundCloudStreams.stream(address: "https://cdn.example/a.m3u8", from: c[0], now: Date(timeIntervalSince1970: 1000))
        #expect(s.proto == .hls && s.codec == "aac" && s.container == "m3u8" && s.bitrate == 160)
        #expect(s.expiresAt == Date(timeIntervalSince1970: 1600))
    }

    @Test func addressExpiryNeverExceedsTheAddressOwnExpiry() {
        let t = scTrack(SoundCloudFixtures.hlsOnlyTrack).transcodings[0]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = SoundCloudStreams.stream(address: "https://cdn.example/a.m3u8?expires=1800000100", from: t, now: now)
        #expect(s.expiresAt == Date(timeIntervalSince1970: 1_800_000_100))
    }

    @Test func encryptedVariantMakesTheWholeTrackProtected() {
        let t = scTrack(SoundCloudFixtures.encryptedTrack)
        #expect(SoundCloudStreams.candidates(from: t.transcodings).isEmpty)
        #expect(SoundCloudAvailability.of(t) == .unavailable(.protected))
        let ctr = SCTranscoding(url: "u", preset: "aac_160k", proto: "ctr-encrypted-hls", mime: "audio/mp4")
        let cbc = SCTranscoding(url: "u", preset: "aac_160k", proto: "cbc-hls", mime: "audio/mp4")
        #expect(SoundCloudStreams.isEncrypted(ctr) && SoundCloudStreams.isEncrypted(cbc))
    }

    @Test func previewBlockedAndPrivateAreFlagged() {
        #expect(SoundCloudAvailability.of(scTrack(SoundCloudFixtures.snippedTrack)) == .unavailable(.preview))
        #expect(SoundCloudAvailability.of(scTrack(SoundCloudFixtures.blockedTrack)) == .unavailable(.blocked))
        #expect(SoundCloudAvailability.of(scTrack(SoundCloudFixtures.notStreamableTrack)) == .unavailable(.notStreamable))
        #expect(SoundCloudAvailability.of(scTrack(SoundCloudFixtures.plainTrack)).isPlayable)
        #expect(SoundCloudStreams.isPreviewURL("https://cf.sndcdn.com/preview/0/30/x.m3u8"))
        #expect(!SoundCloudStreams.isPreviewURL("https://cf.sndcdn.com/playlist/x.m3u8"))
    }

    @Test func aBareIdIsJudgedAfterItIsFetched() {
        let stub = SCTrack(id: "9")
        #expect(stub.isStub)
        #expect(SoundCloudAvailability.of(stub).isPlayable)
    }

    // MARK: client key

    @Test func keyIsFoundInTheBundleAndNotInOthers() {
        #expect(SoundCloudSiteKey.extract(from: SoundCloudFixtures.bundleWithKey) == SoundCloudFixtures.fakeKey)
        #expect(SoundCloudSiteKey.extract(from: "x client_id = '\(SoundCloudFixtures.fakeKey)' y") == SoundCloudFixtures.fakeKey)
        #expect(SoundCloudSiteKey.extract(from: SoundCloudFixtures.bundleWithoutKey) == nil)
        #expect(SoundCloudSiteKey.extract(from: "") == nil)
        let scripts = SoundCloudSiteKey.scriptURLs(in: SoundCloudFixtures.homePage)
        #expect(scripts.map(\.lastPathComponent) == ["0-aaa.js", "1-bbb.js"])
    }

    @Test func concurrentCallersShareOneScrape() async throws {
        let stub = site { _ in (200, "{}") }
        let ids = SoundCloudClientID(http: MusicHTTP(transport: stub), health: SoundCloudHealth(), defaults: UserDefaults(suiteName: "sc-" + UUID().uuidString)!)
        async let a = ids.current()
        async let b = ids.current()
        async let c = ids.current()
        let keys = try await [a, b, c]
        #expect(Set(keys) == [SoundCloudFixtures.fakeKey])
        #expect(stub.count(containing: "https://soundcloud.com") == 1)
        _ = try await ids.current()
        #expect(stub.count(containing: "https://soundcloud.com") == 1)   // kept
    }

    @Test func keySurvivesInPreferencesWithinItsLifetimeOnly() async throws {
        let stub = site { _ in (200, "{}") }
        let clock = SCClock()
        let suite = "sc-" + UUID().uuidString
        func make() -> SoundCloudClientID {
            SoundCloudClientID(http: MusicHTTP(transport: stub), health: SoundCloudHealth(), defaults: UserDefaults(suiteName: suite)!, clock: { clock.read() })
        }
        _ = try await make().current()
        _ = try await make().current()   // a new run reads it from preferences
        #expect(stub.count(containing: "https://soundcloud.com") == 1)
        clock.advance(SoundCloudClientID.ttl + 1)
        _ = try await make().current()
        #expect(stub.count(containing: "https://soundcloud.com") == 2)
    }

    @Test func refusedCallRenewsTheKeyOnceAndTriesAgain() async throws {
        let calls = SCCounter()
        let stub = site { _ in calls.next() == 1 ? (401, "{}") : (200, "{\"ok\":true}") }
        let (client, _) = makeClient(stub)
        let d = try await client.data(path: "tracks/1")
        #expect(String(data: d, encoding: .utf8)?.contains("ok") == true)
        #expect(stub.count(containing: "https://soundcloud.com") == 2)
    }

    @Test func theKeyIsOnlySentToTheApiHost() async {
        let stub = site { _ in (200, "{}") }
        let (client, _) = makeClient(stub)
        await #expect(throws: MusicError.self) { _ = try await client.data(url: URL(string: "https://evil.example/x")!) }
        #expect(stub.requests.isEmpty)
        #expect(!SoundCloudClient.isTrusted(URL(string: "http://api-v2.soundcloud.com/x")!))
    }

    // MARK: cooldown

    @Test func cooldownLadderRestsAfterRepeatedFailures() {
        var c = SoundCloudCooldown()
        let t0 = Date(timeIntervalSince1970: 0)
        let first = c.recordFailure(now: t0)
        #expect(first == nil && !c.isCooling(now: t0))
        let second = c.recordFailure(now: t0)
        #expect(second == 120 && c.isCooling(now: t0.addingTimeInterval(119)))
        #expect(!c.isCooling(now: t0.addingTimeInterval(121)))
        let third = c.recordFailure(now: t0), fourth = c.recordFailure(now: t0), fifth = c.recordFailure(now: t0)
        #expect(third == 600 && fourth == 3600 && fifth == 3600)
        c.recordSuccess()
        #expect(c.failures == 0 && !c.isCooling(now: t0))
    }

    @Test func aRestingProviderMakesNoRequests() async {
        let stub = site { _ in (500, "{}") }
        let clock = SCClock()
        let (client, health) = makeClient(stub, clock: clock)
        await health.failure("test")
        await health.failure("test")
        let resting = await health.isCooling
        #expect(resting)
        let before = stub.requests.count
        await #expect(throws: MusicError.self) { _ = try await client.data(path: "tracks/1") }
        #expect(stub.requests.count == before)
        clock.advance(121)
        let rested = await health.isCooling
        #expect(!rested)
    }

    // MARK: provider

    @Test func searchLeavesOutTracksThatCannotBePlayed() async throws {
        let stub = site { r in
            if url(r).contains("search/tracks") { return (200, "{\"collection\":[\(SoundCloudFixtures.plainTrack),\(SoundCloudFixtures.encryptedTrack),\(SoundCloudFixtures.snippedTrack),\(SoundCloudFixtures.blockedTrack)]}") }
            return (404, "{}")
        }
        let (client, _) = makeClient(stub)
        let p = SoundCloudProvider(client: client, extras: SoundCloudExtras(client: client))
        let page = try await p.searchTracks("drive", page: nil)
        #expect(page.items.map(\.id) == ["1001"])
        #expect(SoundCloudAvailabilityBook.shared.reason(forTrackID: "1003") == .protected)
        #expect(SoundCloudAvailabilityBook.shared.reason(forTrackID: "1004") == .preview)
    }

    @Test func streamsComeBackInPreferenceOrderWithExpiry() async throws {
        let stub = site { r in
            let u = url(r)
            if u.contains("/tracks/1001") { return (200, SoundCloudFixtures.plainTrack) }
            if u.contains("/media/") { return (200, SoundCloudFixtures.streamReply) }
            return (404, "{}")
        }
        let (client, _) = makeClient(stub)
        let p = SoundCloudProvider(client: client, extras: SoundCloudExtras(client: client))
        let streams = try await p.resolveStreams(trackID: "1001", title: "Night Drive")
        #expect(streams.map(\.proto) == [.progressive, .hls])
        #expect(streams.allSatisfy { $0.expiresAt != nil })
        #expect(stub.requests.contains { $0.contains("track_authorization=auth-1") })
    }

    @Test func protectedAndPreviewTracksThrowCalmlyWithoutAskingForAudio() async {
        let stub = site { r in
            let u = url(r)
            if u.contains("/tracks/1003") { return (200, SoundCloudFixtures.encryptedTrack) }
            if u.contains("/tracks/1004") { return (200, SoundCloudFixtures.snippedTrack) }
            return (404, "{}")
        }
        let (client, _) = makeClient(stub)
        let p = SoundCloudProvider(client: client, extras: SoundCloudExtras(client: client))
        await #expect(throws: MusicError.self) { _ = try await p.resolveStreams(trackID: "1003", title: "Label Hit") }
        await #expect(throws: MusicError.self) { _ = try await p.resolveStreams(trackID: "1004", title: "Teaser") }
        #expect(stub.count(containing: "/media/") == 0)
    }

    @Test func aPreviewAddressIsRejectedAfterResolving() async {
        let stub = site { r in
            let u = url(r)
            if u.contains("/tracks/1001") { return (200, SoundCloudFixtures.plainTrack) }
            if u.contains("/media/") { return (200, SoundCloudFixtures.previewReply) }
            return (404, "{}")
        }
        let (client, _) = makeClient(stub)
        let p = SoundCloudProvider(client: client, extras: SoundCloudExtras(client: client))
        await #expect(throws: MusicError.self) { _ = try await p.resolveStreams(trackID: "1001", title: "Night Drive") }
    }

    @Test func otherSourcesSongsAreNeverClaimedByTheMatcher() async throws {
        let p = SoundCloudProvider(client: makeClient(site { _ in (404, "{}") }).0)
        let foreign = MusicTrack(id: "x", providerID: "ytmusic", title: "Night Drive", durationMs: 245_000, artists: [MusicArtistRef(id: "", name: "Nova FM")])
        #expect(try await p.sources(for: foreign).isEmpty)
        let own = MusicTrack(id: "1001", providerID: "soundcloud", title: "Night Drive", durationMs: 245_000, artists: [])
        #expect(try await p.sources(for: own).first?.id == "1001")
    }

    @Test func alternativesOfferTheSameVersionOnly() async throws {
        let remix = SoundCloudFixtures.plainTrack.replacingOccurrences(of: "Night Drive (Original Mix)", with: "Night Drive (Club Remix)").replacingOccurrences(of: "1001", with: "1100")
        let stub = site { r in
            url(r).contains("search/tracks") ? (200, "{\"collection\":[\(SoundCloudFixtures.plainTrack),\(remix)]}") : (404, "{}")
        }
        let (client, _) = makeClient(stub)
        let p = SoundCloudProvider(client: client, extras: SoundCloudExtras(client: client))
        let want = MusicTrack(id: "y", providerID: "ytmusic", title: "Night Drive", durationMs: 244_000, artists: [MusicArtistRef(id: "", name: "Nova FM")])
        let found = try await p.alternatives(for: want)
        #expect(found.map(\.id) == ["1001"])
        #expect(found.first?.streams == nil)
    }

    @Test func pastedShortLinkOpensThePageItNames() async {
        let stub = site { _ in (200, SoundCloudFixtures.shortPage) }
        let (client, _) = makeClient(stub)
        let short = SoundCloudLink.target(for: URL(string: "https://on.soundcloud.com/AbC123")!)
        #expect(short?.id == "s~AbC123")
        let t = await SoundCloudLink.expanded(short!, client: client)
        #expect(t.kind == .track && t.id == "r~nova-fm~night-drive")
    }

    // MARK: links

    @Test func linkShapes() {
        func parse(_ s: String) -> SoundCloudLink.Parsed? { SoundCloudLink.parse(text: s) }
        func P(_ k: SoundCloudLink.Kind, _ path: String) -> SoundCloudLink.Parsed? { SoundCloudLink.Parsed(kind: k, path: path) }
        #expect(parse("https://soundcloud.com/nova-fm/night-drive") == P(.track, "nova-fm/night-drive"))
        #expect(parse("soundcloud.com/nova-fm/night-drive/") == P(.track, "nova-fm/night-drive"))
        #expect(parse("https://m.soundcloud.com/nova-fm/night-drive?in=nova-fm/sets/late-set&utm_source=x") == P(.track, "nova-fm/night-drive"))
        #expect(parse("https://soundcloud.com/nova-fm/sets/late-set") == P(.set, "nova-fm/sets/late-set"))
        #expect(parse("https://soundcloud.com/nova-fm") == P(.user, "nova-fm"))
        #expect(parse("https://soundcloud.com/nova-fm/tracks") == P(.user, "nova-fm"))
        #expect(parse("https://soundcloud.com/nova-fm/night-drive/s-AbCdE") == P(.track, "nova-fm/night-drive/s-AbCdE"))
        #expect(parse("https://on.soundcloud.com/AbC123") == P(.short, "AbC123"))
        #expect(parse("https://soundcloud.com/discover") == nil)
        #expect(parse("https://soundcloud.com/") == nil)
        #expect(parse("https://example.com/nova-fm/night-drive") == nil)
        #expect(parse("https://notsoundcloud.com/a/b") == nil)
    }

    @Test func linkTargetsAreValidAndRoundTrip() {
        let t = SoundCloudLink.target(for: URL(string: "https://soundcloud.com/nova-fm/sets/late-set")!)
        #expect(t?.kind == .playlist && t?.providerID == "soundcloud" && t?.id == "r~nova-fm~sets~late-set")
        #expect(MusicDeepLinks.parse(URL(string: "https://soundcloud.com/nova-fm")!)?.kind == .artist)
        #expect(SoundCloudLink.url(forToken: "r~nova-fm~night-drive")?.absoluteString == "https://soundcloud.com/nova-fm/night-drive")
        #expect(SoundCloudLink.url(forToken: "123") == nil)
        #expect(SoundCloudLink.url(forToken: "r~a b") == nil)
    }

    // MARK: chapters

    @Test func chaptersReadSeveralFormats() {
        let c = SoundCloudChapters.parse(description: SoundCloudFixtures.description)
        #expect(c.map(\.startSeconds) == [0, 225, 754, 3723])
        #expect(c[1].title == "Artist One - First Song")
        #expect(c[2].title == "Ünïcödé 夜の街")
        #expect(c[3].title == "Last One")
    }

    @Test func chaptersNeedThreeAndMustMoveForward() {
        #expect(SoundCloudChapters.parse(description: "00:00 One\n05:00 Two").isEmpty)
        #expect(SoundCloudChapters.parse(description: "Meet at 10:30 sharp").isEmpty)
        let c = SoundCloudChapters.parse(description: "00:00 A\n10:00 B\n05:00 out of order\n20:00 C\n99:00 beyond", duration: 3600)
        #expect(c.map(\.title) == ["A", "B", "C"])
        let trailing = SoundCloudChapters.parse(description: "Intro 00:00\nMiddle (30:10)\nEnd - 1:00:00")
        #expect(trailing.map(\.startSeconds) == [0, 1810, 3600])
    }

    @Test func chaptersFromTimedComments() {
        let comments = [SCComment(id: "1", body: "Second", timestampMs: 600_000, userID: "7"), SCComment(id: "2", body: "First", timestampMs: 5_000, userID: "7"),
                        SCComment(id: "3", body: "Third\nsecond line", timestampMs: 1_200_000, userID: "7"), SCComment(id: "4", body: "no time", timestampMs: nil, userID: "7")]
        let c = SoundCloudChapters.parse(comments: comments)
        #expect(c.map(\.title) == ["First", "Second", "Third"])
        #expect(SoundCloudChapters.index(at: 700, in: c) == 1)
    }

    // MARK: matching

    @Test func remixesNeverMatchStudioRecordings() {
        func t(_ title: String, _ provider: String = "soundcloud", isrc: String? = nil, ms: Int64 = 200_000) -> MusicTrack {
            MusicTrack(id: "1", providerID: provider, title: title, durationMs: ms, artists: [MusicArtistRef(id: "", name: "Luna Park")], isrc: isrc)
        }
        let studio = t("Moonlight", "ytmusic")
        #expect(SoundCloudMatch.isSameRecording(t("Moonlight"), studio))
        #expect(SoundCloudMatch.isSameRecording(t("Moonlight (Original Mix)"), studio))
        for v in ["Moonlight (DJ Sam Remix)", "Moonlight (Bootleg)", "Moonlight - Slowed + Reverb", "Moonlight (Live)", "Moonlight (Club Edit)", "Moonlight [Mashup]"] {
            #expect(!SoundCloudMatch.isSameRecording(t(v), studio), "\(v)")
            #expect(SoundCloudMatch.alternativeScore(want: studio, got: t(v)) == 0, "\(v)")
        }
        #expect(!SoundCloudMatch.isSameRecording(t("Moonlight", ms: 260_000), studio))        // length differs
        #expect(!SoundCloudMatch.isSameRecording(t("Moonlight Sonata"), studio))              // different title
        var other = t("Moonlight", "ytmusic"); other.artists = [MusicArtistRef(id: "", name: "Someone Else")]
        #expect(!SoundCloudMatch.isSameRecording(t("Moonlight"), other))
        #expect(!SoundCloudMatch.mayMergeInGraph(t("Moonlight"), studio))                      // no ISRC: never merged
        #expect(SoundCloudMatch.mayMergeInGraph(t("Moonlight", isrc: "xx1"), t("Moonlight", "ytmusic", isrc: "XX1")))
        #expect(!SoundCloudMatch.mayMergeInGraph(t("Moonlight (Remix)", isrc: "XX1"), t("Moonlight", "ytmusic", isrc: "XX1")))
        #expect(SoundCloudMatch.externalID(for: t("Moonlight")).description == "provider:soundcloud:1")
    }

    @Test func artistShelfNeedsAConfidentProfile() {
        func u(_ id: String, _ name: String, _ f: Int, verified: Bool = false) -> SCUser { SCUser(id: id, username: name, followers: f, verified: verified) }
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Park", 50_000)])?.id == "1")
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Park", 40)]) == nil)
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Park", 40, verified: true)])?.id == "1")
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Parks", 90_000)]) == nil)
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Park", 9_000), u("2", "luna park", 8_000)]) == nil)
        #expect(SoundCloudMatch.confidentUser(named: "Luna Park", among: [u("1", "Luna Park", 90_000), u("2", "luna park", 8_000)])?.id == "1")
    }

    // MARK: autoplay, discovery, waveform

    @Test func relatedPicksAreDedupedAndCapped() throws {
        let list = SoundCloudJSON.rows(SoundCloudJSON.any(Data(SoundCloudFixtures.relatedList.utf8))).compactMap { SoundCloudJSON.track($0) }
        let tracks = list.compactMap(SoundCloudMapping.track)
        let picked = SoundCloudRelated.select(tracks, excluding: ["soundcloud:1002"], room: 10)
        #expect(picked.map(\.id) == ["1001", "1003", "1004"])   // repeat and the seed itself are gone
        #expect(SoundCloudRelated.select(tracks, excluding: [], room: 1).count == 1)
        #expect(SoundCloudRelated.select(tracks, excluding: [], room: 0).isEmpty)
        let budget = SoundCloudRelatedBudget()
        #expect(budget.room(for: "s", cap: 5) == 5)
        budget.spend(4, seed: "s")
        #expect(budget.room(for: "s", cap: 5) == 1)
        budget.spend(4, seed: "s")
        #expect(budget.room(for: "s", cap: 5) == 0)
    }

    @Test func discoveryDerivesGenresFromTheSongsItself() throws {
        let rows = "{\"collection\":[{\"track\":\(SoundCloudFixtures.plainTrack)},{\"track\":\(SoundCloudFixtures.hlsOnlyTrack.replacingOccurrences(of: "\"streamable\"", with: "\"genre\":\"Electronic\",\"streamable\""))},{\"track\":\(SoundCloudFixtures.labelUpload.replacingOccurrences(of: "\"streamable\"", with: "\"genre\":\"Drum & Bass\",\"streamable\""))}]}"
        let tracks = SoundCloudDiscoveryProvider.chartTracks(SoundCloudJSON.any(Data(rows.utf8)))
        #expect(tracks.count == 3)
        #expect(SoundCloudDiscoveryProvider.topGenres(tracks, limit: 2) == ["Electronic", "Drum & Bass"])
        #expect(SoundCloudDiscoveryProvider.genreSlug("Drum & Bass") == "drumandbass")
        #expect(SoundCloudDiscoveryProvider.chartTracks("garbage").isEmpty)
    }

    @Test func waveformSamplesScaleAndShrink() {
        let s = SoundCloudWaveform.samples(from: Data(SoundCloudFixtures.waveform.utf8))
        #expect(s.count == 12 && s.max() == 1 && s.min() == 0)
        #expect(SoundCloudWaveform.samples(from: Data("{}".utf8)).isEmpty)
        #expect(SoundCloudWaveform.bars(s, count: 4).count == 4)
        #expect(SoundCloudWaveform.bars(s, count: 100).count == 12)
        #expect(SoundCloudWaveform.isTrusted(URL(string: "https://wave.sndcdn.com/a.json")!))
        #expect(!SoundCloudWaveform.isTrusted(URL(string: "https://evil.example/a.json")!))
    }
}

private final class SCCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
