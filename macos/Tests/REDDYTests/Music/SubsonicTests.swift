import Testing
import Foundation
@testable import REDDY

private final class SubsonicStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    private let route: @Sendable (URL) -> (Int, String)
    init(_ route: @escaping @Sendable (URL) -> (Int, String)) { self.route = route }
    var requests: [URL] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw MusicError.network("stub") }
        lock.withLock { seen.append(url) }
        let (status, body) = route(url)
        guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private func items(_ url: URL) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[i.name, default: []].append(i.value ?? "") }
    return out
}

private func reply(_ inner: String) -> String {
    #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.55.0","openSubsonic":true"# + (inner.isEmpty ? "" : "," + inner) + "}}"
}
private func failure(_ code: Int) -> String {
    #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":"# + String(code) + #","message":"nope"}}}"#
}

private let songJSON = #"{"id":"so1","title":"Blue","album":"Skies","albumId":"al1","artist":"Ann","artistId":"ar1","track":3,"discNumber":1,"duration":215,"coverArt":"mf-so1","year":2020,"suffix":"flac","contentType":"audio/flac","bitRate":900,"samplingRate":44100,"starred":"2024-01-01T00:00:00Z","isrc":["USAAA2000001"],"explicitStatus":"explicit","replayGain":{"trackGain":-6.5,"albumGain":-7.2}}"#
private let mp3JSON = #"{"id":"so2","title":"Green","album":"Skies","albumId":"al1","artist":"Ann","artistId":"ar1","duration":180,"suffix":"mp3","contentType":"audio/mpeg","bitRate":256}"#

private let server = SubsonicServer(id: "s1", address: "https://music.example.org", username: "ann", salt: "c19b2d", ownNetwork: false)

private func provider(_ stub: SubsonicStub, servers: [SubsonicServer] = [server], transcode: SubsonicTranscode = SubsonicTranscode()) -> SubsonicProvider {
    SubsonicProvider(http: MusicHTTP(transport: stub), servers: { servers }, password: { _ in "sesame" }, transcode: { transcode })
}

private func session(base: String = "https://music.example.org") -> SubsonicSession {
    SubsonicSession(serverID: "s1", base: URL(string: base)!, user: "ann", password: "sesame", salt: "c19b2d")
}

@Suite struct SubsonicAuthTests {
    @Test func tokenIsTheDocumentedHashOfPasswordAndSalt() {
        // The example in the protocol's own documentation.
        #expect(SubsonicAuth.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test func saltsAreFreshHexAndLongEnough() {
        let a = SubsonicAuth.makeSalt(), b = SubsonicAuth.makeSalt()
        #expect(a.count >= 6 && a != b)
        #expect(a.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func requestsCarryTheSignatureAndNeverThePassword() throws {
        let url = try #require(session().url("ping"))
        let q = items(url)
        #expect(url.path == "/rest/ping")
        #expect(q["u"] == ["ann"] && q["s"] == ["c19b2d"] && q["t"] == ["26719a1196d2a940705a59634eb18eab"])
        #expect(q["v"] == ["1.16.1"] && q["c"] == ["StreamSetu"] && q["f"] == ["json"])
        #expect(!url.absoluteString.contains("sesame"))
    }

    @Test func aSessionNeverPrintsItsToken() {
        let s = session()
        #expect(!"\(s)".contains(s.token) && !String(reflecting: s).contains(s.token))
    }

    @Test func repeatedParametersAndPlusSignsSurvive() throws {
        let url = try #require(session().url("star", [("id", "a"), ("id", "b+c")]))
        #expect(items(url)["id"] == ["a", "b+c"])
        #expect(url.absoluteString.contains("b%2Bc"))
    }

    @Test func aServerUnderAPathKeepsIt() throws {
        let url = try #require(session(base: "https://example.org/navidrome").url("ping"))
        #expect(url.path == "/navidrome/rest/ping")
    }
}

@Suite struct SubsonicStreamAndCoverTests {
    @Test func originalStreamAsksForNothingExtra() throws {
        let streamText = try #require(session().streamURL("so1", transcode: SubsonicTranscode()))
        let u = try #require(URL(string: streamText))
        #expect(u.path == "/rest/stream" && items(u)["id"] == ["so1"])
        #expect(items(u)["format"] == nil && items(u)["maxBitRate"] == nil)
    }

