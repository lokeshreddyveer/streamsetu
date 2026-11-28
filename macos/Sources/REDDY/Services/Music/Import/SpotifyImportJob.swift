import Foundation
import Observation

// The import run: read a source, match every distinct track once, let the person review, then write local playlists. Matches are remembered, so a stopped
// or failed run resumes where it left off, and the person's own picks are kept even when caches are cleared.

// MARK: - Pacing and budget

/// How many searches an import may make and when it must rest. Fixed numbers, no setting.
struct ImportBudget: Codable, Equatable, Sendable {
    static let searchesPerHour = 600
    static let cooldown: TimeInterval = 3600
    var windowStart: Date?
    var count = 0
    var cooldownUntil: Date?

    enum Admission: Equatable { case go, wait(until: Date), cooldown(until: Date) }

    /// Asks to make one search. Beyond 600 in an hour the run waits until the hour is over; after a block from the service it stops for an hour.
    mutating func admit(now: Date) -> Admission {
        if let c = cooldownUntil, c > now { return .cooldown(until: c) }
        cooldownUntil = nil
        if let s = windowStart, now.timeIntervalSince(s) < 3600 {
            if count >= Self.searchesPerHour { return .wait(until: s.addingTimeInterval(3600)) }
        } else { windowStart = now; count = 0 }
        count += 1
        return .go
    }

    /// The service refused (429 or 403, or a bot check): no imports for an hour.
    mutating func trip(now: Date) { cooldownUntil = now.addingTimeInterval(Self.cooldown) }
}

enum ImportMessages {
    /// What each failure code says to the person.
    static func text(_ e: ImportError) -> String {
        switch e {
        case .private: String(localized: "That list is private or has been deleted. Open it on Spotify, make it public, or use your Spotify data instead.")
        case .notSpotify: String(localized: "That is not a Spotify link.")
        case .notAList: String(localized: "Paste a playlist or album link. Song and artist links open from the Music search instead.")
        case .empty: String(localized: "There were no songs to bring over.")
        case .spotifyChanged: String(localized: "Spotify's page looks different from what was expected, so it could not be read. Try your Spotify data export instead.")
        case .unreadable: String(localized: "That file could not be read.")
        case .csvColumns: String(localized: "The CSV needs a column with the song title (for example Track Name).")
        case .busy: String(localized: "One import at a time. Wait for the current one to finish.")
        case .nothingRead: String(localized: "No songs were found in that file.")
        case .gone: String(localized: "That playlist is no longer here.")
        case .cooldown(let until): String(localized: "The music service asked for a rest. Try again at \(until.formatted(date: .omitted, time: .shortened)).")
        case .network(let m): m
        }
    }
}

enum ImportPacing {
    /// One request at a time: searches 1.2 to 2.0 s apart, and after every 40 requests an extra 15 to 25 s break.
    static func delay(afterRequest n: Int, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        var d = random(1.2...2.0)
        if n > 0, n % 40 == 0 { d += random(15...25) }
        return d
    }
}

// MARK: - Match cache

struct ImportMatchRecord: Codable, Hashable, Sendable {
    var key: String
    var tier: ImportTier
    var pick: MusicTrack?
    /// Kept for every tier except matched.
    var candidates: [MusicTrack] = []
    /// The person's own choice: reused by every later import and kept when caches are cleared.
    var manual = false
    var updatedAt: Date
}

@MainActor @Observable
final class ImportMatchCache {
    static let missingRetryAfter: TimeInterval = 7 * 86_400
    private(set) var records: [String: ImportMatchRecord]
    @ObservationIgnored private let store: MusicJSONStore<[String: ImportMatchRecord]>

    init(directory: URL, debounce: Duration = .seconds(1)) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MusicJSONStore(url: directory.appendingPathComponent("import-matches.json"), debounce: debounce)
        records = store.load() ?? [:]
    }

    /// An answer worth reusing: the person's picks always, matches and checks always, misses only for 7 days.
    func lookup(_ key: String, now: Date = Date()) -> ImportMatchRecord? {
        guard let r = records[key] else { return nil }
        if r.tier == .missing, !r.manual, now.timeIntervalSince(r.updatedAt) > Self.missingRetryAfter { return nil }
        return r
    }

    func set(_ r: ImportMatchRecord) { records[r.key] = r; store.save(records) }

    /// Clearing caches keeps the person's own picks.
    func clearCaches() { records = records.filter { $0.value.manual }; store.save(records) }
    func flush() { store.flush() }
}

