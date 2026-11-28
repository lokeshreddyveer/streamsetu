import Foundation
import Testing
@testable import REDDY

// Contract tests for the two scrobbling services. The canned replies are copies of what the public services answered on 2026-11-25 to read-only
// requests (an invalid token, a missing key, a bogus key). Nothing here submits a listen and nothing touches the network.

private final class ServiceStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private final class ServiceStore: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ initial: [String: String] = [:]) { values = initial }
    func read(_ account: String) -> String? { lock.withLock { values[account] } }
    func write(_ value: String, account: String) { lock.withLock { values[account] = value } }
    func remove(_ account: String) { lock.withLock { values[account] = nil } }
}

private let serviceTrack = MusicTrack(id: "t1", providerID: "spotify", title: "Song", durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Band")])

/// What api.listenbrainz.org/1/validate-token answered for a made-up token: HTTP 200 (not 401) with valid false.
private let lbInvalid = #"{"code":200,"message":"Token invalid.","valid":false}"#
private let lbValid = #"{"code":200,"message":"Token valid.","user_name":"someone","valid":true}"#
private let lbMissingHeader = #"{"code":400,"error":"You need to provide an Authorization token."}"#
private let lastFMNoKey = #"{"message":"Invalid parameters - Your request is missing a required parameter","error":6}"#
private let lastFMBadKey = #"{"message":"Invalid API key - You must be granted a valid key by last.fm","error":10}"#

@Suite struct ScrobbleListenBrainzContractTests {
    @Test func invalidTokenAnswersHTTP200WithValidFalseAndNothingIsStored() async {
        let stub = ServiceStub { _ in (200, lbInvalid) }
        let store = ServiceStore()
        let http = MusicHTTP(transport: stub)
        let p = ListenBrainzProvider(http: http, store: store)
        await #expect(throws: MusicError.notSignedIn("ListenBrainz")) { try await p.setToken("00000000-0000-0000-0000-000000000000") }
        #expect(store.read(ListenBrainzProvider.tokenAccount) == nil)
        #expect(stub.requests.count == 1 && stub.requests[0].url?.path == "/1/validate-token")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Token 00000000-0000-0000-0000-000000000000")

        let client = ListenBrainzClient(http: http, store: store)
        do { _ = try await client.connect(token: "x", server: ""); Issue.record("expected a refusal") }
        catch let e as ScrobbleSendError { #expect(e == .refused("Token invalid.")) } catch { Issue.record("wrong error") }
        #expect(!client.isConnected)
    }

    @Test func validTokenNamesTheUserAndIsKept() async throws {
        let store = ServiceStore()
        let client = ListenBrainzClient(http: MusicHTTP(transport: ServiceStub { _ in (200, lbValid) }), store: store)
        #expect(try await client.connect(token: " tok ", server: "") == "someone")
        #expect(client.token == "tok" && client.username == "someone" && client.isConnected)
    }

    @Test func missingAuthorizationHeaderIsAHTTP400WithAnErrorField() async {
        let client = ListenBrainzClient(http: MusicHTTP(transport: ServiceStub { _ in (400, lbMissingHeader) }), store: ServiceStore())
        do { _ = try await client.connect(token: "x", server: ""); Issue.record("expected a refusal") }
        catch let e as ScrobbleSendError { if case .refused = e {} else { Issue.record("wrong kind \(e)") } } catch { Issue.record("wrong error") }
    }

    @Test func withoutATokenEverythingIsDormant() async throws {
        let stub = ServiceStub { _ in (200, "{}") }
        let p = ListenBrainzProvider(http: MusicHTTP(transport: stub), store: ServiceStore())
        #expect(await p.isSignedIn == false)
        #expect(p.statusNote == "Add your key to start" && p.capabilities == [.scrobble])
        await p.nowPlaying(serviceTrack)
        await #expect(throws: MusicError.notSignedIn("ListenBrainz")) { try await p.scrobble(MusicScrobble(timestamp: Date(), track: serviceTrack, playedMs: 100_000)) }
        let client = ListenBrainzClient(http: MusicHTTP(transport: stub), store: ServiceStore())
        let payload = ScrobblePayloadTrack(artist: "Band", title: "Song", album: "", durationMs: 1000, isrc: nil, originURL: nil)
        await #expect(throws: ScrobbleSendError.signedOut) { try await client.playingNow(payload) }
        await #expect(throws: ScrobbleSendError.signedOut) { try await client.listen(payload, start: Date()) }
        #expect(stub.requests.isEmpty)
    }

    @Test func listenBodyUsesTheDocumentedFields() throws {
        let payload = ScrobblePayloadTrack(artist: "Band", title: "Song", album: "Alb", durationMs: 200_000, isrc: "USAAA0000001", originURL: "https://open.spotify.com/track/t1")
        let single = try #require((try JSONSerialization.jsonObject(with: ListenBrainzClient.payload(listenType: "single", payload, listenedAt: Date(timeIntervalSince1970: 1_700_000_000), version: "1.0"))) as? [String: Any])
        #expect(single["listen_type"] as? String == "single")
        let listen = try #require((single["payload"] as? [[String: Any]])?.first)
        #expect(listen["listened_at"] as? Int == 1_700_000_000)
        let meta = try #require(listen["track_metadata"] as? [String: Any])
        #expect(meta["artist_name"] as? String == "Band" && meta["track_name"] as? String == "Song" && meta["release_name"] as? String == "Alb")
        let playing = try #require((try JSONSerialization.jsonObject(with: ListenBrainzClient.payload(listenType: "playing_now", payload, listenedAt: nil, version: "1.0"))) as? [String: Any])
        #expect((playing["payload"] as? [[String: Any]])?.first?["listened_at"] == nil)
    }
}

@Suite struct ScrobbleLastFMContractTests {
    @Test func missingKeyAndBadKeyAnswerWithErrorCodesInTheBody() async throws {
        let stub = ServiceStub { req in
            let q = req.url?.query ?? ""
            return q.contains("api_key=") ? (403, lastFMBadKey) : (400, lastFMNoKey)
        }
        let store = ServiceStore()
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: store)
        // No key saved: no request is made at all.
        do { _ = try await client.getToken(); Issue.record("expected an error") } catch let e as LastFMAPIError { #expect(e.code == 10) } catch { Issue.record("wrong error") }
        #expect(stub.requests.isEmpty)
        client.setAppKeys(key: "bogus", secret: "s")
        do { _ = try await client.getToken(); Issue.record("expected an error") } catch let e as LastFMAPIError { #expect(e.code == 10 && e.message.contains("Invalid API key")) } catch { Issue.record("wrong error") }
        let url = try #require(stub.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "method" }?.value == "auth.getToken" && items.first { $0.name == "format" }?.value == "json" && items.contains { $0.name == "api_sig" })
        #expect(stub.requests.first?.httpMethod == "GET")
    }

    @Test func withoutCredentialsEverythingIsDormant() async throws {
        let stub = ServiceStub { _ in (200, "{}") }
        let p = LastFMProvider(http: MusicHTTP(transport: stub), store: ServiceStore())
        #expect(await p.isSignedIn == false)
        #expect(p.statusNote == "Add your key to start")
        await p.nowPlaying(serviceTrack)
        await #expect(throws: MusicError.notSignedIn("Last.fm")) { try await p.scrobble(MusicScrobble(timestamp: Date(), track: serviceTrack, playedMs: 100_000)) }
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: ServiceStore())
        await #expect(throws: ScrobbleSendError.signedOut) { try await client.nowPlaying(artist: "A", title: "T", album: "") }
        await #expect(throws: ScrobbleSendError.signedOut) { try await client.scrobble(artist: "A", title: "T", album: "", start: Date(), durationMs: 1000) }
        #expect(stub.requests.isEmpty)
    }

    @Test func aWriteThatIsNotJSONIsRefusedNotCountedAsSent() async {
        let creds = #"{"apiKey":"k","secret":"s","sessionKey":"sk"}"#
        let store = ServiceStore(["lastfm.credentials": creds])
        let client = LastFMClient(http: MusicHTTP(transport: ServiceStub { _ in (200, "FAILED Incorrect protocol version") }), store: store)
        do { try await client.scrobble(artist: "A", title: "T", album: "", start: Date(), durationMs: 1000); Issue.record("expected a refusal") }
        catch let e as ScrobbleSendError { if case .refused = e {} else { Issue.record("wrong kind \(e)") } } catch { Issue.record("wrong error") }
    }

    @Test func signatureFollowsTheDocumentedRule() {
        // name+value pairs sorted by name, secret appended, MD5; format is not signed.
        let sig = LastFMProvider.signature(["method": "auth.getToken", "api_key": "xxx", "format": "json"], secret: "ssss")
        #expect(sig == MusicHash.md5("api_keyxxxmethodauth.getTokenssss"))
    }
}
