import Foundation
import CryptoKit
import Observation

// MARK: - The walk

/// One provider's turn in the walk. `takesSlot` is false for sources that should not delay the one after them (Community, local files).
struct MusicLyricsWalkEntry: Sendable {
    let id: String
    let takesSlot: Bool
    /// Started only when every source above it has answered without finding anything (Genius).
    var lazy: Bool = false
    let run: @Sendable () async throws -> MusicLyrics?

    init(id: String, takesSlot: Bool, lazy: Bool = false, run: @escaping @Sendable () async throws -> MusicLyrics?) {
        self.id = id; self.takesSlot = takesSlot; self.lazy = lazy; self.run = run
    }
}

/// What the walk reports about each source while it runs, for the source picker.
enum MusicLyricsWalkEvent: Sendable {
    case started, hit(MusicLyrics), none, error, cancelled
}

struct MusicLyricsWalkOutcome: Sendable {
    var lyrics: MusicLyrics?
    /// True when at least one provider ANSWERED (a hit, plain text, or a definitive "no"). All-errors means offline, not "no lyrics".
    var answered: Bool
    /// How many sources failed (as opposed to answering "no"). A "no lyrics" verdict is not trusted while any source errored.
    var errored: Int = 0
    /// Which sources said a definitive "no", and which failed.
    var noneIDs: Set<String> = []
    var errorIDs: Set<String> = []
}

/// Staggered concurrent walk. Provider i starts after i x stagger (a song with no synced lyrics anywhere no longer waits on every
/// provider in turn); answers are READ strictly in the person's order, and the first one that "settles" stops everything else.
enum MusicLyricsWalk {
    static let stagger = 0.3
    static let cap = 10.0

    /// Instrumental, or synced and (word-timed or word-by-word not preferred).
    static func settles(_ l: MusicLyrics, preferWords: Bool) -> Bool {
        if l.instrumental { return true }
        return l.isSynced && (l.isWordTimed || !preferWords)
    }

    /// Start slot per entry: a source that takes no slot starts together with the one after it.
    static func slots(takesSlot: [Bool]) -> [Int] {
        var out: [Int] = []
        var taken = 0
        for t in takesSlot { out.append(taken); if t { taken += 1 } }
        return out
    }

    static func run(_ entries: [MusicLyricsWalkEntry], preferWords: Bool, stagger: Double = MusicLyricsWalk.stagger,
                    cap: Double = MusicLyricsWalk.cap, progress: (@Sendable (String, MusicLyricsWalkEvent) -> Void)? = nil) async -> MusicLyricsWalkOutcome {
        guard !entries.isEmpty else { return MusicLyricsWalkOutcome(lyrics: nil, answered: false) }
        let slots = slots(takesSlot: entries.map(\.takesSlot))
        return await withTaskGroup(of: (Int, MusicLyricsAnswer).self) { group in
            var started = Set<Int>()
            func start(_ i: Int, _ g: inout TaskGroup<(Int, MusicLyricsAnswer)>) {
                started.insert(i)
                let e = entries[i]
                let delay = e.lazy ? 0 : Double(slots[i]) * stagger
                g.addTask {
                    if delay > 0 {
                        do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { progress?(e.id, .cancelled); return (i, .error("cancelled")) }
                    }
                    progress?(e.id, .started)
                    do {
                        let r = try await MusicLyricsIO.withTimeout(cap) { try await e.run() }
                        guard let r, let n = MusicLyricsNormalizer.normalize(r) else { progress?(e.id, .none); return (i, .none) }
                        progress?(e.id, .hit(n))
                        return (i, .hit(n))
                    } catch {
                        progress?(e.id, Task.isCancelled ? .cancelled : .error)
                        return (i, .error("\(error)"))
                    }
                }
            }
            for i in entries.indices where !entries[i].lazy { start(i, &group) }
            var arrived: [Int: MusicLyricsAnswer] = [:]
            var next = 0
            var firstSynced: MusicLyrics?, firstPlain: MusicLyrics?
            var answered = false
            var errored = 0
            var noneIDs = Set<String>(), errorIDs = Set<String>()
            func read(_ g: inout TaskGroup<(Int, MusicLyricsAnswer)>) -> MusicLyrics? {
                while next < entries.count {
                    if arrived[next] == nil {
                        guard entries[next].lazy, !started.contains(next) else { return nil }
                        if firstSynced != nil || firstPlain != nil { arrived[next] = .error("skipped"); continue }
                        start(next, &g)
                        return nil
                    }
                    guard let ans = arrived[next] else { return nil }
                    next += 1
                    switch ans {
                    case .hit(let l):
                        answered = true
                        if settles(l, preferWords: preferWords) { return l }
                        if l.isSynced { if firstSynced == nil { firstSynced = l } } else if firstPlain == nil { firstPlain = l }
                    case .none: answered = true
                    default: break
                    }
                }
                return nil
            }
            if let won = read(&group) { group.cancelAll(); return MusicLyricsWalkOutcome(lyrics: won, answered: true) }
            while let (i, a) = await group.next() {
                arrived[i] = a
                if case .error(let why) = a, why != "skipped", why != "cancelled" { errored += 1; errorIDs.insert(entries[i].id) }
                if case .none = a { noneIDs.insert(entries[i].id) }
                if let won = read(&group) {
                    group.cancelAll()
                    for k in entries.indices where !started.contains(k) { progress?(entries[k].id, .cancelled) }
                    return MusicLyricsWalkOutcome(lyrics: won, answered: true)
                }
                if next >= entries.count { break }
            }
            group.cancelAll()
            for k in entries.indices where !started.contains(k) { progress?(entries[k].id, .cancelled) }
            return MusicLyricsWalkOutcome(lyrics: firstSynced ?? firstPlain, answered: answered, errored: errored, noneIDs: noneIDs, errorIDs: errorIDs)
        }
    }
}

// MARK: - Cache rules

enum MusicLyricsCachePolicy {
    static let missTTL: TimeInterval = 6 * 3600
    /// Bumped when the rules for remembering "no lyrics" change; older "no lyrics" rows are dropped on read.
    static let schema = 4
    /// Sources whose "no" can be trusted as a real answer.
    static let reliable: Set<String> = [MusicLyricsSources.community, MusicLyricsSources.lrclib, MusicLyricsSources.lrcRed, MusicLyricsSources.unison,
                                        MusicLyricsSources.netease, MusicLyricsSources.qq]
    static let communityRecheck: TimeInterval = 24 * 3600
    static let otherRecheck: TimeInterval = 7 * 24 * 3600