// MARK: - Source records (Update from Spotify)

struct SpotifySourceRecord: Codable, Hashable, Sendable {
    var url: String
    /// The Spotify track keys the playlist held, in order.
    var keys: [String]
    var auto = false
    var checked: Date
}

@MainActor @Observable
final class ImportSourceStore {
    private(set) var records: [String: SpotifySourceRecord]
    @ObservationIgnored private let store: MusicJSONStore<[String: SpotifySourceRecord]>
    init(directory: URL, debounce: Duration = .seconds(1)) {
        store = MusicJSONStore(url: directory.appendingPathComponent("import-sources.json"), debounce: debounce)
        records = store.load() ?? [:]
    }
    func record(for id: UUID) -> SpotifySourceRecord? { records[id.uuidString] }
    func set(_ r: SpotifySourceRecord, for id: UUID) { records[id.uuidString] = r; store.save(records) }
    /// Deleting a playlist forgets where it came from.
    func forget(_ id: UUID) { records[id.uuidString] = nil; store.save(records) }
    func flush() { store.flush() }
}

// MARK: - Update planning (pure)

enum ImportUpdate {
    struct Plan: Equatable { var add: [String]; var remove: Set<String> }

    /// Songs new on Spotify are added (unless the playlist already holds them); songs that left Spotify are removed unless another remaining track maps to the same song.
    static func plan(previousKeys: [String], newKeys: [String], currentUIDs: [String], uid: (String) -> String?) -> Plan {
        let prev = Set(previousKeys), now = Set(newKeys), have = Set(currentUIDs)
        var add: [String] = [], seen = Set<String>()
        for k in newKeys where !prev.contains(k) {
            if let u = uid(k), !have.contains(u), seen.insert(u).inserted { add.append(u) }
        }
        let kept = Set(newKeys.compactMap(uid))
        var remove = Set<String>()
        for k in previousKeys where !now.contains(k) {
            if let u = uid(k), have.contains(u), !kept.contains(u) { remove.insert(u) }
        }
        return Plan(add: add, remove: remove)
    }

    /// Puts Spotify's songs in Spotify's order while manual additions keep their exact positions: the rows that are Spotify's are re-dealt into the slots
    /// Spotify's songs already hold. A song present twice is Spotify's the first time only.
    static func order(current: [String], spotify: [String]) -> [String] {
        var seen = Set<String>()
        let sp = spotify.filter { seen.insert($0).inserted }
        let spSet = Set(sp)
        var firstSeen = Set<String>(), slots: [Int] = []
        for (i, u) in current.enumerated() where spSet.contains(u) && firstSeen.insert(u).inserted { slots.append(i) }
        let present = Set(slots.map { current[$0] })
        let dealt = sp.filter { present.contains($0) }
        var out = current
        for (slot, u) in zip(slots, dealt) { out[slot] = u }
        return out
    }

    struct Move: Equatable { var id: String; var before: String? }

    /// The fewest "move item before item" steps: keep the longest increasing subsequence of the current order, move the rest from the end of the target backwards
    /// (a track that went to the top is one move, not many). Both lists must hold the same ids.
    static func minimalMoves(current: [String], target: [String]) -> [Move] {
        guard current != target, Set(current) == Set(target), current.count == target.count else { return [] }
        let pos = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($1, $0) })
        let seq = current.map { pos[$0] ?? 0 }
        // Longest increasing subsequence by patience sorting.
        var tails: [Int] = [], tailIdx: [Int] = [], prev = [Int](repeating: -1, count: seq.count)
        for (i, v) in seq.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if tails[mid] < v { lo = mid + 1 } else { hi = mid } }
            if lo == tails.count { tails.append(v); tailIdx.append(i) } else { tails[lo] = v; tailIdx[lo] = i }
            prev[i] = lo > 0 ? tailIdx[lo - 1] : -1
        }
        var keep = Set<String>()
        var k = tailIdx.last ?? -1
        while k >= 0 { keep.insert(current[k]); k = prev[k] }
        var moves: [Move] = []
        for i in stride(from: target.count - 1, through: 0, by: -1) where !keep.contains(target[i]) {
            moves.append(Move(id: target[i], before: i + 1 < target.count ? target[i + 1] : nil))
        }
        return moves
    }

    static func apply(_ moves: [Move], to list: [String]) -> [String] {
        var out = list
        for m in moves {
            guard let f = out.firstIndex(of: m.id) else { continue }
            out.remove(at: f)
            if let b = m.before, let t = out.firstIndex(of: b) { out.insert(m.id, at: t) } else { out.append(m.id) }
        }
        return out
    }

    /// First check 2 minutes after launch, then every 30; each playlist at most every 6 hours, longest unchecked first.
    static let firstCheckDelay: TimeInterval = 120, checkInterval: TimeInterval = 1800, perPlaylistInterval: TimeInterval = 6 * 3600, readSpacing: TimeInterval = 5
    static func due(_ records: [String: SpotifySourceRecord], now: Date) -> [String] {
        records.filter { $0.value.auto && now.timeIntervalSince($0.value.checked) >= perPlaylistInterval }.sorted { $0.value.checked < $1.value.checked }.map(\.key)
    }
}

