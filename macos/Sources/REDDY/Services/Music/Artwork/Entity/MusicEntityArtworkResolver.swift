import Foundation

// The resolver: one chain per kind of thing, one answer with provenance. Lazy (nothing runs until asked), concurrent-safe (single flight per
// subject, at most `maxConcurrent` subjects at once), never on the playback path, and it never answers with a picture it could not verify.

/// What the resolver may read from the music graph. The production adapter reads the graph store; tests answer from memory.
protocol MusicArtworkGraphContext: Sendable {
    /// The subject with everything the graph knows added: external ids, jobs, titles of works, year, creator.
    func enrich(_ subject: MusicArtworkSubject) async -> MusicArtworkSubject
    /// A picture the graph already holds for this subject (an `imageRef` turned into an address).
    func storedAddress(for subject: MusicArtworkSubject) async -> String?
    /// Other things whose picture may stand in, best first (a film's soundtrack albums, a song's album then film, a playlist's songs, a facet's albums).
    func related(to subject: MusicArtworkSubject) async -> [MusicArtworkRelation]
}

struct MusicArtworkRelation: Sendable, Hashable {
    var subject: MusicArtworkSubject
    var label: String
}

/// What a source can use: the transport (the governed one in the app), the TMDB gate, the graph, and the clock.
struct MusicArtworkContext: Sendable {
    var transport: any MusicMetadataTransport
    /// The app's TMDB client (`MusicFilmTMDBGate`): key, switch and pacing are its business. Nil when TMDB is not set up.
    var tmdb: (@Sendable (String, [URLQueryItem]) async throws -> Data)?
    var now: @Sendable () -> Date = { Date() }
}

protocol MusicArtworkSource: Sendable {
    var id: MusicArtworkSourceID { get }
    /// The Settings switch that turns this source off (nil: only the shared artwork switch applies).
    var switchID: MusicSourceID? { get }
    func applies(to kind: MusicEntityKind) -> Bool
    /// Candidates for the subject, best first. Returns [] for "nothing here"; throws for a network failure (the resolver remembers those only briefly).
    func candidates(for subject: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate]
}

/// The facts the resolver reads from the outside world before every network step.
struct MusicArtworkGate: Sendable {
    /// Music consent given, not a Kids profile or a locked app, online, and the "find pictures online" switch on.
    var networkAllowed: @Sendable () -> Bool
    var sourceOn: @Sendable (MusicSourceID) -> Bool
    static let open = MusicArtworkGate(networkAllowed: { true }, sourceOn: { _ in true })
    static let closed = MusicArtworkGate(networkAllowed: { false }, sourceOn: { _ in false })
}

/// The order of steps per kind of thing. `relations` borrows the picture of a related thing; `stored` is the graph's own picture.
enum MusicArtworkStep: Hashable, Sendable {
    case stored
    case source(MusicArtworkSourceID)
    case relations

    static func plan(for kind: MusicEntityKind) -> [MusicArtworkStep] {
        switch kind {
        case .person, .group:
            return [.stored, .source(.wikimedia), .source(.tmdb), .source(.imdb), .source(.deezer), .source(.jiosaavn)]
        case .film, .series:
            return [.stored, .source(.wikimedia), .source(.tmdb), .source(.imdb), .relations, .source(.itunes), .source(.deezer), .source(.jiosaavn)]
        case .album, .release:
            return [.stored, .source(.coverArtArchive), .source(.itunes), .source(.deezer), .source(.jiosaavn), .relations]
        case .recording, .track, .work:
            return [.stored, .relations, .source(.itunes), .source(.deezer), .source(.jiosaavn)]
        case .playlist, .genre, .language, .region, .era, .station:
            return [.stored, .relations]
        }
    }
}

/// Limits how many subjects resolve at once, so a screen of fifty cards does not start fifty chains. Cancel-safe.
actor MusicArtworkLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UInt64, c: CheckedContinuation<Void, Never>)] = []
    private var next: UInt64 = 0

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit { running += 1; return }
        next += 1
        let id = next
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append((id, c)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// A waiter woken by cancellation proceeds and is counted as running, so the caller must `release` exactly once (it does, in a defer).
    private func cancel(_ id: UInt64) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { running += 1; waiters.remove(at: i).c.resume() }
    }

    func release() {
        running -= 1
        if !waiters.isEmpty, running < limit { running += 1; waiters.removeFirst().c.resume() }
    }
}