    @Test func aConversionAskIsOnTheAddress() throws {
        let streamText = try #require(session().streamURL("so1", transcode: SubsonicTranscode(format: "opus", maxBitRate: 128)))
        let u = try #require(URL(string: streamText))
        #expect(items(u)["format"] == ["opus"] && items(u)["maxBitRate"] == ["128"])
    }

    @Test func onlyListedFormatsAndCeilingsAreAccepted() {
        #expect(SubsonicTranscode(format: "flac", maxBitRate: 100).isOriginal)
        #expect(SubsonicTranscode(format: "mp3", maxBitRate: 64).stored == "mp3:64")
        #expect(SubsonicTranscode(stored: "aac:").format == "aac" && SubsonicTranscode(stored: "aac:").maxBitRate == nil)
        #expect(SubsonicTranscode(stored: ":192").maxBitRate == 192)
        #expect(SubsonicTranscode(stored: nil).isOriginal && SubsonicTranscode(stored: "garbage").isOriginal)
    }

    @Test func coverAddressesAreStableAndSized() throws {
        let a = SubsonicMapper(session: session()).thumbnails("mf-so1")
        #expect(a.map(\.width) == [300, 1200])
        #expect(a == SubsonicMapper(session: session()).thumbnails("mf-so1"))
        #expect(items(try #require(URL(string: a[0].url)))["size"] == ["300"])
        #expect(SubsonicMapper(session: session()).thumbnails(nil).isEmpty)
    }

    @Test func aLosslessFileIsPlayedAsLossless() throws {
        let d = try #require(try JSONSerialization.jsonObject(with: Data(songJSON.utf8)) as? [String: Any])
        let s = try #require(SubsonicMapper(session: session()).stream(for: d, raw: "so1", transcode: SubsonicTranscode()))
        #expect(s.container == "flac" && s.isLossless && s.sampleRate == 44100)
    }

    @Test func aLossyFileKeepsItsBitRateAndAConversionTakesTheAskedOne() throws {
        let d = try #require(try JSONSerialization.jsonObject(with: Data(mp3JSON.utf8)) as? [String: Any])
        let m = SubsonicMapper(session: session())
        let plain = try #require(m.stream(for: d, raw: "so2", transcode: SubsonicTranscode()))
        #expect(plain.codec == "mp3" && plain.bitrate == 256 && !plain.isLossless)
        let conv = try #require(m.stream(for: d, raw: "so2", transcode: SubsonicTranscode(format: "opus", maxBitRate: 96)))
        #expect(conv.codec == "opus" && conv.container == "ogg" && conv.bitrate == 96)
    }
}

@Suite struct SubsonicReplyTests {
    private func parse(_ s: String) throws -> [String: Any] { try SubsonicReply.envelope(try JSONSerialization.jsonObject(with: Data(s.utf8))) }