// MARK: - The job

struct ImportRow: Identifiable, Hashable, Sendable {
    var key: String
    var source: ImportSourceTrack
    var tier: ImportTier
    var pick: MusicTrack?
    var candidates: [MusicTrack]
    var manual: Bool
    var id: String { key }
}

struct ImportResult: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var added: Int
    var notFound: Int
}

@MainActor @Observable
final class SpotifyImportJob {
    /// The one import of the app, so it keeps running when its window is closed ("Keep browsing").
    static let shared = SpotifyImportJob(registry: MusicHub.shared.registry, library: MusicHub.shared.library, directory: MusicHub.supportDirectory)

    enum Phase: Equatable { case idle, reading, pick, matching, review, creating, done, failed(ImportError), cancelled }
    typealias Searcher = @Sendable (String) async throws -> [MusicTrack]
    typealias Reader = @Sendable (SpotifyLink) async throws -> ImportList

    private(set) var phase: Phase = .idle
    private(set) var lists: [ImportList] = []
    var selected: Set<Int> = []
    private(set) var rows: [String: ImportRow] = [:]
    private(set) var done = 0
    private(set) var total = 0
    private(set) var recentMatched: [ImportRow] = []
    private(set) var waitingUntil: Date?
    private(set) var results: [ImportResult] = []
    private(set) var startedAt: Date?
    /// Rises with every change a screen should react to; a late snapshot never rolls the screen back.
    private(set) var generation = 0

    @ObservationIgnored let registry: MusicRegistry
    @ObservationIgnored let library: MusicLibrary
    @ObservationIgnored let cache: ImportMatchCache
    @ObservationIgnored let sources: ImportSourceStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let searcher: Searcher?
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let sleeper: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let budgetKey = "music.import.budget"

    init(registry: MusicRegistry, library: MusicLibrary, directory: URL, defaults: UserDefaults = .standard, http: MusicHTTP = MusicHTTP(),
         searcher: Searcher? = nil, reader: Reader? = nil, sleeper: (@Sendable (TimeInterval) async -> Void)? = nil) {
        self.registry = registry; self.library = library
        self.cache = ImportMatchCache(directory: directory)
        self.sources = ImportSourceStore(directory: directory)
        self.defaults = defaults; self.searcher = searcher
        self.reader = reader ?? { try await SpotifyLinkReader(http: http, auth: SpotifyAuth(http: http)).read($0) }
        self.sleeper = sleeper ?? { try? await Task.sleep(for: .seconds($0)) }
    }

    // MARK: budget

