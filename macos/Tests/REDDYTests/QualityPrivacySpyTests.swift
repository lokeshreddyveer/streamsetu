import Testing
import Foundation
@testable import REDDY

/// A spy stands in for every network call: locked, hidden and twin-of-locked titles and channels must never reach TMDB, fanart.tv, TheTVDB or TVmaze,
/// and nothing that is sent may carry a key in the URL or any personal data. In-memory database, no sleeps, no network.
@Suite("Privacy network spy") struct QualityPrivacySpyTests {
    static let token = "eyJ" + String(repeating: "q", count: 60)
    static let forbidden = ["secret", "hidden", "cross title", "voyage"]

    final class Spy: @unchecked Sendable {
        private let l = NSLock(); private var reqs: [URLRequest] = []
        func record(_ r: URLRequest) { l.withLock { reqs.append(r) } }
        var all: [URLRequest] { l.withLock { reqs } }
    }

    private func make() throws -> (PrivacyMatrix, MetadataMatchService, Spy) {
        let m = try PrivacyMatrix(); try m.lock(); m.session(locked: true)
        try m.db.write { try $0.exec("UPDATE movies SET poster_url=NULL, rating=NULL; UPDATE series SET poster_url=NULL, rating=NULL") }      // every title now waits, restricted or not
        let creds = InMemoryCredentialStore()
        let spy = Spy()
        let body = Data(#"{"results":[{"id":7,"title":"Open Film One","poster_path":"/p.jpg","release_date":"2010-01-01","vote_average":7.4,"vote_count":300,"popularity":5}]}"#.utf8)
        let svc = MetadataMatchService(db: m.db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { Self.token }) { r in spy.record(r); return body }
        return (m, svc, spy)
    }

    private func assertClean(_ reqs: [URLRequest], sourceNames: [String] = []) {
        for r in reqs {
            let url = (r.url?.absoluteString ?? "").lowercased().removingPercentEncoding ?? ""
            for f in Self.forbidden { #expect(!url.contains(f), "restricted word '\(f)' in \(url)") }
            #expect(!url.contains("api_key") && !url.contains(Self.token.lowercased()) && !url.contains("apikey") && !url.contains("token="), "a key in the URL")
            let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self).lowercased()
            for f in Self.forbidden { #expect(!body.contains(f)) }
            for n in sourceNames { #expect(!url.contains(n.lowercased()) && !body.contains(n.lowercased()), "playlist name sent") }
            for h in ["cookie", "x-user", "x-profile", "x-device"] { #expect(r.value(forHTTPHeaderField: h) == nil, "personal header \(h)") }
            #expect(r.url?.user == nil && r.url?.host?.contains("example") != true)
        }
    }

    @Test func theBulkRunNeverAsksAboutARestrictedTitle() async throws {
        let (m, svc, spy) = try make()
        _ = try await svc.run()
        let reqs = spy.all
        #expect(!reqs.isEmpty, "the open titles are still looked up")
        assertClean(reqs, sourceNames: ["Alpha", "Beta"])
        #expect(Set(try svc.pending(limit: 100).items.map(\.id)).isDisjoint(with: m.restrictedIDs.union(m.restrictedTwinIDs)))
    }

    @Test func theExpressLaneAndTheRatingBackfillOnlyOfferSendableTitles() throws {
        let (m, svc, _) = try make()
        let everything = Array(m.ids.values)
        let blocked = m.restrictedIDs.union(m.restrictedTwinIDs)
        for c in svc.candidates(ids: everything) + svc.ratingCandidates(ids: everything) { #expect(!blocked.contains(c.id), "express offered \(c.title)") }
        for c in svc.ratingBacklog(limit: 500) { #expect(!blocked.contains(c.id), "backlog offered \(c.title)") }
        for id in blocked { #expect(!svc.isSendable(id)) }
        #expect(svc.isSendable(m.id("A:Open Film One")))
    }

    @Test func unlockedSessionStillNeverSendsAHiddenOrLockedFolder() async throws {
        let (m, svc, spy) = try make(); m.session(locked: false)
        _ = try await svc.run()
        assertClean(spy.all)
        #expect(!svc.isSendable(m.id("A:Hidden Film")) && !svc.isSendable(m.id("A:Secret Film")))
    }

    final class StubArt: ArtworkProvider, @unchecked Sendable {
        let source: HubSource; private let l = NSLock(); private var ids: [Int] = []
        init(_ s: HubSource) { source = s }
        func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] { l.withLock { ids.append(id.tmdb ?? id.tvdb ?? 0) }; return [] }
        var asked: [Int] { l.withLock { ids } }
    }
    final class StubEpisodes: EpisodeProvider, @unchecked Sendable {
        let source = HubSource.tvmaze; private let l = NSLock(); private var ids: [Int] = []
        func episodes(for id: HubIdentity) async throws -> HubEpisodes? { l.withLock { ids.append(id.tvmaze ?? 0) }; return nil }
        var asked: [Int] { l.withLock { ids } }
    }

    @Test func theHubNeverAsksFanartTvdbOrTvmazeAboutARestrictedTitle() async throws {
        let (m, svc, _) = try make()
        let d = UserDefaults(suiteName: "q.priv.\(UUID())")!
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func acc(_ s: HubSource) -> HubAccess { HubAccess(source: s, secrets: MemorySecretStore(), builtIn: { "FAKE" }, defaults: d, now: { t0 }) }
        let fan = StubArt(.fanart), tvdb = StubArt(.tvdb), maze = StubEpisodes()
        let hub = MetadataHub(store: HubStore(db: m.db), artwork: [fan, tvdb], episodes: [maze], access: [.fanart: acc(.fanart), .tvdb: acc(.tvdb), .tvmaze: acc(.tvmaze)],
                              isSendable: { svc.isSendable($0) }, now: { t0 }, sleep: { _ in })
        var number: [String: Int] = [:]; var n = 1000
        for (_, id) in m.ids.sorted(by: { $0.key < $1.key }) { n += 1; number[id] = n }
        for (key, id) in m.ids where !key.hasSuffix("Channel") {
            let k = number[id]!
            await hub.refresh(id, identity: HubIdentity(tmdb: k, tvdb: k, imdb: nil, tvmaze: k), kind: key.contains("Show") ? .series : .movie)
        }
        let blockedNumbers = Set(m.restrictedIDs.union(m.restrictedTwinIDs).compactMap { number[$0] })
        let asked = Set(fan.asked + tvdb.asked + maze.asked)
        #expect(!asked.isEmpty, "open titles are enriched")
        #expect(asked.isDisjoint(with: blockedNumbers), "restricted ids reached a provider")
    }

    @Test func providerRequestBuildersKeepKeysOutOfTheURL() throws {
        let key = "FAKEKEY123456"
        let fan = try #require(FanartProvider.request(kind: .movie, id: "603", keys: FanartKeys(projectKey: key, clientKey: "CLIENTKEY99")))
        let login = try #require(TVDBSession.loginRequest(apiKey: key, pin: "PIN4242"))
        let maze = try #require(TVmazeProvider.showRequest(id: HubIdentity(tmdb: nil, tvdb: 81189, imdb: "tt0903747", tvmaze: nil)))
        for r in [fan, login, maze] {
            let u = r.url!.absoluteString
            #expect(!u.contains(key) && !u.contains("CLIENTKEY99") && !u.contains("PIN4242") && r.url?.query?.contains("key") != true, "\(u)")
            #expect(r.url?.scheme == "https")
        }
        #expect(fan.value(forHTTPHeaderField: "api-key") == key)
        #expect(String(decoding: login.httpBody ?? Data(), as: UTF8.self).contains(key))
        #expect(maze.value(forHTTPHeaderField: "Authorization") == nil && maze.httpBody == nil)
    }
}
