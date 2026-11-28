import Foundation

/// Decides once per queue tail whether to fetch more music. It remembers the tail it already tried, so a provider that returns nothing
/// is never asked again until the queue has a different last track.
struct MusicEndlessGate: Sendable, Equatable {
    private(set) var attempted: UUID?
    private(set) var inFlight = false
    /// Empty answers for the current tail. One empty answer (a network blip, a rate limit) must not end autoplay for good, so the tail is
    /// asked again after a growing wait, up to `retryDelays.count` times.
    private(set) var failures = 0
    private(set) var nextAt = Date.distantPast

    func shouldFetch(enabled: Bool, repeatOff: Bool, isTail: Bool, tailKey: UUID?, now: Date = Date()) -> Bool {
        guard enabled, repeatOff, isTail, let tailKey, !inFlight else { return false }
        if attempted != tailKey { return true }
        return failures > 0 && failures <= MusicAutoplayEngine.retryDelays.count && now >= nextAt
    }

    mutating func begin(_ key: UUID) { if attempted != key { failures = 0 }; attempted = key; inFlight = true }
    mutating func finish() { inFlight = false }
    /// The fetch for the current tail found nothing.
    mutating func noteEmpty(now: Date = Date()) {
        failures += 1
        nextAt = now.addingTimeInterval(MusicAutoplayEngine.retryDelays[min(failures, MusicAutoplayEngine.retryDelays.count) - 1])
    }
    /// Seconds to wait before the next try, or nil when the tries are used up.
    var retryDelay: TimeInterval? { failures > 0 && failures <= MusicAutoplayEngine.retryDelays.count ? MusicAutoplayEngine.retryDelays[failures - 1] : nil }
    /// Forget the tail, for a freshly built queue.
    mutating func reset() { attempted = nil; inFlight = false; failures = 0 }
    /// Treat this tail as done so nothing is fetched for it (the person cleared the auto-added tracks).
    mutating func suppress(_ key: UUID?) { attempted = key; inFlight = false; failures = 0 }
}

/// Keeps Smart Shuffle from asking for suggestions again and again: it is asked on every position tick.
/// An answer that placed nothing is remembered with the queue it was asked for, and no new request goes out until that queue changes. An empty answer (offline, a source
/// with nothing to say) waits a growing time before the next try.
struct MusicSuggestGate: Sendable, Equatable {
    struct Key: Equatable, Sendable { var epoch: Int; var own: Int; var suggested: Int }
    static let backoff: [TimeInterval] = [30, 120, 300, 900]
    private(set) var spent: Key?
    private(set) var emptyAnswers = 0
    private(set) var nextAt = Date.distantPast

    func shouldFetch(_ key: Key, now: Date) -> Bool { key != spent && now >= nextAt }
    /// Songs came back but none could be placed in this queue.
    mutating func placedNothing(_ key: Key) { spent = key; emptyAnswers = 0; nextAt = .distantPast }
    /// Nothing came back.
    mutating func answeredNothing(now: Date) {
        emptyAnswers += 1
        nextAt = now.addingTimeInterval(Self.backoff[min(emptyAnswers, Self.backoff.count) - 1])
    }
    mutating func reset() { self = MusicSuggestGate() }
}

/// What a fetched track must pass to be queued: not blocked, not recently played, not already queued, no repeats of a song, few per artist.
struct MusicEndlessFilter: Sendable {
    var blocked: Set<String> = []
    var recentUIDs: Set<String> = []
    var queuedUIDs: Set<String> = []
    var queuedKeys: Set<String> = []
    var limit = MusicEndlessSource.batchSize
    var perArtistCap = MusicEndlessSource.perArtistCap
    /// Artists of the song that seeded the batch: they get a larger share, because "more like this" is mostly more of them.
    var seedArtistKeys: Set<String> = []
    var seedArtistCap = MusicEndlessSource.seedArtistCap