    private var budget: ImportBudget {
        get { defaults.data(forKey: budgetKey).flatMap { try? JSONDecoder().decode(ImportBudget.self, from: $0) } ?? ImportBudget() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: budgetKey) }
    }
    /// When the service block ends, if one is running. Device-only playlists ignore it.
    var cooldownEnds: Date? { budget.cooldownUntil.flatMap { $0 > Date() ? $0 : nil } }
    /// The hourly search budget as it stands, so the scheduler can decline to start a run that would only sit waiting.
    var budgetState: ImportBudget { budget }

    private func bump() { generation += 1 }

    // MARK: sources

    var isBusy: Bool { [.reading, .matching, .creating].contains(phase) }

    func reset() { task?.cancel(); phase = .idle; lists = []; selected = []; rows = [:]; done = 0; total = 0; recentMatched = []; results = []; waitingUntil = nil; bump() }

    func load(link text: String) {
        guard !isBusy else { phase = .failed(.busy); return }
        guard let link = SpotifyLink.parse(text) else { phase = .failed(.notSpotify); bump(); return }
        guard link.kind == .playlist || link.kind == .album else { phase = .failed(.notAList); bump(); return }
        phase = .reading; bump()
        let reader = self.reader
        task = Task { [weak self] in
            do { let l = try await reader(link); self?.finishReading([l]) }
            catch let e as ImportError { self?.phase = .failed(e); self?.bump() }
            catch { self?.phase = .failed(.unreadable); self?.bump() }
        }
    }

    func load(file data: Data, name: String) {
        guard !isBusy else { phase = .failed(.busy); return }
        do { finishReading(try SpotifyExportReader.lists(fromFile: data, name: name)) }
        catch let e as ImportError { phase = .failed(e); bump() }
        catch { phase = .failed(.unreadable); bump() }
    }

    private func finishReading(_ found: [ImportList]) {
        let usable = found.filter { !$0.tracks.isEmpty }
        guard !usable.isEmpty else { phase = .failed(.empty); bump(); return }
        lists = usable; selected = Set(usable.indices); phase = .pick; bump()
    }

    // MARK: matching

    func startMatching() {
        guard phase == .pick, !selected.isEmpty else { return }
        task = Task { [weak self] in await self?.runMatching() }
    }

    func cancel() { task?.cancel(); if isBusy { phase = .cancelled; bump() } }

    private func resolveSearcher() -> Searcher? {
        if let searcher { return searcher }
        guard let p = registry.activeMetadata else { return nil }
        return { q in try await p.searchTracks(q, page: nil).items }
    }

    private func runMatching() async {
        guard let search = resolveSearcher() else { phase = .failed(.network("Turn on a music source in Music settings first.")); bump(); return }
        phase = .matching; startedAt = Date(); rows = [:]; recentMatched = []; bump()
        var queue: [ImportSourceTrack] = [], seen = Set<String>()
        for i in selected.sorted() { for t in lists[i].tracks where seen.insert(t.key).inserted { queue.append(t) } }
        total = queue.count; done = 0
        var failures = 0, requests = 0
        for src in queue {
            if Task.isCancelled { phase = .cancelled; bump(); return }
            if let c = cache.lookup(src.key) { settle(row(src, c)); continue }
            switch await admit() {
            case .stop(let e): phase = .failed(e); bump(); return
            case .go: break
            }
            do {
                let found = try await search(ImportMatcher.searchQuery(for: src))
                failures = 0; requests += 1
                let ranked = ImportMatcher.rank(source: src, results: found)
                let tier = ImportMatcher.tier(ranked.first?.score ?? 0)
                let rec = ImportMatchRecord(key: src.key, tier: tier, pick: tier == .missing ? nil : ranked.first?.track,
                                            candidates: tier == .matched ? [] : ranked.map(\.track), manual: false, updatedAt: Date())
                cache.set(rec)
                settle(row(src, rec))
                await sleeper(ImportPacing.delay(afterRequest: requests))
            } catch MusicError.rateLimited(_) {
                var b = budget; b.trip(now: Date()); budget = b
                phase = .failed(.cooldown(until: b.cooldownUntil ?? Date().addingTimeInterval(3600))); bump(); return
            } catch is CancellationError { phase = .cancelled; bump(); return }
            catch {
                // A failed search is not an answer, so nothing is stored; three in a row stop the run.
                failures += 1
                if failures >= 3 { phase = .failed(.network((error as? MusicError)?.errorDescription ?? "The search failed.")); bump(); return }
                settle(ImportRow(key: src.key, source: src, tier: .missing, pick: nil, candidates: [], manual: false))
            }
        }
        phase = .review; bump()
    }

    private enum Admit { case go, stop(ImportError) }

    private func admit() async -> Admit {
        while true {
            var b = budget
            let a = b.admit(now: Date()); budget = b
            switch a {
            case .go: waitingUntil = nil; return .go
            case .cooldown(let until): return .stop(.cooldown(until: until))
            case .wait(let until):
                waitingUntil = until; bump()
                await sleeper(5)
                if Task.isCancelled { return .stop(.busy) }
            }
        }
    }

    private func row(_ src: ImportSourceTrack, _ r: ImportMatchRecord) -> ImportRow {
        ImportRow(key: src.key, source: src, tier: r.tier, pick: r.pick, candidates: r.candidates, manual: r.manual)
    }

    private func settle(_ r: ImportRow) {
        rows[r.key] = r; done += 1
        if r.tier == .matched { recentMatched = Array(([r] + recentMatched).prefix(5)) }
        bump()
    }

    // MARK: counts and review

    func count(_ t: ImportTier) -> Int { rows.values.filter { $0.tier == t }.count }
    func rows(in t: ImportTier) -> [ImportRow] { rows.values.filter { $0.tier == t }.sorted { $0.source.title.localizedCaseInsensitiveCompare($1.source.title) == .orderedAscending } }

    /// Minutes left, shown only after five songs are done.
    func minutesLeft(now: Date = Date()) -> Int? {
        guard done >= 5, let s = startedAt, total > done else { return nil }
        let per = now.timeIntervalSince(s) / Double(done)
        return max(1, Int((per * Double(total - done) / 60).rounded(.up)))
    }

    /// "Looks right": keeps the pick and remembers it as the person's own.
    func confirm(_ key: String) {
        guard var r = rows[key], let pick = r.pick else { return }
        r.tier = .matched; r.manual = true; rows[key] = r
        cache.set(ImportMatchRecord(key: key, tier: .matched, pick: pick, manual: true, updatedAt: Date())); bump()
    }

    /// "Change": picking a song marks the row matched and stores it as a manual pick.
    func choose(_ key: String, _ track: MusicTrack) {
        guard var r = rows[key] else { return }
        r.pick = track; r.tier = .matched; r.manual = true
        if !r.candidates.contains(where: { $0.uid == track.uid }) { r.candidates.insert(track, at: 0) }
        rows[key] = r
        cache.set(ImportMatchRecord(key: key, tier: .matched, pick: track, candidates: r.candidates, manual: true, updatedAt: Date())); bump()
    }

    /// "Leave out": the row becomes missing and stays out of the playlist.
    func leaveOut(_ key: String) {
        guard var r = rows[key] else { return }
        r.pick = nil; r.tier = .missing; r.manual = true; rows[key] = r
        cache.set(ImportMatchRecord(key: key, tier: .missing, pick: nil, candidates: r.candidates, manual: true, updatedAt: Date())); bump()
    }

    /// Searches the active source for a row, for the "Change" picker.
    func search(_ text: String) async -> [MusicTrack] {
        guard let s = resolveSearcher() else { return [] }
        return (try? await s(text)) ?? []
    }

    // MARK: creating

    static let playlistCap = 5_000

    /// Lists are written last to first so the library (newest on top) ends up in Spotify's order. A list over 5,000 songs is split into "Name", "Name (2)", ...
    func create(names: [Int: String] = [:], keepUpdated: Bool) {
        guard phase == .review else { return }
        phase = .creating; total = selected.count; done = 0; bump()
        var made: [ImportResult] = []
        for i in selected.sorted(by: >) {
            let list = lists[i]
            let name = (names[i]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? (list.kind == .liked ? String(localized: "Liked Songs") : list.name)
            var tracks: [MusicTrack] = [], have = Set<String>(), missing = 0, keys = Set<String>()
            for s in list.tracks where keys.insert(s.key).inserted {
                if let t = rows[s.key]?.pick, rows[s.key]?.tier != .missing { if have.insert(t.uid).inserted { tracks.append(t) } } else { missing += 1 }
            }
            let chunks = stride(from: 0, to: max(tracks.count, 1), by: Self.playlistCap).map { Array(tracks[$0..<min($0 + Self.playlistCap, tracks.count)]) }
            for (n, chunk) in chunks.enumerated() {
                let p = library.createPlaylist(name: n == 0 ? name : "\(name) (\(n + 1))", tracks: chunk)
                if n == 0, keepUpdated, let url = list.shareURL {
                    sources.set(SpotifySourceRecord(url: url, keys: list.tracks.map(\.key).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, auto: false, checked: Date()), for: p.id)
                }
                made.append(ImportResult(id: p.id, name: p.name, added: chunk.count, notFound: n == 0 ? missing : 0))
            }
            done += 1
        }
        results = made.reversed(); phase = .done; bump()
    }

    /// Tab separated "artist TAB title" lines for the songs that were not found.
    var missingText: String {
        rows.values.filter { $0.tier == .missing }.sorted { $0.source.title < $1.source.title }.map { ($0.source.artists.first ?? "") + "\t" + $0.source.title }.joined(separator: "\n")
    }

    // MARK: update from Spotify

    struct UpdateSummary: Equatable, Sendable { var added: Int; var removed: Int; var upToDate: Bool }

    /// Reads the link again, adds what is new, removes what left, and puts Spotify's songs back in Spotify's order. A truncated read is refused, since everything past
    /// 100 would look removed.
    func update(playlist id: UUID) async throws -> UpdateSummary {
        guard !isBusy else { throw ImportError.busy }
        guard let rec = sources.record(for: id), let link = SpotifyLink.parse(rec.url) else { throw ImportError.gone }
        guard let search = resolveSearcher() else { throw ImportError.network("Turn on a music source in Music settings first.") }
        guard library.playlist(id: id) != nil else { sources.forget(id); throw ImportError.gone }
        if let c = cooldownEnds { throw ImportError.cooldown(until: c) }
        let list = try await reader(link)
        if list.truncated { throw ImportError.spotifyChanged }
        var newKeys: [String] = [], seen = Set<String>(), bySrc: [String: ImportSourceTrack] = [:]
        for t in list.tracks where seen.insert(t.key).inserted { newKeys.append(t.key); bySrc[t.key] = t }
        var updated = rec; updated.checked = Date()
        if newKeys == rec.keys { sources.set(updated, for: id); return UpdateSummary(added: 0, removed: 0, upToDate: true) }
        var picks: [String: MusicTrack] = [:]
        var requests = 0
        for k in newKeys {
            guard let src = bySrc[k] else { continue }
            if let c = cache.lookup(k) { if c.tier != .missing, let p = c.pick { picks[k] = p }; continue }
            if case .stop(let e) = await admit() { throw e }
            let ranked = ImportMatcher.rank(source: src, results: (try? await search(ImportMatcher.searchQuery(for: src))) ?? [])
            let tier = ImportMatcher.tier(ranked.first?.score ?? 0)
            cache.set(ImportMatchRecord(key: k, tier: tier, pick: tier == .missing ? nil : ranked.first?.track, candidates: tier == .matched ? [] : ranked.map(\.track), updatedAt: Date()))
            if tier != .missing, let t = ranked.first?.track { picks[k] = t }
            requests += 1
            await sleeper(ImportPacing.delay(afterRequest: requests))
        }
        // Earlier keys that left Spotify map through the cache too.
        for k in rec.keys where picks[k] == nil { if let c = cache.lookup(k), let p = c.pick { picks[k] = p } }
        let current = library.playlist(id: id)?.tracks.map(\.uid) ?? []
        let plan = ImportUpdate.plan(previousKeys: rec.keys, newKeys: newKeys, currentUIDs: current, uid: { picks[$0]?.uid })
        let byUID = Dictionary(picks.values.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        if !plan.remove.isEmpty, let p = library.playlist(id: id) {
            library.remove(at: IndexSet(p.tracks.indices.filter { plan.remove.contains(p.tracks[$0].uid) }), from: id)
        }
        library.add(plan.add.compactMap { byUID[$0] }, to: id)
        if let p = library.playlist(id: id) {
            let now = p.tracks.map(\.uid)
            let target = ImportUpdate.order(current: now, spotify: newKeys.compactMap { picks[$0]?.uid })
            // Playlists never hold a song twice, so the ids are unique and the minimal move list applies directly.
            var working = now
            for m in ImportUpdate.minimalMoves(current: now, target: target) {
                guard let from = working.firstIndex(of: m.id) else { continue }
                let to = m.before.flatMap { working.firstIndex(of: $0) } ?? working.count
                library.move(from: IndexSet(integer: from), to: to, in: id)
                working = ImportUpdate.apply([m], to: working)
            }
        }
        updated.keys = newKeys
        sources.set(updated, for: id)
        return UpdateSummary(added: plan.add.count, removed: plan.remove.count, upToDate: false)
    }
}