    @Test func anOkReplyGivesItsBodyAndServerInfo() throws {
        let root = try parse(reply(#""x":1"#))
        let info = SubsonicReply.info(root)
        #expect(info.isNavidrome && info.openSubsonic && info.serverVersion == "0.55.0" && info.apiVersion == "1.16.1")
    }

    @Test func errorCodesBecomeTheAppsOwnErrors() {
        #expect(SubsonicReply.mapError(code: 40) == .notSignedIn("Subsonic"))
        #expect(SubsonicReply.mapError(code: 41) == .notSignedIn("Subsonic"))
        #expect(SubsonicReply.mapError(code: 50) == .refused("Subsonic"))
        #expect(SubsonicReply.mapError(code: 70) == .notFound)
        #expect(SubsonicReply.mapError(code: 30) == .network("server version not supported"))
        #expect(SubsonicReply.mapError(code: 0) == .network("server error 0"))
    }

    @Test func aFailedReplyThrowsWithoutTheServersWords() {
        #expect(throws: MusicError.notSignedIn("Subsonic")) { try parse(failure(40)) }
        do { _ = try parse(failure(70)) } catch { #expect(!"\(error)".contains("nope")) }
    }

    @Test func somethingThatIsNotAReplyIsUnexpected() {
        #expect(throws: MusicError.network("unexpected reply")) { try SubsonicReply.envelope(["hello": 1]) }
    }

    @Test func statusLinesAreSortedFromErrors() {
        #expect(SubsonicStatus.status(forError: MusicError.notSignedIn("Subsonic")) == .wrongLogin)
        #expect(SubsonicStatus.status(forError: MusicError.refused("Subsonic")) == .notAllowed)
        #expect(SubsonicStatus.status(forError: MusicError.network("unexpected reply")) == .notASubsonicServer)
        #expect(SubsonicStatus.status(forError: MusicError.network("HTTP 502")) == .notASubsonicServer)
        #expect(SubsonicStatus.status(forError: MusicError.network("offline")) == .notReachable)
    }

    @Test func oneRowListsCanArriveAsASingleObject() throws {
        let root = try parse(reply(#""starred2":{"song":{"id":"a","title":"t"}}"#))
        #expect(SubsonicRows.rows(root, "starred2", "song").count == 1)
        #expect(SubsonicRows.rows(root, "starred2", "album").isEmpty)
    }

    @Test func artistsComeOutOfTheirIndexGroups() throws {
        let root = try parse(reply(#""artists":{"index":[{"name":"A","artist":[{"id":"1","name":"Ann"}]},{"name":"B","artist":[{"id":"2","name":"Bob"},{"id":"3","name":"Bea"}]}]}"#))
        #expect(SubsonicRows.indexedArtists(root).count == 3)
    }
}

@Suite struct SubsonicMappingTests {
    private func dict(_ s: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }

    @Test func aSongBecomesATrackWithServerScopedIds() throws {
        let t = try #require(SubsonicMapper(session: session()).song(try dict(songJSON)))
        #expect(t.id == "s1~so1" && t.uid == "subsonic:s1~so1" && t.providerID == "subsonic")
        #expect(t.title == "Blue" && t.durationMs == 215_000 && t.trackNumber == 3 && t.discNumber == 1)
        #expect(t.artists.first?.id == "s1~ar1" && t.album?.id == "s1~al1" && t.album?.title == "Skies" && t.album?.releaseDate == "2020")
        #expect(t.explicit && t.isrc == "USAAA2000001" && t.rating == .like)
        #expect(t.directStreams == nil, "the stream address carries the signature, so it is built when played and never stored in a library")
    }

    @Test func twoServersNeverShareAnId() {
        #expect(SubsonicID.make("s1", "7") != SubsonicID.make("s2", "7"))
        #expect(SubsonicID.split("s1~so~1")?.raw == "so~1")
        #expect(SubsonicID.split("noserver") == nil && SubsonicID.split("~x") == nil && SubsonicID.split("s1~") == nil)
    }

    @Test func rowsWithoutAnIdOrTitleAreDropped() throws {
        let m = SubsonicMapper(session: session())
        #expect(m.song(try dict(#"{"title":"x"}"#)) == nil)
        #expect(m.song(try dict(#"{"id":"1"}"#)) == nil)
        #expect(m.album(try dict(#"{"name":"x"}"#)) == nil)
        #expect(m.artist(try dict(#"{"id":"1"}"#)) == nil)
        #expect(m.song(try dict(#"{"id":"1","title":"Folder","isDir":true}"#)) == nil)
    }

    @Test func albumsArtistsAndPlaylistsMap() throws {
        let m = SubsonicMapper(session: session())
        let a = try #require(m.album(try dict(#"{"id":"al1","name":"Skies","artist":"Ann","artistId":"ar1","songCount":9,"year":2020,"coverArt":"al-al1"}"#)))
        #expect(a.id == "s1~al1" && a.totalTracks == 9 && a.artists.first?.name == "Ann" && !a.thumbnails.isEmpty)
        let r = try #require(m.artist(try dict(#"{"id":"ar1","name":"Ann","albumCount":2}"#)))
        #expect(r.id == "s1~ar1" && r.name == "Ann")
        let p = try #require(m.playlist(try dict(#"{"id":"p1","name":"Mix","songCount":4,"owner":"ann","public":true}"#)))
        #expect(p.id == "s1~p1" && p.trackCount == 4 && p.isPublic && p.owner == "ann")
    }

    @Test func replayGainTrackWinsThenAlbumThenFallback() {
        #expect(SubsonicReplayGain(trackGain: -6, albumGain: -9).lufs == -12)
        #expect(SubsonicReplayGain(albumGain: -9).lufs == -9)
        #expect(SubsonicReplayGain(fallbackGain: 0).lufs == -18)
        #expect(SubsonicReplayGain().lufs == nil)
        #expect(SubsonicReplayGain(nil) == nil && SubsonicReplayGain([:]) == nil)
        #expect(SubsonicReplayGain(["trackGain": "-6.54 dB"])?.trackGain == -6.54)
    }
}

@Suite struct SubsonicAddressTests {
    private func ok(_ s: String, tick: Bool = false) -> String? { if case .success(let u) = SubsonicServers.validate(s, ownNetwork: tick) { u.absoluteString } else { nil } }
    private func problem(_ s: String, tick: Bool = false) -> MusicOwnInstances.Problem? { if case .failure(let p) = SubsonicServers.validate(s, ownNetwork: tick) { p } else { nil } }

    @Test func httpsIsAssumedAndTheAddressIsCleaned() {
        #expect(ok("music.example.org") == "https://music.example.org")
        #expect(ok("  https://music.example.org/navidrome/ ") == "https://music.example.org/navidrome")
        #expect(ok("https://music.example.org:4533") == "https://music.example.org:4533")
    }

    @Test func plainHTTPOnlyForYourOwnNetworkWithTheTick() {
        #expect(problem("http://music.example.org") == .needsHTTPS)
        #expect(problem("http://192.168.1.20:4533") == .needsOwnNetworkTick)
        #expect(ok("http://192.168.1.20:4533", tick: true) == "http://192.168.1.20:4533")
        #expect(problem("192.168.1.20:4533") == .needsOwnNetworkTick)
        #expect(ok("http://nas.local:4533", tick: true) == "http://nas.local:4533")
    }

    @Test func oddAddressesAreRefused() {
        #expect(problem("") == .empty)
        #expect(problem("ftp://music.example.org") == .wrongScheme)
        #expect(problem("https://ann:pw@music.example.org") == .credentials)
        #expect(problem("https://music.example.org/a/../b") == .badPath)
        #expect(problem("https://music.example.org?x=1") == .badPath)
    }

    @Test func addRefusesBadInputBeforeTouchingTheKeychain() {
        let d = UserDefaults(suiteName: "subsonic.tests.add")!
        d.removePersistentDomain(forName: "subsonic.tests.add")
        defer { d.removePersistentDomain(forName: "subsonic.tests.add") }
        #expect(SubsonicServers.add(address: "https://music.example.org", username: "  ", password: "pw", ownNetwork: false, defaults: d) == .failure(.noUser))
        #expect(SubsonicServers.add(address: "https://music.example.org", username: "ann", password: "", ownNetwork: false, defaults: d) == .failure(.noPassword))
        #expect(SubsonicServers.add(address: "http://music.example.org", username: "ann", password: "pw", ownNetwork: false, defaults: d) == .failure(.address(.needsHTTPS)))
        #expect(SubsonicServers.load(d).isEmpty)
    }

    @Test func atMostThreeServersAndNoDuplicates() {
        let d = UserDefaults(suiteName: "subsonic.tests.limit")!
        d.removePersistentDomain(forName: "subsonic.tests.limit")
        defer { d.removePersistentDomain(forName: "subsonic.tests.limit") }
        let list = (1...4).map { SubsonicServer(id: "s\($0)", address: "https://m\($0).example.org", username: "ann", salt: "abcdef", ownNetwork: false) }
        SubsonicServers.save(list, d)
        #expect(SubsonicServers.load(d).count == 3)
        #expect(SubsonicServers.add(address: "https://other.example.org", username: "ann", password: "pw", ownNetwork: false, defaults: d) == .failure(.tooMany))
        #expect(SubsonicServers.add(address: "https://m1.example.org", username: "ann", password: "pw", ownNetwork: false, defaults: d) == .failure(.tooMany))
    }

    @Test func onlyServersTickedAsOwnAndPrivateJoinTheAllowList() {
        let d = UserDefaults(suiteName: "subsonic.tests.hosts")!
        d.removePersistentDomain(forName: "subsonic.tests.hosts")
        defer { d.removePersistentDomain(forName: "subsonic.tests.hosts") }
        SubsonicServers.save([
            SubsonicServer(id: "a", address: "http://192.168.1.20:4533", username: "ann", salt: "abcdef", ownNetwork: true),
            SubsonicServer(id: "b", address: "http://192.168.1.21:4533", username: "ann", salt: "abcdef", ownNetwork: false),
            SubsonicServer(id: "c", address: "https://music.example.org", username: "ann", salt: "abcdef", ownNetwork: true),
        ], d)
        #expect(SubsonicServers.privateHosts(d) == ["192.168.1.20"])
    }

    @Test func theSettingsKeysAreDeviceOnlyAndNeverSynced() {
        for k in [SubsonicServers.defaultsKey, SubsonicTranscode.defaultsKey] {
            #expect(MusicDefaultsKeys.deviceSettings.contains(k))
            #expect(!MusicDefaultsKeys.portable.contains(k))
        }
    }

    @Test func aServerWithoutItsPasswordGetsNoSession() {
        let s = SubsonicServers.sessions([server], password: { _ in nil })
        #expect(s.isEmpty)
        #expect(SubsonicServers.sessions([server], password: { _ in "sesame" }).count == 1)
    }
}

@Suite struct SubsonicProviderTests {
    @Test func withoutAServerItIsDormant() async throws {
        let stub = SubsonicStub { _ in (200, reply("")) }
        let p = provider(stub, servers: [])
        #expect(await p.isSignedIn == false && p.statusNote == SubsonicProvider.addServerNote)
        await #expect(throws: MusicError.notSignedIn("Subsonic")) { try await p.searchTracks("blue", page: nil) }
        #expect(stub.requests.isEmpty)
    }

    @Test func itIsKnownButNeedsSetupAndCoversTheRoles() {
        let p = provider(SubsonicStub { _ in (200, "") })
        #expect(p.info.requiresSignIn && p.info.kind == .builtIn)
        #expect(p.capabilities.isSuperset(of: [.search, .browse, .tracks, .albums, .artists, .playlists, .audio, .scrobble, .library]))
        #expect(!MusicSetupPresets.defaultSet(providers: [p]).contains(p.id), "a source that needs an account is never in the default set")
    }

    @Test func searchAsksForSongsOnlyAndMapsThem() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""searchResult3":{"song":["# + songJSON + "]}")) }
        let page = try await provider(stub).searchTracks("blue", page: .offset(offset: 60, limit: 20))
        #expect(page.items.map(\.id) == ["s1~so1"])
        let q = items(try #require(stub.requests.first))
        #expect(stub.requests.first?.path == "/rest/search3")
        #expect(q["query"] == ["blue"] && q["songCount"] == ["20"] && q["songOffset"] == ["60"] && q["albumCount"] == ["0"] && q["artistCount"] == ["0"])
        #expect(page.next == nil, "a short page ends the list")
    }

    @Test func aFullPageOffersTheNextOne() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""searchResult3":{"song":["# + songJSON + "," + mp3JSON + "]}")) }
        let page = try await provider(stub).searchTracks("blue", page: .offset(offset: 0, limit: 2))
        #expect(page.next == .offset(offset: 2, limit: 2))
    }

    @Test func twoServersAreAskedAndJoinedInOrder() async throws {
        let second = SubsonicServer(id: "s2", address: "https://two.example.org", username: "bob", salt: "abcdef", ownNetwork: false)
        let stub = SubsonicStub { url in
            url.host == "two.example.org" ? (200, reply(#""searchResult3":{"song":["# + mp3JSON + "]}")) : (200, reply(#""searchResult3":{"song":["# + songJSON + "]}"))
        }
        let page = try await provider(stub, servers: [server, second]).searchTracks("x", page: nil)
        #expect(page.items.map(\.id) == ["s1~so1", "s2~so2"])
        #expect(Set(stub.requests.compactMap(\.host)) == ["music.example.org", "two.example.org"])
    }

    @Test func oneServerFailingStillShowsTheOther() async throws {
        let second = SubsonicServer(id: "s2", address: "https://two.example.org", username: "bob", salt: "abcdef", ownNetwork: false)
        let stub = SubsonicStub { url in url.host == "two.example.org" ? (500, "") : (200, reply(#""searchResult3":{"song":["# + songJSON + "]}")) }
        #expect(try await provider(stub, servers: [server, second]).searchTracks("x", page: nil).items.count == 1)
    }

    @Test func aWrongPasswordIsASignInProblem() async {
        let stub = SubsonicStub { _ in (200, failure(40)) }
        await #expect(throws: MusicError.notSignedIn("Subsonic")) { try await provider(stub).searchTracks("x", page: nil) }
    }

    @Test func anIdFromAnUnknownServerIsNotFound() async {
        let stub = SubsonicStub { _ in (200, reply("")) }
        await #expect(throws: MusicError.notFound) { try await provider(stub).track(id: "zz~so1") }
        #expect(stub.requests.isEmpty)
    }

    @Test func similarSongsRadioUsesTheTrackCallAndDropsTheSeed() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""similarSongs2":{"song":["# + songJSON + "," + mp3JSON + "]}")) }
        let out = try await provider(stub).recommendations(seedTrackIDs: ["s1~so1"], limit: 25)
        #expect(out.map(\.id) == ["s1~so2"])
        let q = items(try #require(stub.requests.first))
        #expect(stub.requests.first?.path == "/rest/getSimilarSongs2" && q["id"] == ["so1"] && q["count"] == ["25"])
    }

    @Test func radioFallsBackToTheOlderCallWhenTheFirstIsEmpty() async throws {
        let stub = SubsonicStub { url in
            url.path.hasSuffix("getSimilarSongs2") ? (200, reply(#""similarSongs2":{}"#)) : (200, reply(#""similarSongs":{"song":["# + mp3JSON + "]}"))
        }
        #expect(try await provider(stub).recommendations(seedTrackIDs: ["s1~so1"], limit: 10).map(\.id) == ["s1~so2"])
        #expect(stub.requests.map(\.lastPathComponent) == ["getSimilarSongs2", "getSimilarSongs"])
    }

    @Test func starringSendsEveryIdOfTheServerInOneCall() async throws {
        let stub = SubsonicStub { _ in (200, reply("")) }
        try await provider(stub).setSaved(true, trackIDs: ["s1~a", "s1~b", "zz~c"])
        #expect(stub.requests.count == 1 && stub.requests[0].path == "/rest/star")
        #expect(items(stub.requests[0])["id"] == ["a", "b"])
        try await provider(stub).setSaved(false, trackIDs: ["s1~a"])
        #expect(stub.requests.last?.path == "/rest/unstar")
    }

    @Test func savedStatusComesFromTheStarredList() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""starred2":{"song":["# + songJSON + "]}")) }
        #expect(try await provider(stub).isSaved(trackIDs: ["s1~so1", "s1~so2"]) == [true, false])
    }

    @Test func playlistsListAndPage() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""playlists":{"playlist":[{"id":"p1","name":"Mix","songCount":2},{"id":"p2","name":"Road","songCount":5}]}"#)) }
        let page = try await provider(stub).savedPlaylists(page: .offset(offset: 0, limit: 1))
        #expect(page.items.map(\.name) == ["Mix"] && page.totalCount == 2 && page.next == .offset(offset: 1, limit: 1))
        #expect(try await provider(stub).searchPlaylists("roa", page: nil).items.map(\.name) == ["Road"])
    }

    @Test func playlistEditsUseTheDocumentedCalls() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""playlist":{"id":"p9","name":"New"}"#)) }
        let p = provider(stub)
        let rawSong394 = try #require(try JSONSerialization.jsonObject(with: Data(songJSON.utf8)) as? [String: Any])
        let song394 = try #require(SubsonicMapper(session: session()).song(rawSong394))
        let made = try await p.createPlaylist(name: "New", tracks: [song394])
        #expect(made?.id == "s1~p9")
        #expect(items(stub.requests[0])["name"] == ["New"] && items(stub.requests[0])["songId"] == ["so1"])
        try await p.removeEntries(at: [2, 0], fromPlaylist: "s1~p9")
        #expect(items(stub.requests[1])["songIndexToRemove"] == ["0", "2"] && items(stub.requests[1])["playlistId"] == ["p9"])
        try await p.deletePlaylist(id: "s1~p9")
        #expect(stub.requests[2].path == "/rest/deletePlaylist")
    }

    @Test func ownTracksSkipTheMatcherAndStreamWithTheConversionAsk() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""song":"# + mp3JSON)) }
        let p = provider(stub, transcode: SubsonicTranscode(format: "mp3", maxBitRate: 192))
        let rawSongA1 = try #require(try JSONSerialization.jsonObject(with: Data(mp3JSON.utf8)) as? [String: Any])
        let track = try #require(SubsonicMapper(session: session()).song(rawSongA1))
        let sources = try await p.sources(for: track)
        #expect(sources.count == 1 && sources[0].confidence == 1 && sources[0].providerID == "subsonic" && sources[0].streams == nil)
        #expect(stub.requests.isEmpty, "finding the source of an own track needs no request")
        let streams = try await p.streams(for: sources[0])
        let u = try #require(URL(string: streams[0].url))
        #expect(u.path == "/rest/stream" && items(u)["id"] == ["so2"] && items(u)["format"] == ["mp3"] && items(u)["maxBitRate"] == ["192"])
    }

    @Test func aSongFromAnotherSourceIsFoundInTheLibraryByTitleAndArtist() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""searchResult3":{"song":["# + songJSON + "," + mp3JSON + "]}")) }
        let want = MusicTrack(id: "x", providerID: "spotify", title: "Blue", durationMs: 215_000, artists: [MusicArtistRef(id: "a", name: "Ann")])
        let found = try await provider(stub).sources(for: want)
        #expect(found.first?.id == "s1~so1" && !found.contains { $0.id == "s1~so2" })
        let other = MusicTrack(id: "y", providerID: "spotify", title: "Completely Different", durationMs: 100_000, artists: [MusicArtistRef(id: "b", name: "Zed")])
        #expect(try await provider(stub).sources(for: other).isEmpty)
    }

    @Test func theServerReplayGainBecomesALoudness() async throws {
        let stub = SubsonicStub { _ in (200, reply(#""song":"# + songJSON)) }
        let rawSongA2 = try #require(try JSONSerialization.jsonObject(with: Data(songJSON.utf8)) as? [String: Any])
        let track = try #require(SubsonicMapper(session: session()).song(rawSongA2))
        #expect(await provider(stub).loudnessLUFS(for: track) == -11.5)
        let plain = SubsonicStub { _ in (200, reply(#""song":"# + mp3JSON)) }
        let rawSongA3 = try #require(try JSONSerialization.jsonObject(with: Data(mp3JSON.utf8)) as? [String: Any])
        let t2 = try #require(SubsonicMapper(session: session()).song(rawSongA3))
        #expect(await provider(plain).loudnessLUFS(for: t2) == nil)
    }

    @Test func playReportsCarryTheStartTimeInMillisecondsAndOnlyForOwnSongs() async throws {
        let stub = SubsonicStub { _ in (200, reply("")) }
        let p = provider(stub)
        let rawSongA4 = try #require(try JSONSerialization.jsonObject(with: Data(songJSON.utf8)) as? [String: Any])
        let track = try #require(SubsonicMapper(session: session()).song(rawSongA4))
        try await p.scrobble(MusicScrobble(timestamp: Date(timeIntervalSince1970: 1_700_000_000), track: track, playedMs: 200_000))
        var q = items(stub.requests[0])
        #expect(q["id"] == ["so1"] && q["time"] == ["1700000000000"] && q["submission"] == ["true"])
        await p.nowPlaying(track)
        q = items(stub.requests[1])
        #expect(q["submission"] == ["false"] && q["time"] == nil)
        let foreign = MusicTrack(id: "x", providerID: "spotify", title: "t", durationMs: 1, artists: [])
        try await p.scrobble(MusicScrobble(timestamp: Date(), track: foreign, playedMs: 1))
        await p.nowPlaying(foreign)
        #expect(stub.requests.count == 2)
    }

    @Test func aTestCallSortsTheAnswerIntoPlainWords() async {
        let ok = await SubsonicProbe.run(session(), http: MusicHTTP(transport: SubsonicStub { _ in (200, reply("")) }))
        #expect(ok.isWorking)
        if case .working(_, let info) = ok { #expect(info.isNavidrome) }
        #expect(await SubsonicProbe.run(session(), http: MusicHTTP(transport: SubsonicStub { _ in (200, failure(40)) })) == .wrongLogin)
        #expect(await SubsonicProbe.run(session(), http: MusicHTTP(transport: SubsonicStub { _ in (404, "") })) == .notASubsonicServer)
        #expect(await SubsonicProbe.run(session(), http: MusicHTTP(transport: SubsonicStub { _ in (200, "<html>") })) == .notASubsonicServer)
    }

    @Test func errorsNeverCarryTheRequestAddress() async {
        let stub = SubsonicStub { _ in (503, "") }
        do { _ = try await provider(stub).searchTracks("x", page: nil) } catch {
            #expect(!"\(error)".contains("26719a1196d2a940705a59634eb18eab") && !"\(error)".contains("c19b2d"))
        }
    }
}