actor MusicEntityArtworkResolver {
    static let maxDepth = 2
    static let maxRelations = 3

    private struct Flight { let id: UInt64; var waiters: Int; let task: Task<MusicResolvedArtwork?, Never> }

    private let sources: [MusicArtworkSourceID: any MusicArtworkSource]
    private let graph: (any MusicArtworkGraphContext)?
    nonisolated let cache: MusicArtworkResolutionCache
    private let gate: MusicArtworkGate
    private let probe: @Sendable (String) async -> Bool
    private let context: MusicArtworkContext
    private let limiter: MusicArtworkLimiter
    private var flights: [String: Flight] = [:]
    private var nextFlight: UInt64 = 0

    /// - probe: loads the picture through Music's own artwork service (and so warms its disk cache); false when it is dead or not an image.
    init(sources: [any MusicArtworkSource], graph: (any MusicArtworkGraphContext)?, cache: MusicArtworkResolutionCache, gate: MusicArtworkGate,
         context: MusicArtworkContext, maxConcurrent: Int = 2, probe: @escaping @Sendable (String) async -> Bool) {
        var map: [MusicArtworkSourceID: any MusicArtworkSource] = [:]
        for s in sources { map[s.id] = s }
        self.sources = map; self.graph = graph; self.cache = cache; self.gate = gate; self.context = context; self.probe = probe
        self.limiter = MusicArtworkLimiter(limit: maxConcurrent)
    }

    /// The remembered answer, or nil (no network, no waiting). Safe from any thread.
    nonisolated func cached(_ subject: MusicArtworkSubject) -> MusicResolvedArtwork? { cache.positive(subject.key) }

    func forget(_ subject: MusicArtworkSubject, address: String?) { cache.forgetPositive(subject.key, ifAddress: address) }

    /// The best verified picture for the subject, or nil. Concurrent calls for one subject share one run; the run is cancelled when the last caller leaves.
    func resolve(_ subject: MusicArtworkSubject) async -> MusicResolvedArtwork? {
        if let hit = cache.positive(subject.key) { return hit }
        if cache.isMiss(subject.key) { return nil }
        let key = subject.key
        let flight: Flight
        if var f = flights[key] {
            f.waiters += 1; flights[key] = f; flight = f
        } else {
            nextFlight += 1
            let id = nextFlight
            // Utility priority: finding a picture is never urgent, and must not compete with scrolling and playback for the processor.
            let task = Task(priority: .utility) { [self] () -> MusicResolvedArtwork? in
                await limiter.acquire()
                let r = Task.isCancelled ? nil : await run(subject, depth: 0, visited: [key])
                await limiter.release()
                finish(key, id: id)
                return r
            }
            flight = Flight(id: id, waiters: 1, task: task)
            flights[key] = flight
        }
        return await withTaskCancellationHandler { await flight.task.value } onCancel: { Task { await self.leave(key, id: flight.id) } }
    }

    private func leave(_ key: String, id: UInt64) {
        guard var f = flights[key], f.id == id else { return }
        f.waiters -= 1
        if f.waiters <= 0 { f.task.cancel(); flights[key] = nil } else { flights[key] = f }
    }

    private func finish(_ key: String, id: UInt64) { if flights[key]?.id == id { flights[key] = nil } }

    // MARK: the chain

    private func run(_ original: MusicArtworkSubject, depth: Int, visited: Set<String>) async -> MusicResolvedArtwork? {
        let subject = await graph?.enrich(original) ?? original
        let threshold = MusicArtworkMatch.minimumConfidence(for: subject.kind)
        var sawTransientFailure = false
        for step in MusicArtworkStep.plan(for: subject.kind) {
            if Task.isCancelled { return nil }
            switch step {
            case .stored:
                if let address = await graph?.storedAddress(for: subject), await probe(address) {
                    return finalise(MusicResolvedArtwork(address: address, source: .stored, confidence: 1, evidence: ["graph"], credit: nil, resolvedAt: context.now(), borrowedFrom: nil), for: original)
                }
            case .source(let id):
                guard let source = sources[id], source.applies(to: subject.kind), allowed(source) else { continue }
                let missKey = subject.key + "|" + id.rawValue
                if cache.isMiss(missKey) { continue }
                do {
                    let found = try await source.candidates(for: subject, context: context)
                    var tried = false
                    for c in found.sorted(by: { $0.confidence > $1.confidence }) where c.confidence >= threshold {
                        tried = true
                        if Task.isCancelled { return nil }
                        if await probe(c.address) {
                            return finalise(MusicResolvedArtwork(address: c.address, source: c.source, confidence: c.confidence, evidence: c.evidence, credit: c.credit,
                                                                 resolvedAt: context.now(), borrowedFrom: nil), for: original)
                        }
                    }
                    cache.recordMiss(missKey, transient: tried)   // an address that would not load is a short memory, an empty answer a day
                    if tried { sawTransientFailure = true }
                } catch is CancellationError {
                    return nil
                } catch {
                    sawTransientFailure = true
                    cache.recordMiss(missKey, transient: true)
                }
            case .relations:
                guard depth < Self.maxDepth else { continue }
                var related = await graph?.related(to: subject) ?? []
                // A song the graph has no edge for yet still knows the album it was listed on.
                if related.isEmpty, subject.isSongLike, let album = subject.works.first, !album.isEmpty {
                    related = [MusicArtworkRelation(subject: .album(album, creator: subject.creator), label: album)]
                }
                for rel in related.prefix(Self.maxRelations) where !visited.contains(rel.subject.key) {
                    if Task.isCancelled { return nil }
                    var hit = cache.positive(rel.subject.key)
                    if hit == nil, !cache.isMiss(rel.subject.key) { hit = await run(rel.subject, depth: depth + 1, visited: visited.union([rel.subject.key])) }
                    if let hit {
                        return finalise(MusicResolvedArtwork(address: hit.address, source: .relation, confidence: min(hit.confidence, 0.9), evidence: ["via:" + hit.source.rawValue],
                                                             credit: hit.credit, resolvedAt: context.now(), borrowedFrom: rel.label), for: original)
                    }
                }
            }
        }
        // Nothing: remember briefly when a network step failed (so a flaky minute is not a day-long "no"), otherwise for the full miss time.
        if depth == 0 { cache.recordMiss(original.key, transient: sawTransientFailure) }
        return nil
    }

    private func allowed(_ s: any MusicArtworkSource) -> Bool {
        guard gate.networkAllowed() else { return false }
        if let sw = s.switchID { return gate.sourceOn(sw) }
        return true
    }

    private func finalise(_ r: MusicResolvedArtwork, for subject: MusicArtworkSubject) -> MusicResolvedArtwork {
        cache.store(r, for: subject.key)
        return r
    }
}