    /// A hit is cached only if the length was known or the winner matches by id; fuzzy providers on an unknown length can land on another cut.
    static func shouldStoreHit(durationKnown: Bool, providerID: String) -> Bool {
        durationKnown || MusicLyricsSources.idMatchedProviders.contains(providerID)
    }
    /// A miss is cached only if somebody answered and no source merely failed: a timeout or an offline moment is not "no lyrics".
    static func shouldStoreMiss(answered: Bool, errored: Int = 0) -> Bool { answered && errored == 0 }

    /// A miss is remembered only when a trustworthy source really said "no" and none of the trustworthy ones failed.
    static func shouldStoreMiss(none: Set<String>, errors: Set<String>) -> Bool {
        !none.isDisjoint(with: reliable) && errors.isDisjoint(with: reliable)
    }

    /// Hits live forever; "no lyrics" verdicts expire after 24 hours.
    static func isFresh(hit: Bool, fetchedAt: Date, now: Date) -> Bool { hit || now.timeIntervalSince(fetchedAt) < missTTL }
}

enum MusicLyricsRevalidation {
    enum Plan: Equatable, Sendable {
        case none
        case refreshCommunity(filedID: String, revision: Int?)
        case askCommunity
    }

    /// What to do in the background with a cached hit. Never for searches, local files or ids that cannot be one.
    static func plan(lyrics: MusicLyrics, fetchedAt: Date, now: Date, request: MusicLyricsRequest, communityOn: Bool,
                     order: [MusicLyricsSources.Entry], preferWords: Bool) -> Plan {
        guard communityOn, !request.searched, !request.isLocal, let vid = request.videoID, MusicLyricsText.plausibleVideoID(vid) else { return .none }
        let age = now.timeIntervalSince(fetchedAt)
        if lyrics.providerID == MusicLyricsSources.community {
            return age > MusicLyricsCachePolicy.communityRecheck ? .refreshCommunity(filedID: lyrics.communityID ?? vid, revision: lyrics.revision) : .none
        }
        guard age > MusicLyricsCachePolicy.otherRecheck, !lyrics.pinned, lyrics.providerID != MusicLyricsSources.localOwn else { return .none }
        let communityRank = order.firstIndex { $0.id == MusicLyricsSources.community } ?? Int.max
        let ownRank = order.firstIndex { $0.id == lyrics.providerID } ?? Int.max
        if communityRank < ownRank || !MusicLyricsWalk.settles(lyrics, preferWords: preferWords) { return .askCommunity }
        return .none
    }
}

// MARK: - Disk store

struct MusicLyricsCacheEntry: Sendable, Equatable {
    var lyrics: MusicLyrics?
    var fetchedAt: Date
    /// Written by an older build: entities are re-decoded and flat lyrics re-asked on read.
    var legacy: Bool = false
}

private struct MusicLyricsCacheRecord: Codable {
    var lyrics: MusicLyrics?
    var fetchedAt: Double
    var schema: Int?
}

