import Foundation
import Testing
@testable import REDDY

/// Recorded replies (trimmed) of the real services, under Tests/REDDYTests/Music/Fixtures.
enum MetadataFixtures {
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["MUSIC_FIXTURES_DIR"] { return URL(fileURLWithPath: env, isDirectory: true) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func data(_ name: String) -> Data { (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data() }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}

/// Answers sources from fixtures by a substring of the request address (`path?sorted=query`). Counts and records every call.
final class FixtureTransport: MusicMetadataTransport, @unchecked Sendable {
    struct Route { var match: String; var file: String? ; var data: Data? = nil; var fail: MusicError? = nil }
    private let lock = NSLock()
    private var routes: [Route]
    private(set) var calls: [String] = []
    var failAll: MusicError?
    /// Fixtures of `wbgetentities` replies: the one that holds the first requested id answers.
    var peopleFiles: [String] = []

    init(_ routes: [Route] = []) { self.routes = routes }
    func add(_ r: Route) { lock.withLock { routes.insert(r, at: 0) } }
    func route(_ match: String, _ file: String) { add(Route(match: match, file: file)) }
    var callCount: Int { lock.withLock { calls.count } }
    func calls(containing s: String) -> Int { lock.withLock { calls.filter { $0.contains(s) }.count } }

    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data {
        let key = url.absoluteString + "?" + query.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        let (hit, fail): (Route?, MusicError?) = lock.withLock {
            calls.append(key)
            return (routes.first { key.contains($0.match) }, failAll)
        }
        if let f = fail { throw f }
        if key.contains("action=wbgetentities"), !peopleFiles.isEmpty {
            let ids = key.components(separatedBy: "ids=").dropFirst().first?.components(separatedBy: "&").first ?? ""
            let first = ids.components(separatedBy: "|").first ?? ""
            for f in peopleFiles where MetadataFixtures.text(f).contains("\"\(first)\"") { return MetadataFixtures.data(f) }
            throw MusicError.notFound
        }
        guard let r = hit else { throw MusicError.notFound }
        if let f = r.fail { throw f }
        return r.data ?? MetadataFixtures.data(r.file ?? "")
    }
}

/// A clock that only moves when asked or when a sleeper needs it to: sleeping until T sets now to T. Records every sleep target.
final class VirtualClock: MusicGovernorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    private(set) var sleeps: [TimeInterval] = []
    func now() -> TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    func sleep(until time: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { sleeps.append(time); if time > t { t = time } }
        await Task.yield()
    }
}

/// A source that answers from a closure; counts its fetches.
final class CountingSource: MusicMetadataSource, @unchecked Sendable {
    let id: MusicSourceID
    var policy: MusicSourcePolicy { MusicSourcePolicy(hosts: [], license: .cc0, retention: nil, attribution: nil, ttl: [:], defaultTTL: 3600, defaultOn: true, privacyNote: "") }
    private let lock = NSLock()
    private var n = 0
    let body: @Sendable (MusicSourceRequest) async throws -> MusicClaimBatch
    init(_ id: MusicSourceID, body: @escaping @Sendable (MusicSourceRequest) async throws -> MusicClaimBatch) { self.id = id; self.body = body }
    var fetchCount: Int { lock.withLock { n } }
    func fetch(_ request: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        lock.withLock { n += 1 }
        return try await body(request)
    }
}
