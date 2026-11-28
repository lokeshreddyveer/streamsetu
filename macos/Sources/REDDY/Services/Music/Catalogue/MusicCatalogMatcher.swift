import Foundation

/// What a typed query turned into after asking the catalogue: the song it most likely means and the search texts that use the catalogue's words.
struct MusicQueryExpansion: Sendable, Equatable {
    var canonical: MusicCanonicalTrack?
    /// Up to three texts, none equal to what was typed.
    var queries: [String]
    static let none = MusicQueryExpansion(canonical: nil, queries: [])
}

/// Finds, for a song a metadata-only source knows, the playable copy on the audio sources and checks it, without starting playback.
/// A copy is accepted by the same kind of rules the resolver uses (version words, artist, running time) plus the twin scoring in `MusicTwinSelection`.
/// Everything is tolerant: a source that is down or slow is skipped, and with no answer the song simply has no twin yet.
actor MusicCatalogMatcher {
    struct Environment: Sendable {
        var audio: @Sendable () async -> [any MusicAudioProvider]
        var catalogue: @Sendable () async -> [any MusicMetadataProvider]
    }

    /// Per catalogue hit: how long its copy may be searched for.
    nonisolated static let hitBudget: TimeInterval = 6
    nonisolated static let concurrency = 3
    nonisolated static let expansionBudget: TimeInterval = 3

    private let store: MusicCanonicalStore
    private let env: Environment
    private let rules: MusicTwinRules
    private let now: @Sendable () -> Date
    private var inflight: [String: Task<MusicCanonicalTrack?, Never>] = [:]

    init(store: MusicCanonicalStore, environment: Environment, rules: MusicTwinRules = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.env = environment; self.rules = rules; self.now = now
    }

    /// The enabled catalogue sources that can search (for the enrichment calls).
    func environmentCatalogue() async -> [any MusicMetadataProvider] { await env.catalogue() }
    /// The enabled sources that play audio (for the chart pipeline's "does this source play its own songs").
    func environmentAudio() async -> [any MusicAudioProvider] { await env.audio() }

    // MARK: canonical identity

    /// The canonical form of a catalogue row, remembered.
    @discardableResult
    func canonicalise(_ track: MusicTrack) -> MusicCanonicalTrack {
        store.put(MusicCatalogCanon.make(from: track, now: now()))
    }

    // MARK: twins

    /// The canonical song with at least one verified playable copy, or nil when none was found (a miss is remembered for a day).
    func twin(for track: MusicTrack) async -> MusicCanonicalTrack? {
        let fresh = MusicCatalogCanon.make(from: track, now: now())
        if let known = store.canonical(for: track) {
            // A hit is written again only when this row is new to the entry: a write on every hit would renew its life and rewrite the file for each row of a page.
            if known.isMatched { if !known.seenOn.contains(track.uid) { _ = store.put(withSeen(known, track.uid)) }; return known }
            if now().timeIntervalSince(known.checkedAt) < MusicCanonicalStore.unmatchedTTL, known.checkedAt.timeIntervalSince1970 > 0 { return nil }
        }
        let key = fresh.key
        if let running = inflight[key] { return await running.value }
        let task = Task<MusicCanonicalTrack?, Never> { [self] in await self.probe(fresh) }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func withSeen(_ c: MusicCanonicalTrack, _ uid: String) -> MusicCanonicalTrack {
        var x = c
        if !x.seenOn.contains(uid) { x.seenOn.append(uid) }
        return x
    }

    private func probe(_ canonical: MusicCanonicalTrack) async -> MusicCanonicalTrack? {
        let found = await dryRun(canonical)
        var c = canonical
        if !found.reached { _ = store.put(c); return nil }
        c.twins = found.twins
        c.checkedAt = now()
        let saved = store.put(c)
        return saved.isMatched ? saved : nil
    }

    struct DryRun: Sendable { var twins: [MusicCanonicalTwin]; var reached: Bool }

    /// Asks every audio source for candidates (title and artist, title and film, another spelling), scores them and keeps the accepted ones.
    /// No stream is opened and nothing is played. `reached` is false when no source answered at all, so a dead network is not remembered as "no copy".
    func dryRun(_ canonical: MusicCanonicalTrack, budget: TimeInterval = MusicCatalogMatcher.hitBudget) async -> DryRun {
        let providers = await env.audio()
        guard !providers.isEmpty else { return DryRun(twins: [], reached: false) }
        let variants = MusicTwinSelection.variants(for: canonical)
        let rules = self.rules
        let collector = Collector()
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for p in providers {
                    group.addTask {
                        for v in variants {
                            if Task.isCancelled { return }
                            guard let sources = try? await p.sources(for: v) else { continue }
                            collector.answered()
                            let ranked = MusicTwinSelection.rank(canonical: canonical, candidates: sources, rules: rules)
                            collector.add(ranked.map { ($0.source, $0.verdict) })
                            if let top = ranked.first, top.verdict.score >= 0.8 { return }
                        }
                    }
                }
            }
        }
        let finished = await Self.race(work, seconds: budget)
        work.cancel()
        let snap = collector.snapshot()
        let twins = snap.hits.sorted { $0.1.score > $1.1.score }.prefix(3).map { (s, v) in
            MusicCanonicalTwin(providerID: s.providerID, sourceID: s.id, title: s.title, artist: s.artist, album: s.album, durationMs: s.durationMs,
                               externalURL: s.externalURL, thumbnails: s.thumbnails, score: v.score, deltaMs: v.deltaMs, hasStreams: !(s.streams ?? []).isEmpty)
        }
        // A search that was cut short by the time limit and found nothing says nothing about the song: it is not remembered as "no copy" (it is asked again next time).
        return DryRun(twins: Array(twins), reached: snap.answered > 0 && (finished || !twins.isEmpty))
    }

    /// Waits for a task, but never longer than `seconds`. A real race: the caller gets the first answer (or the timeout) at once. A task group would wait for its
    /// slower child, and awaiting another task's value does not react to cancellation, so the deadline would never cut anything short. The caller cancels the task.
    private static func race(_ task: Task<Void, Never>, seconds: TimeInterval) async -> Bool {
        do { try await MusicStreamResolver.withDeadline(seconds) { await task.value }; return true } catch { return false }
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [(MusicAudioSource, MusicTwinVerdict)] = []
        private var count = 0
        func add(_ h: [(MusicAudioSource, MusicTwinVerdict)]) { lock.withLock { hits.append(contentsOf: h) } }
        func answered() { lock.withLock { count += 1 } }
        func snapshot() -> (hits: [(MusicAudioSource, MusicTwinVerdict)], answered: Int) { lock.withLock { (hits, count) } }
    }

    // MARK: lists

    /// For each catalogue row, its playable form or nil. Three at a time, 4 seconds each, and no more than `budget` seconds in all: rows still
    /// being matched when the budget ends are left out now (no new row is started; a lookup already running finishes in the background, so the next search finds it cached).
    func playable(_ tracks: [MusicTrack], budget: TimeInterval = 6) async -> [MusicTrack?] {
        let results = Slots(tracks.count)
        let queue = Counter(tracks.count)
        let workers = (0..<Self.concurrency).map { _ in
            Task { [self] in
                while !Task.isCancelled, let i = queue.next() {
                    let t = tracks[i]
                    if let direct = t.directStreams, !direct.isEmpty { results.set(i, t); continue }
                    if let c = await self.twin(for: t) { results.set(i, Self.playableTrack(from: c, catalogueRow: t)) }
                }
            }
        }
        let all = Task { for w in workers { await w.value } }
        _ = await Self.race(all, seconds: budget)
        // The workers are separate tasks: cancelling `all` does not reach them, so each one is told to stop (their finished rows stay in `results`).
        all.cancel()
        for w in workers { w.cancel() }
        return results.snapshot()
    }

    final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MusicTrack?]
        init(_ n: Int) { items = Array(repeating: nil, count: n) }
        func set(_ i: Int, _ t: MusicTrack) { lock.withLock { items[i] = t } }
        func snapshot() -> [MusicTrack?] { lock.withLock { items } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var i = 0
        private let n: Int
        init(_ n: Int) { self.n = n }
        func next() -> Int? { lock.withLock { guard i < n else { return nil }; defer { i += 1 }; return i } }
    }

    /// The catalogue row's own id for a credited name, only when the playable copy comes from the same source (an id means nothing to another one).
    nonisolated private static func artistID(named name: String, in row: MusicTrack, sameSource: Bool) -> String {
        guard sameSource else { return "" }
        return row.artists.first { $0.name == name }?.id ?? ""
    }

    /// The song as a track the player can resolve: the playable copy's identity with the catalogue's words, running time and cover.
    nonisolated static func playableTrack(from c: MusicCanonicalTrack, catalogueRow: MusicTrack) -> MusicTrack {
        guard let twin = c.twins.first else { return catalogueRow }
        let cover = c.coverURL.map { [MusicThumbnail(url: $0, width: 1000, height: 1000)] } ?? []
        // Ids belong to the source that gave them: the catalogue row's album and artist ids are kept only when the playable copy is from that same source, and a
        // name or title is never used as an id (an empty id is plain text, so "Go to album" and "Go to artist" are not offered for it).
        let sameSource = twin.providerID == catalogueRow.providerID
        var album: MusicAlbumRef?
        if sameSource, let own = catalogueRow.album {
            album = own
        } else if let title = catalogueRow.album?.title ?? c.album ?? c.film {
            album = MusicAlbumRef(id: "", title: title)
        }
        var t = MusicTrack(id: twin.sourceID, providerID: twin.providerID, title: c.title, durationMs: c.durationMs > 0 ? c.durationMs : (twin.durationMs ?? 0),
                           artists: c.artists.map { name in MusicArtistRef(id: Self.artistID(named: name, in: catalogueRow, sameSource: sameSource), name: name) },
                           album: album,
                           thumbnails: cover + twin.thumbnails, explicit: c.explicit, popularity: catalogueRow.popularity, isrc: c.isrc)
        t.externalURL = twin.externalURL ?? catalogueRow.externalURL
        if MusicTwinRules.standard.youTubeFamily.contains(twin.providerID) { t.videoID = twin.sourceID }
        return t
    }

    // MARK: query expansion

    /// Asks the catalogue what the typed words mean. Nil canonical when the catalogue is silent, slow, or nothing fits well enough.
    func expand(_ query: String, budget: TimeInterval = MusicCatalogMatcher.expansionBudget) async -> MusicQueryExpansion {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return .none }
        let providers = await env.catalogue()
        guard !providers.isEmpty else { return .none }
        let box = HitBox()
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for p in providers {
                    group.addTask { if let page = try? await p.searchTracks(q, page: nil) { box.add(Array(page.items.prefix(5))) } }
                }
            }
        }
        _ = await Self.race(work, seconds: budget)
        work.cancel()
        guard let best = Self.bestHit(for: q, among: box.snapshot()) else { return .none }
        let canon = canonicalise(best)
        let typed = MusicText.normalize(q)
        let qs = MusicTwinSelection.queries(for: canon).filter { MusicText.normalize($0) != typed }
        return MusicQueryExpansion(canonical: canon, queries: qs)
    }

    final class HitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MusicTrack] = []
        func add(_ t: [MusicTrack]) { lock.withLock { items.append(contentsOf: t) } }
        func snapshot() -> [MusicTrack] { lock.withLock { items } }
    }

    /// The hit whose title (with or without the artist) fits the typed words best, at least 0.8; exact spellings beat phonetic ones.
    nonisolated static func bestHit(for query: String, among hits: [MusicTrack]) -> MusicTrack? {
        var best: (MusicTrack, Float)?
        for h in hits {
            let clean = MusicCatalogCanon.make(from: h)
            let s = max(MusicTransliterationKey.similarity(query, clean.title),
                        MusicTransliterationKey.similarity(query, clean.title + " " + clean.primaryArtist),
                        MusicTransliterationKey.similarity(query, clean.primaryArtist + " " + clean.title))
            if s >= 0.8, s > (best?.1 ?? 0) { best = (h, s) }
        }
        return best?.0
    }
}