    func apply<G: RandomNumberGenerator>(_ candidates: [MusicTrack], using rng: inout G) -> [MusicTrack] {
        var seenKeys = queuedKeys
        var seenUIDs = queuedUIDs.union(recentUIDs)
        var perArtist: [String: Int] = [:]
        var out: [MusicTrack] = []
        for t in candidates {
            if out.count >= limit { break }
            if blocked.contains(t.uid) || t.artists.contains(where: { blocked.contains($0.id) }) { continue }
            if seenUIDs.contains(t.uid) { continue }
            let key = MusicEndlessSource.songKey(t)
            if seenKeys.contains(key) { continue }
            let artist = MusicEndlessSource.artistKey(t)
            if perArtist[artist, default: 0] >= (seedArtistKeys.contains(artist) ? max(seedArtistCap, perArtistCap) : perArtistCap) { continue }
            perArtist[artist, default: 0] += 1
            seenKeys.insert(key); seenUIDs.insert(t.uid)
            out.append(t)
        }
        return MusicEndlessSource.lightShuffle(out, using: &rng)
    }
}

/// Finds similar music to keep a queue going. The selection rules are pure so they can be tested without a network.
enum MusicEndlessSource {
    static let batchSize = 15
    static let perArtistCap = 2
    static let seedArtistCap = 4
    static let recentWindow = 50
    /// Seconds before the end of the last track at which the fetch may start (it also starts when that track begins).
    static let finalWindow: TimeInterval = 20
    static let maxSeeds = 5

    static func songKey(_ t: MusicTrack) -> String { normalise(t.title) + "|" + normalise(t.artists.first?.name ?? "") }
    static func artistKey(_ t: MusicTrack) -> String {
        guard let a = t.artists.first else { return "" }
        return a.id.isEmpty ? normalise(a.name) : a.id
    }

    static func normalise(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Shuffles inside small windows only, so the order stays close to the provider's ranking.
    static func lightShuffle<G: RandomNumberGenerator>(_ items: [MusicTrack], window: Int = 4, using rng: inout G) -> [MusicTrack] {
        var out: [MusicTrack] = []
        var i = 0
        while i < items.count {
            let end = min(items.count, i + window)
            out += items[i..<end].shuffled(using: &rng)
            i = end
        }
        return out
    }

    /// Asks the provider for candidates in order: recommendations, then top tracks of the artist and related artists, then a search.
    /// A stage counts only when it yields something that passes the filter. Errors end a stage quietly.
    static func load(provider: any MusicMetadataProvider, current: MusicTrack, seeds: [MusicTrack], filter: MusicEndlessFilter) async -> [MusicTrack] {
        var rng = SystemRandomNumberGenerator()
        let own = provider.id
        let seedIDs = seeds.filter { $0.providerID == own }.prefix(maxSeeds).map(\.id)
        if !seedIDs.isEmpty, let recs = try? await provider.recommendations(seedTrackIDs: Array(seedIDs), limit: 20) {
            let picked = filter.apply(recs, using: &rng)
            if !picked.isEmpty { return picked }
        }
        if Task.isCancelled { return [] }
        if current.providerID == own, let artist = current.artists.first {
            var pool = (try? await provider.artistTopTracks(id: artist.id)) ?? []
            let related = ((try? await provider.relatedArtists(id: artist.id)) ?? []).prefix(3)
            for r in related {
                if Task.isCancelled { return [] }
                pool += ((try? await provider.artistTopTracks(id: r.id)) ?? []).prefix(5)
            }
            let picked = filter.apply(pool, using: &rng)
            if !picked.isEmpty { return picked }
        }
        if Task.isCancelled { return [] }
        if let name = current.artists.first?.name, !name.isEmpty,
           let page = try? await provider.searchTracks(name, page: nil) {
            return filter.apply(page.items, using: &rng)
        }
        return []
    }
}

/// When the queue ran dry and autoplay brought nothing back, ask once more after a short wait, then stop quietly.
struct MusicEmptyQueueWatchdog: Sendable, Equatable {
    static let retryDelay: TimeInterval = 3
    private(set) var retried = false

    /// True once per dry spell; the second dry answer returns false and the queue ends.
    mutating func shouldRetry() -> Bool {
        if retried { retried = false; return false }
        retried = true
        return true
    }

    /// A song started: a later dry spell gets its retry again.
    mutating func reset() { retried = false }
}