/// One JSON file per track, keyed by a hash of the track uid (plus one "alias" file keyed by the normalised title, artist and length, so the
/// same song met through another service is found too). The newest-used files stay: at most `maxFiles` files and `maxBytes` bytes, the least
/// recently used go first (pinned lyrics never). The folder is kept out of backups. All file work happens on this actor, so writes keep their order.
actor MusicLyricsDiskStore {
    static let maxFiles = 2_000
    static let maxBytes = 40 * 1024 * 1024
    private let directory: URL
    private var writes = 0

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var u = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    nonisolated static func fileURL(_ dir: URL, key: String) -> URL {
        let hash = MusicHash.sha256(key)
        return dir.appendingPathComponent(hash + ".json")
    }

    func read(key: String) -> MusicLyricsCacheEntry? {
        let url = Self.fileURL(directory, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Reading counts as use: the file moves to the front of the least-recently-used order.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return Self.decode(data, fileDate: date)
    }

    /// Only a hit is shared through an alias; a miss never is.
    func readAlias(key: String) -> MusicLyricsCacheEntry? {
        guard let e = read(key: key), e.lyrics != nil, !e.legacy else { return nil }
        return e
    }

    func writeAlias(key: String, lyrics: MusicLyrics) {
        var l = lyrics
        l.pinned = false
        write(key: key, lyrics: l, fetchedAt: Date())
    }

    nonisolated static func decode(_ data: Data, fileDate: Date? = nil) -> MusicLyricsCacheEntry? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["fetchedAt"] != nil,
           let r = try? JSONDecoder().decode(MusicLyricsCacheRecord.self, from: data) {
            // "No lyrics" rows from before the current rules may have been caused by failing sources: ignore them.
            if r.lyrics == nil, (r.schema ?? 0) < MusicLyricsCachePolicy.schema { return nil }
            return MusicLyricsCacheEntry(lyrics: r.lyrics, fetchedAt: Date(timeIntervalSince1970: r.fetchedAt))
        }
        guard let l = try? JSONDecoder().decode(MusicLyrics.self, from: data) else { return nil }
        return MusicLyricsCacheEntry(lyrics: l, fetchedAt: fileDate ?? Date(), legacy: true)
    }

    func write(key: String, lyrics: MusicLyrics?, fetchedAt: Date) {
        let rec = MusicLyricsCacheRecord(lyrics: lyrics, fetchedAt: fetchedAt.timeIntervalSince1970, schema: MusicLyricsCachePolicy.schema)
        guard let data = try? JSONEncoder().encode(rec) else { return }
        try? data.write(to: Self.fileURL(directory, key: key), options: .atomic)
        writes += 1
        if writes % 20 == 0 { trim() }
    }

    func delete(key: String) { try? FileManager.default.removeItem(at: Self.fileURL(directory, key: key)) }

    /// Removes the least recently used files until the folder is within its limits (a little under, so it is not trimmed on every write).
    /// Returns how many files were removed.
    @discardableResult
    func trim(maxFiles: Int = MusicLyricsDiskStore.maxFiles, maxBytes: Int = MusicLyricsDiskStore.maxBytes) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var rows: [(url: URL, date: Date, size: Int)] = files.filter { $0.pathExtension == "json" }.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return ($0, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        var total = rows.reduce(0) { $0 + $1.size }
        guard rows.count > maxFiles || total > maxBytes else { return 0 }
        rows.sort { $0.date < $1.date }
        var count = rows.count, removed = 0
        let targetFiles = maxFiles * 9 / 10, targetBytes = maxBytes * 9 / 10
        for r in rows where count > targetFiles || total > targetBytes {
            if let d = try? Data(contentsOf: r.url), Self.decode(d)?.lyrics?.pinned == true { continue }
            try? FileManager.default.removeItem(at: r.url)
            count -= 1; total -= r.size; removed += 1
        }
        return removed
    }

    /// How many files and bytes the folder holds (tests and the privacy page).
    func usage() -> (files: Int, bytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "json" }
        return (files.count, files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0) })
    }

    /// Removes every row, or every row except pinned lyrics (a settings change spares what the person picked by hand).
    func clear(keepPinned: Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if keepPinned, let d = try? Data(contentsOf: f), Self.decode(d)?.lyrics?.pinned == true { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// MARK: - Query for the source picker

/// What the picker asks with when the person types a title and artist: the album is dropped (it is another song), the length is kept.
struct MusicLyricsQuery: Hashable, Sendable {
    var title: String
    var artists: String
}

// MARK: - Terminal states

/// Why there are no lyrics to show.
enum MusicLyricsMiss: Equatable, Sendable {
    /// The sources answered and none has the song.
    case notFound
    /// A long compilation (mixtape, jukebox, non-stop, mashup, over eight minutes): lyrics for the whole file are not expected.
    case mix
    /// No source could be reached in time (offline, or every source failed or hung): worth trying again.
    case offline
}

/// What the lyrics panel shows. Owned by the service (keyed by track), so a view that is torn down and rebuilt cannot strand it.
enum MusicLyricsLoadState: Equatable, Sendable {
    case idle
    case loading
    case found(MusicLyrics)
    case none(MusicLyricsMiss)

    var isTerminal: Bool { if case .idle = self { return false }; if case .loading = self { return false }; return true }
}

/// The time limits of one lookup. `overall` is the hard cap for what the person waits; the walk gets `walkBudget` (leaving room for the
/// cache and the wrap-up), a likely mix only `mixBudget`.
struct MusicLyricsTiming: Sendable {
    var overall = 12.0
    var walkBudget = 10.5
    var mixBudget = 5.0
    var cap = MusicLyricsWalk.cap
    var stagger = MusicLyricsWalk.stagger
    /// The race rules (waves, the plain-text window, the soft answer time); see `MusicLyricsRaceConfig`.
    var race = MusicLyricsRaceConfig()
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
}

enum MusicLyricsMix {
    static let minutes = 8.0
    static let words = ["mixtape", "jukebox", "nonstop", "non-stop", "non stop", "mashup", "mash-up", "megamix", "full album"]

    static func isLikelyMix(title: String, durationSeconds: Double) -> Bool {
        if durationSeconds > minutes * 60 { return true }
        let t = title.lowercased()
        return words.contains { t.contains($0) }
    }
}

// MARK: - Service

/// Finds lyrics for a track. Cache first (hits forever, "no lyrics" for 24 hours), otherwise the staggered walk over the person's
/// ordered sources. Two screens asking for the same track at once share one lookup. Everything is best effort: a failure is never an error
/// the person sees.
@MainActor @Observable
final class MusicLyricsService {
    @ObservationIgnored private let registry: MusicRegistry
    @ObservationIgnored private let store: MusicLyricsDiskStore?
    @ObservationIgnored private let http: MusicHTTP
    @ObservationIgnored private var memory: [String: MusicLyricsCacheEntry] = [:]
    /// Which tracks the uid-keyed maps (memory, loadStates, sourceStates, missReasons, winningVariant, candidates) hold; the newest `uidMapLimit` stay.
    @ObservationIgnored private var recency = MusicRecency()
    nonisolated static let uidMapLimit = 300
    @ObservationIgnored private var inflight: [String: Task<MusicLyrics?, Never>] = [:]
    @ObservationIgnored private var revalidated: Set<String> = []
    @ObservationIgnored private var offsetTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var storingPick: Set<String> = []
    @ObservationIgnored private var candidates: [String: [String: MusicLyrics]] = [:]
    @ObservationIgnored private var pendingChoice: [String: String] = [:]
    /// The wording that found each track's lyrics, asked first next time and used by the source picker.
    @ObservationIgnored private let health = MusicLyricsHealth()
    @ObservationIgnored private var winningVariant: [String: MusicLyricsQueryVariant] = [:]
    /// What the sources taught us this session: their speed and failures, used to order, delay and time out sources.
    @ObservationIgnored let stats = MusicLyricsSourceStats()
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchOwned: Set<String> = []
    @ObservationIgnored private var warmedAt: Date?
    /// Tests switch the connection warm-up off (it talks to the real hosts).
    @ObservationIgnored var warmsConnections = true
    /// How many songs after the playing one are looked up ahead.
    nonisolated static let prefetchDepth = 2

    /// What each track's panel shows, owned here so it survives the view being torn down and rebuilt. Always ends in a terminal state.
    private(set) var loadStates: [String: MusicLyricsLoadState] = [:]
    /// Bumped when the cache is wiped, so an open panel asks again.
    private(set) var epoch = 0
    @ObservationIgnored private var loadTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var missReasons: [String: MusicLyricsMiss] = [:]
    @ObservationIgnored var timing = MusicLyricsTiming()

    /// Per track, per source: what the picker shows. Missing means "not fetched".
    private(set) var sourceStates: [String: [String: MusicLyricsSourceState]] = [:]

    /// Lyrics settings from the library; set by the hub. Changing the order, the switches or word-by-word clears the cache (pinned spared).
    private(set) var settings = MusicSettings()
    /// Bumps whenever a cached row changes behind the screen's back (revalidation, pick, nudge); open views ask again silently.
    private(set) var updateCount = 0
    private(set) var lastUpdatedUID: String?

    /// Supplies the YouTube video id for a track that is not itself a YouTube track (the matched recording's page).
    @ObservationIgnored var videoIDResolver: (@MainActor (MusicTrack) -> String?)?

    init(registry: MusicRegistry, cacheDirectory: URL? = nil, http: MusicHTTP = MusicHTTP()) {
        self.registry = registry
        self.http = http
        store = cacheDirectory.map { MusicLyricsDiskStore(directory: $0) }
    }

    // MARK: settings

    func apply(settings new: MusicSettings) {
        let old = settings
        settings = new
        let changed = old.lyricsSourceOrder != new.lyricsSourceOrder || old.lyricsSourceEnabled != new.lyricsSourceEnabled
            || old.preferWordByWord != new.preferWordByWord
        if changed { clearCache(keepPinned: true) }
    }

    /// The sources in the person's order with their switches, including plugin lyrics providers after the built-ins.
    var sourceEntries: [MusicLyricsSources.Entry] {
        let extra = registry.all.filter { $0 is any MusicLyricsProvider && !MusicLyricsSources.defaultOrder.contains($0.id) && $0.id != MusicLyricsSources.localOwn }.map(\.id)
        return MusicLyricsSources.resolve(order: settings.lyricsSourceOrder, enabled: settings.lyricsSourceEnabled, extra: extra)
    }

    // MARK: speed: prefetch and warm connections

    /// The key of the second cache row: the same song reached through another service (another id) shares its lyrics.
    nonisolated static func aliasKey(for track: MusicTrack) -> String {
        let title = MusicLyricsQueryBuilder.cleanTitle(track.title).title
        let artist = MusicLyricsQueryBuilder.cleanArtists(track.artists.map(\.name).joined(separator: ", "))
        let first = artist.split(separator: ",").first.map(String.init) ?? ""
        return "alias|" + MusicText.normalize(title.isEmpty ? track.title : title) + "|" + MusicText.normalize(first) + "|" + String(track.durationMs / 5000)
    }

    /// A song started: its lyrics are looked up at once (so the panel, the preview and the bar find them ready) and, when the connection is
    /// not metered, so are the next `prefetchDepth` songs of the queue, one after the other, after the playing song's own lookup is done.
    func trackStarted(_ track: MusicTrack, queue: [MusicTrack], metered: Bool) {
        warmConnections()
        ensureLoaded(track)
        let after = queue.firstIndex { $0.uid == track.uid }.map { Array(queue[($0 + 1)...]) } ?? []
        schedulePrefetch(Array(after.prefix(Self.prefetchDepth)), after: track, metered: metered)
    }

    /// Looks up the given songs quietly. Replaces the previous list: lookups for songs that left it are cancelled (unless a panel shows them).
    func schedulePrefetch(_ list: [MusicTrack], after current: MusicTrack?, metered: Bool) {
        prefetchTask?.cancel()
        for uid in prefetchOwned where loadTasks[uid] == nil { inflight[uid]?.cancel() }
        prefetchOwned = []
        guard !metered, !list.isEmpty else { return }
        let timing = self.timing
        let waitFor = current?.uid
        prefetchTask = Task { @MainActor [weak self] in
            // Idle first: the playing song's own lookup goes before any lookup ahead.
            var waited = 0.0
            while let self, let waitFor, self.loadTasks[waitFor] != nil, waited < 6, !Task.isCancelled {
                try? await timing.sleep(0.25); waited += 0.25
            }
            for t in list {
                guard !Task.isCancelled, let self else { return }
                if self.memory[t.uid].map({ MusicLyricsCachePolicy.isFresh(hit: $0.lyrics != nil, fetchedAt: $0.fetchedAt, now: Date()) }) == true { continue }
                self.prefetchOwned.insert(t.uid)
                _ = await MusicDeadline.orNil(seconds: timing.overall, sleep: timing.sleep) { await self.lyrics(for: t) }
                self.prefetchOwned.remove(t.uid)
            }
        }
    }

    /// Opens the connections of the two sources asked first (a cheap HEAD to their address), once in ten minutes, so the first lookup does not
    /// pay for the handshake.
    func warmConnections() {
        guard warmsConnections else { return }
        if let w = warmedAt, Date().timeIntervalSince(w) < 600 { return }
        warmedAt = Date()
        let on = Set(sourceEntries.filter { $0.enabled && registry.isEnabled($0.id) }.map(\.id))
        let origins: [(String, String)] = [(MusicLyricsSources.lrclib, "https://lrclib.net/"), (MusicLyricsSources.jioSaavn, "https://www.jiosaavn.com/")]
        let urls = origins.filter { on.contains($0.0) }.compactMap { URL(string: $0.1) }
        let http = self.http
        Task.detached(priority: .utility) {
            for u in urls { _ = try? await MusicLyricsIO.withTimeout(2.5) { try await http.send(url: u, method: "HEAD", query: [:], headers: [:], body: nil) } }
        }
    }

    // MARK: panel state

    func loadState(for track: MusicTrack) -> MusicLyricsLoadState { loadStates[track.uid] ?? .idle }

    /// Starts (or joins) the lookup for this track on the service, not on a view: it ends in `found` or `none` within `timing.overall`
    /// whatever the sources do, and nobody's cancellation can leave it at `loading`. A finished state is kept (a miss for the 6 hour TTL
    /// through the cache); `force` looks again.
    /// Older tracks leave every uid-keyed map together (never one that is loading); the disk cache is untouched, so a later open reads it back.
    private func trimMaps(touching uid: String) {
        recency.touch(uid)
        let busy = Set(loadTasks.keys).union(inflight.keys).union(prefetchOwned).union([uid])
        for old in recency.evict(limit: Self.uidMapLimit, keeping: busy) {
            memory[old] = nil; loadStates[old] = nil; sourceStates[old] = nil; missReasons[old] = nil; winningVariant[old] = nil; candidates[old] = nil
        }
    }

    func ensureLoaded(_ track: MusicTrack, force: Bool = false) {
        let uid = track.uid
        // A lookup that only timed out (.offline) is not a miss: showing the song again asks again.
        if !force, let st = loadStates[uid], st != .idle, st != .none(.offline) { recency.touch(uid); return }
        trimMaps(touching: uid)
        loadTasks[uid]?.task.cancel()
        loadStates[uid] = .loading
        let token = UUID()
        let timing = self.timing
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await MusicDeadline.orNil(seconds: timing.overall, sleep: timing.sleep) { await self.lyrics(for: track) }
            guard self.loadTasks[uid]?.token == token else { return }
            self.loadTasks[uid] = nil
            switch answer {
            case .some(.some(let l)) where !l.isEmpty: self.loadStates[uid] = .found(l)
            case .some: self.loadStates[uid] = .none(self.missReasons[uid] ?? .notFound)
            case .none:
                // The hard end came while a provisional answer (plain text, or the early "none") was on screen: that answer stays.
                if !(self.loadStates[uid]?.isTerminal ?? false) { self.loadStates[uid] = .none(.offline) }
            }
        }
        loadTasks[uid] = (token, task)
    }

    /// The person asked again: forget a remembered miss and look again.
    func searchAgain(_ track: MusicTrack) {
        let key = track.uid
        if memory[key]?.lyrics == nil { memory[key] = nil; if let store { Task { await store.delete(key: key) } } }
        missReasons[key] = nil
        ensureLoaded(track, force: true)
    }

    /// A background change (community revalidation, a pick, an offset, an editor save) touched `track`: re-reads its row and shows it when it differs from
    /// `shown`. `stillCurrent` is asked after the await so a song change in between never adopts the old song's lyrics for the new one.
    func refreshAfterUpdate(for track: MusicTrack, shown: MusicLyrics?, stillCurrent: () -> Bool) async {
        guard lastUpdatedUID == track.uid else { return }
        guard let fresh = await lyrics(for: track), fresh != shown, stillCurrent() else { return }
        adopt(fresh, for: track)
    }

    /// A pick, an edit or a background refresh changed the row: show it.
    func adopt(_ lyrics: MusicLyrics?, for track: MusicTrack) {
        if let l = lyrics, !l.isEmpty { loadStates[track.uid] = .found(l) } else { loadStates[track.uid] = .none(.notFound) }
    }

    // MARK: reading lyrics

    func lyrics(for track: MusicTrack) async -> MusicLyrics? {
        let key = track.uid
        let found: MusicLyrics?
        if let running = inflight[key] { found = await running.value } else {
            let task = Task<MusicLyrics?, Never> { await self.lookup(track) }
            inflight[key] = task
            found = await task.value
            // After a cache wipe a newer lookup may sit under this key already: only the one this call started is cleared.
            if inflight[key] == task { inflight[key] = nil }
        }
        guard let found else { return nil }
        return await Self.withReading(found)
    }

    private static func withReading(_ l: MusicLyrics) async -> MusicLyrics {
        await Task.detached(priority: .utility) { MusicRomanizer.apply(to: l) }.value
    }

    /// Forgets everything cached (privacy wipe).
    func clearCache() { clearCache(keepPinned: false) }

    func clearCache(keepPinned: Bool) {
        prefetchTask?.cancel()
        // A lookup that started with the old source order or switches must not store its answer as fresh.
        for (_, t) in inflight { t.cancel() }
        inflight = [:]
        for (_, t) in loadTasks { t.task.cancel() }
        loadTasks = [:]
        prefetchOwned = []
        candidates = [:]
        sourceStates = [:]
        missReasons = [:]
        pendingChoice = [:]; winningVariant = [:]    // a source picked or a query that won before the wipe must not apply to the next hit
        memory = memory.filter { keepPinned && $0.value.lyrics?.pinned == true }
        revalidated = []
        loadStates = loadStates.filter { if case .found(let l) = $0.value { return keepPinned && l.pinned }; return false }
        epoch += 1
        if let store { Task { await store.clear(keepPinned: keepPinned) } }
    }

    /// The one offset for every song (plus or minus 5 s); positive shows the lyrics later.
    var globalOffsetMs: Int64 { settings.lyricsOffsetMs }

    // MARK: picker states

    func sourceState(_ providerID: String, for track: MusicTrack) -> MusicLyricsSourceState { sourceStates[track.uid]?[providerID] ?? .notFetched }

    private func setState(_ s: MusicLyricsSourceState, _ id: String, _ uid: String) {
        var m = sourceStates[uid] ?? [:]
        m[id] = s
        sourceStates[uid] = m
    }

    private func handle(_ event: MusicLyricsWalkEvent, id: String, uid: String) {
        switch event {
        case .started: setState(.fetching, id, uid)
        case .hit(let l):
            setState(.found, id, uid)
            var c = candidates[uid] ?? [:]
            c[id] = l
            candidates[uid] = c
            if pendingChoice[uid] == id { pendingChoice[uid] = nil; Task { await self.applyCandidate(id, uid: uid) } }
        case .none: setState(.notFound, id, uid)
        case .error: setState(health.isDown(id) ? .unavailable : .notFetched, id, uid)
        case .cancelled: setState(.notFetched, id, uid)
        }
    }

    private func applyCandidate(_ id: String, uid: String) async {
        guard var l = candidates[uid]?[id] else { return }
        if l.sourceName.isEmpty { l.sourceName = MusicLyricsSources.name(id) }
        l.pinned = true
        l.offsetMs = memory[uid]?.lyrics?.offsetMs ?? 0
        await put(key: uid, lyrics: l, fetchedAt: Date())
        notifyUpdated(uid)
    }

    /// A tap on a source row. Found: use it now. Fetching: remember the choice and use it when it lands. Not fetched: ask that source alone
    /// and use the answer. Not found: nothing.
    func pick(providerID: String, for track: MusicTrack) async {
        let uid = track.uid
        switch sourceState(providerID, for: track) {
        case .found: await applyCandidate(providerID, uid: uid)
        case .fetching: pendingChoice[uid] = providerID
        case .notFound: break
        case .notFetched, .unavailable:
            health.reset(providerID)
            setState(.fetching, providerID, uid)
            switch await ask(providerID: providerID, for: track) {
            case .hit(let l):
                var c = candidates[uid] ?? [:]; c[providerID] = l; candidates[uid] = c
                setState(.found, providerID, uid)
                await applyCandidate(providerID, uid: uid)
            case .none: setState(.notFound, providerID, uid)
            case .error: setState(.notFetched, providerID, uid)
            }
        }
    }

    nonisolated static func lineIndex(in lines: [MusicLyricLine], at ms: Int64) -> Int? { MusicLyricsLookup.lineIndex(in: lines, at: ms) }

    nonisolated static func fileURL(_ dir: URL, key: String) -> URL { MusicLyricsDiskStore.fileURL(dir, key: key) }

    // MARK: per-song choices

    /// One provider's answer for this song, uncached, even if the provider is switched off (the picker can "Check" an off source).
    func ask(providerID: String, for track: MusicTrack, query: MusicLyricsQuery? = nil) async -> MusicLyricsAnswer {
        guard let provider = registry.provider(id: providerID) as? any MusicLyricsProvider else { return .error("unavailable") }
        var request = await makeRequest(track, needFacts: providerID == MusicLyricsSources.youtube || track.durationMs <= 0)
        if let q = query {
            request.title = q.title; request.artists = q.artists; request.album = nil; request.searched = true
        } else if !request.isLocal, let v = winningVariant[track.uid] ?? MusicLyricsQueryBuilder.variants(for: request).first {
            request = request.applying(v)
        }
        do {
            guard let l = try await Self.run(provider, request: request, track: track), let n = MusicLyricsNormalizer.normalize(l) else { return .none }
            return .hit(Self.stamped(n, provider: provider))
        } catch { return .error("\(error)") }
    }

    /// Pins this provider's lyrics for the song (a miss leaves the existing ones). Nil provider = Automatic: forget the row and walk again.
    @discardableResult
    func choose(providerID: String?, for track: MusicTrack, query: MusicLyricsQuery? = nil) async -> MusicLyrics? {
        let key = track.uid
        guard let providerID else {
            memory[key] = nil; offsetTasks[key]?.cancel()
            await store?.delete(key: key)
            notifyUpdated(key)
            return await lyrics(for: track)
        }
        guard case .hit(var l) = await ask(providerID: providerID, for: track, query: query) else { return memory[key]?.lyrics }
        storingPick.insert(key)
        defer { storingPick.remove(key) }
        l.pinned = true
        l.offsetMs = memory[key]?.lyrics?.offsetMs ?? 0
        await put(key: key, lyrics: l, fetchedAt: Date())
        notifyUpdated(key)
        return l
    }

    /// Nudges the timing of the song's lyrics (positive shows them later). Held in memory at once, written 400 ms after the last change,
    /// and pins the lyric. Ignored while a pick is being stored (its write would land after this one and undo it).
    func setOffset(_ ms: Int64, for track: MusicTrack) {
        let key = track.uid
        guard !storingPick.contains(key), var entry = memory[key], var l = entry.lyrics else { return }
        l.offsetMs = MusicLyricsLookup.clampOffset(ms)
        l.pinned = true
        entry.lyrics = l
        memory[key] = entry
        offsetTasks[key]?.cancel()
        let store = self.store, at = entry.fetchedAt
        offsetTasks[key] = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await store?.write(key: key, lyrics: l, fetchedAt: at)
        }
    }

    /// A lyrics file the person picked for this song. Pinned, so it survives settings changes.
    @discardableResult
    func importLyrics(from file: URL, for track: MusicTrack) async -> MusicLyrics? {
        guard let l = LocalLyricsProvider.parseFile(file) else { return nil }
        return await pinImported(l, for: track)
    }

    @discardableResult
    func importLyrics(text: String, for track: MusicTrack) async -> MusicLyrics? {
        guard let l = MusicLyricsParsers.lyrics(from: text, source: LocalLyricsProvider.name, provider: MusicLyricsSources.localOwn) else { return nil }
        return await pinImported(l, for: track)
    }

    private func pinImported(_ lyrics: MusicLyrics, for track: MusicTrack) async -> MusicLyrics {
        var l = lyrics
        l.pinned = true
        await put(key: track.uid, lyrics: l, fetchedAt: Date())
        notifyUpdated(track.uid)
        return l
    }

    // MARK: lookup

    private func lookup(_ track: MusicTrack) async -> MusicLyrics? {
        let key = track.uid
        let now = Date()
        var cached = memory[key]
        if cached == nil, let store, var e = await store.read(key: key) {
            if e.legacy, let l = e.lyrics {
                // Rows from before flat lyrics were demoted are asked again unless pinned.
                if l.pinned { e.lyrics = MusicLyricsNormalizer.repairLegacy(l) ?? l } else if let repaired = MusicLyricsNormalizer.repairLegacy(l), repaired.isSynced == l.isSynced {
                    e.lyrics = repaired
                } else { e.lyrics = nil; e.fetchedAt = .distantPast }
            }
            cached = e
            memory[key] = e
        }
        if cached == nil, let store, track.providerID != "local", let alias = await store.readAlias(key: Self.aliasKey(for: track)) {
            // The same song reached through another service (another id) is already here.
            cached = alias
            memory[key] = alias
        }
        // Lyrics saved before the language check, in another language's script than the song, are asked again (unless the person picked them).
        if let l = cached?.lyrics, !l.pinned {
            let locale = MusicLyricsLocale.detect(title: track.title, artists: track.artistLine, album: track.album?.title)
            if !MusicLyricsLanguageGuard.accepts(l, expected: MusicLyricsLanguageGuard.expected(track: track, locale: locale)) { cached = nil; memory[key] = nil }
        }
        if let e = cached, MusicLyricsCachePolicy.isFresh(hit: e.lyrics != nil, fetchedAt: e.fetchedAt, now: now) {
            if let l = e.lyrics { scheduleRevalidation(track, entry: MusicLyricsCacheEntry(lyrics: l, fetchedAt: e.fetchedAt)) }
            else { missReasons[key] = MusicLyricsMix.isLikelyMix(title: track.title, durationSeconds: Double(track.durationMs) / 1000) ? .mix : .notFound }
            return e.lyrics
        }
        return await walk(track)
    }

    private func walk(_ track: MusicTrack) async -> MusicLyrics? {
        let timing = self.timing
        let mix = MusicLyricsMix.isLikelyMix(title: track.title, durationSeconds: Double(track.durationMs) / 1000)
        let budget = mix ? timing.mixBudget : timing.walkBudget
        let uid = track.uid
        missReasons[uid] = nil
        // The facts (length, album, lyrics id) come from YouTube Music in the background; only a song with no length waits for them,
        // because the length is what tells one cut of a song from another.
        let plain = MusicLyricsRequest.make(track: track, videoID: videoIDResolver?(track))
        let enriched = Task { @MainActor [weak self] in await self?.enrich(plain) ?? plain }
        let base = plain.hasDuration || plain.isLocal ? plain : await enriched.value
        if base.isrc == nil, !base.isLocal { let copy = base; Task { @MainActor [weak self] in var r = copy; await self?.identifyRecording(&r) } }

        // Video titles and channel names become a few questions; they are asked side by side, not one round after the other.
        let variants = base.isLocal ? [] : MusicLyricsQueryBuilder.variants(for: base)
        // The raw title and the swapped reading are weak guesses (the film name alone finds the film's title song): they are not asked side by
        // side with the strong wordings, only when nothing else exists.
        let strong = variants.filter { $0.kind != .original }
        var reqs: [(MusicLyricsRequest, MusicLyricsQueryVariant?)] = (strong.isEmpty ? variants : strong).map { (base.applying($0), $0) }
        if reqs.isEmpty { reqs = [(base, nil)] }
        if let known = winningVariant[uid], let i = reqs.firstIndex(where: { $0.1 == known }) { reqs.insert(reqs.remove(at: i), at: 0) }
        trimMaps(touching: uid)
        sourceStates[uid] = [:]; candidates[uid] = [:]; pendingChoice[uid] = nil

        let jobs = raceJobs(requests: reqs.map(\.0), base: base, track: track, enriched: enriched)
        var cfg = timing.race
        let scale = min(1, budget / 10.5)
        cfg.preferWords = settings.preferWordByWord
        cfg.durationSeconds = base.durationSeconds
        cfg.sleep = timing.sleep
        cfg.budget = budget
        cfg.soft = min(cfg.soft, budget * 0.6)
        cfg.secondWaveAt *= scale; cfg.lastWaveAt *= scale; cfg.plainWindow *= scale; cfg.upgradeWindow *= scale
        let race = await MusicLyricsRace.run(jobs, config: cfg, stats: stats, progress: { [weak self] id, event in
            Task { @MainActor in self?.handle(event, id: id, uid: uid) }
        }, onProvisional: { [weak self] l in
            Task { @MainActor in await self?.showEarly(l, uid: uid) }
        }, onSoftMiss: { [weak self] in
            Task { @MainActor in self?.showEarlyMiss(uid: uid) }
        })
        if Task.isCancelled { return race.walk.lyrics }
        var outcome = race.walk
        // A mix is only given lyrics when a source matched it with timed lines; a plain-text guess for a compilation is not shown.
        if mix, let l = outcome.lyrics, !l.instrumental, !l.isSynced { outcome.lyrics = nil }
        let won = race.winnerVariant.flatMap { $0 < reqs.count ? reqs[$0] : nil }
        if var l = outcome.lyrics {
            if l.sourceName.isEmpty { l.sourceName = MusicLyricsSources.name(l.providerID) }
            if let v = won?.1 { winningVariant[uid] = v }
            if MusicLyricsCachePolicy.shouldStoreHit(durationKnown: base.hasDuration, providerID: l.providerID) {
                await put(key: uid, lyrics: l, fetchedAt: Date())
                await store?.writeAlias(key: Self.aliasKey(for: track), lyrics: l)
            } else { memory[uid] = MusicLyricsCacheEntry(lyrics: l, fetchedAt: Date()) }
            maybeHint(winner: l, request: won?.0 ?? base)
            return l
        }
        missReasons[uid] = mix ? .mix : (outcome.answered ? .notFound : .offline)
        if MusicLyricsCachePolicy.shouldStoreMiss(none: outcome.noneIDs, errors: outcome.errorIDs) { await put(key: uid, lyrics: nil, fetchedAt: Date()) }
        return nil
    }

    /// Plain text (or the early "none") shown while the race goes on looking for timed lyrics.
    private func showEarly(_ l: MusicLyrics, uid: String) async {
        guard loadTasks[uid] != nil else { return }
        let r = await Self.withReading(l)
        guard loadTasks[uid] != nil else { return }
        loadStates[uid] = .found(r)
    }

    private func showEarlyMiss(uid: String) {
        guard loadTasks[uid] != nil, loadStates[uid] == .loading else { return }
        loadStates[uid] = .none(missReasons[uid] ?? .notFound)
    }

    /// The jobs of one race: every enabled source in the plan's order and wave, one job per wording it is worth asking.
    private func raceJobs(requests: [MusicLyricsRequest], base: MusicLyricsRequest, track: MusicTrack, enriched: Task<MusicLyricsRequest, Never>) -> [MusicLyricsRaceJob] {
        var out: [MusicLyricsRaceJob] = []
        if base.isLocal {
            let local = LocalLyricsProvider()
            out.append(MusicLyricsRaceJob(id: local.info.id, wave: 0, timeout: 3) { try await local.lyrics(for: base) })
        }
        let ids = sourceEntries.filter { $0.enabled && registry.isEnabled($0.id) }.map(\.id)
        let locale = MusicLyricsLocale.detect(title: base.title, artists: base.artists, album: base.album)
        let expectedLanguage = MusicLyricsLanguageGuard.expected(track: track, locale: locale)
        for choice in MusicLyricsSourcePlan.plan(enabled: ids, locale: locale, stats: stats, cap: timing.cap) {
            let id = choice.id
            guard let p = registry.provider(id: id) as? any MusicLyricsProvider else { continue }
            if let rp = p as? any MusicLyricsRequestProvider, !rp.isAvailable { continue }
            if health.isDown(id) { setState(.unavailable, id, track.uid); continue }
            let health = self.health
            for v in 0..<max(1, min(choice.variants, requests.count)) {
                let request = requests[v]
                out.append(MusicLyricsRaceJob(id: id, variant: v, wave: choice.wave, timeout: choice.timeout) {
                    let probe = MusicLyricsProbe()
                    do {
                        var asked = request
                        if id == MusicLyricsSources.youtube { asked.youTubeBrowseID = await enriched.value.youTubeBrowseID }
                        let found = try await MusicLyricsProbe.$current.withValue(probe) { try await Self.run(p, request: asked, track: track) }
                        if found == nil, probe.didFail { throw MusicError.network("source unavailable") }
                        await MainActor.run { health.recordAnswer(id) }
                        // A lyric in another language's script is turned away whatever source it came from (a Hindi dub's words under a Telugu song).
                        if let f = found, !MusicLyricsLanguageGuard.accepts(f, expected: expectedLanguage) {
                            MusicDebugLog.log("lyrics", "turned away \(id) lyrics for \(track.title): wrong script for expected \(expectedLanguage?.rawValue ?? "-")")
                            return nil
                        }
                        return found.map { Self.stamped($0, provider: p) }
                    } catch {
                        if !(error is CancellationError) { await MainActor.run { health.recordFailure(id) } }
                        throw error
                    }
                })
            }
        }
        return out
    }

    private nonisolated static func run(_ p: any MusicLyricsProvider, request: MusicLyricsRequest, track: MusicTrack) async throws -> MusicLyrics? {
        if let rp = p as? any MusicLyricsRequestProvider { return try await rp.lyrics(for: request) }
        return try await p.lyrics(for: track)
    }

    private nonisolated static func stamped(_ l: MusicLyrics, provider: any MusicLyricsProvider) -> MusicLyrics {
        var x = l
        if x.providerID.isEmpty { x.providerID = provider.info.id }
        if x.sourceName.isEmpty { x.sourceName = provider.info.name }
        return x
    }

    /// Fills what the queue item lacks (length, album, lyrics browse id) from YouTube Music's "next" call; the request as it was when that fails.
    private func enrich(_ request: MusicLyricsRequest) async -> MusicLyricsRequest {
        var r = request
        guard !r.isLocal, let vid = r.videoID, let source = MusicLyricsBuiltIns.youTubeLink.source else { return r }
        do {
            let f = try await MusicLyricsIO.withTimeout(1.5) { try await source.facts(videoID: vid) }
            if !r.hasDuration, let d = f.durationSeconds, d > 0 { r.durationSeconds = d }
            if r.album == nil, let a = f.album, !a.isEmpty { r.album = a }
            r.youTubeBrowseID = f.lyricsBrowseID
        } catch { r.factsFailed = true }
        return r
    }

    private func makeRequest(_ track: MusicTrack, needFacts: Bool) async -> MusicLyricsRequest {
        let r = MusicLyricsRequest.make(track: track, videoID: videoIDResolver?(track))
        return needFacts ? await enrich(r) : r
    }

    /// The recording step: when the track has no recording code, BiniLyrics is asked once by name (2.5 s at most) and the code it names is
    /// remembered for the video id (100 entries, memory only), so lrc.red and LyricsPlus can match the recording itself.
    private func identifyRecording(_ request: inout MusicLyricsRequest) async {
        if request.isrc != nil { return }
        if let vid = request.videoID, let known = await MusicRecordingMemory.shared.get(vid) {
            request.isrc = known.isrc; request.identified = known
            return
        }
        let binis = MusicLyricsSources.bini
        guard !request.isLocal, sourceEntries.contains(where: { $0.id == binis && $0.enabled }), registry.isEnabled(binis),
              let p = registry.provider(id: binis) as? BiniLyricsProvider, let found = await p.identify(request) else { return }
        request.isrc = found.isrc; request.identified = found
        if let vid = request.videoID { await MusicRecordingMemory.shared.set(vid, found) }
    }

    private func put(key: String, lyrics: MusicLyrics?, fetchedAt: Date) async {
        memory[key] = MusicLyricsCacheEntry(lyrics: lyrics, fetchedAt: fetchedAt)
        await store?.write(key: key, lyrics: lyrics, fetchedAt: fetchedAt)
    }

    private func notifyUpdated(_ key: String) { lastUpdatedUID = key; updateCount += 1 }

    // MARK: hint and revalidation

    private var communityOn: Bool { sourceEntries.contains { $0.id == MusicLyricsSources.community && $0.enabled } && registry.isEnabled(MusicLyricsSources.community) }

    private func maybeHint(winner: MusicLyrics, request: MusicLyricsRequest) {
        guard CommunityLyricsProvider.shouldHint(winner: winner, request: request, communityOn: communityOn) else { return }
        let provider = CommunityLyricsProvider(http: http)
        let id = winner.providerID
        Task.detached(priority: .background) { await provider.sendHint(request: request, provider: id) }
    }

    private func scheduleRevalidation(_ track: MusicTrack, entry: MusicLyricsCacheEntry) {
        let key = track.uid
        guard let cached = entry.lyrics, !revalidated.contains(key) else { return }
        let request = MusicLyricsRequest.make(track: track, videoID: videoIDResolver?(track))
        let plan = MusicLyricsRevalidation.plan(lyrics: cached, fetchedAt: entry.fetchedAt, now: Date(), request: request, communityOn: communityOn,
                                                order: sourceEntries.filter(\.enabled), preferWords: settings.preferWordByWord)
        guard plan != .none else { return }
        revalidated.insert(key)
        let provider = CommunityLyricsProvider(http: http)
        Task { await self.revalidate(key: key, request: request, cached: cached, plan: plan, provider: provider) }
    }

    private func revalidate(key: String, request: MusicLyricsRequest, cached: MusicLyrics, plan: MusicLyricsRevalidation.Plan, provider: CommunityLyricsProvider) async {
        // The stamp is written BEFORE the request, so a song is asked at most once a day however often it is opened.
        let now = Date()
        switch plan {
        case .none: return
        case .refreshCommunity(let filedID, let revision):
            await put(key: key, lyrics: cached, fetchedAt: now)
            guard let result = try? await provider.fetch(request, filedID: filedID, revision: revision) else { return }
            switch result {
            case .notModified: return
            case .none:
                // Taken down: the next look walks the list again (the pin goes with it).
                guard current(key, matches: cached) else { return }
                memory[key] = nil
                await store?.delete(key: key)
                notifyUpdated(key)
            case .lyrics(var fresh):
                guard current(key, matches: cached), fresh.synced != cached.synced || fresh.authors != cached.authors else { return }
                fresh.pinned = cached.pinned
                fresh.offsetMs = fresh.synced == cached.synced ? cached.offsetMs : 0
                await put(key: key, lyrics: fresh, fetchedAt: now)
                notifyUpdated(key)
            }
        case .askCommunity:
            await put(key: key, lyrics: cached, fetchedAt: now)
            do {
                if case .lyrics(let fresh) = try await provider.fetch(request, filedID: nil, revision: nil), current(key, matches: cached) {
                    await put(key: key, lyrics: fresh, fetchedAt: now)
                    notifyUpdated(key)
                }
            } catch {
                // Offline is not "Community does not have it": look again in about a day.
                let retry = now.addingTimeInterval(-MusicLyricsCachePolicy.otherRecheck + 24 * 3600)
                if current(key, matches: cached) { await put(key: key, lyrics: cached, fetchedAt: retry) }
            }
        }
    }

    /// A late answer is dropped if the row changed meanwhile (pinned, nudged, replaced, cleared).
    private func current(_ key: String, matches cached: MusicLyrics) -> Bool {
        guard let now = memory[key]?.lyrics else { return false }
        return now.synced == cached.synced && now.plain == cached.plain && now.pinned == cached.pinned && now.offsetMs == cached.offsetMs
    }
}
