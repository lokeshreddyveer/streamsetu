import Foundation
import Observation

// The chart playability pipeline. Any ranked list (a chart playlist, a trending or featured section, a "new releases" page) is turned into rows that are
// each either playable (with the exact track and source that will play) or honestly unavailable. Nothing here starts playback: a copy is accepted by the
// catalogue matcher's rules and then checked by an opening read only (the stream verifier, or the resolver through `verifyOwn` / `verifyTwin`).

// MARK: version and reason

/// Which version of a chart song was chosen, in the order the pipeline prefers them.
enum MusicChartVersion: String, Codable, Sendable, Equatable, CaseIterable {
    /// The chart's own row, already playable and verified.
    case own
    /// The official audio or the auto-generated Topic upload.
    case officialAudio
    /// The song row of the artist's release (a streaming service's album track).
    case albumTrack
    case lyricVideo
    case officialVideo
    case other

    var preference: Int {
        switch self {
        case .own: 0
        case .officialAudio: 1
        case .albumTrack: 2
        case .lyricVideo: 3
        case .officialVideo: 4
        case .other: 5
        }
    }
}

/// Why a chart song has no playable copy, in words a person can read.
enum MusicChartReason: String, Codable, Sendable, Equatable {
    case noPlayableCopy, blocked, held, offline, catalogueOff, timedOut, failedToPlay

    var text: String {
        switch self {
        case .noPlayableCopy: Localized.string("No playable copy of this song was found.")
        case .blocked: Localized.string("This song is on your Never play list.")
        case .held: Localized.string("Music is locked right now.")
        case .offline: Localized.string("You are offline.")
        case .catalogueOff: Localized.string("Catalogue matching is off, so only songs this source plays itself are shown.")
        case .timedOut: Localized.string("This song took too long to check. Tap it to try again.")
        case .failedToPlay: Localized.string("This copy did not play. Tap the song to look for another.")
        }
    }
}

enum MusicChartRowState: Equatable, Sendable {
    case pending, resolving, playable
    case unavailable(MusicChartReason)
}

/// What a chart row shows besides the song itself.
struct MusicChartRowStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case resolving, ready, unavailable }
    var rank: Int
    var phase: Phase
    /// "Audio version" or "Lyric video", only when the chosen copy differs materially from the chart's row.
    var note: String?
    /// The plain reason, for a tooltip, when the song is unavailable.
    var reason: String?
    /// How many copies of this song the chart listed (video, lyric video, audio); 1 when only one.
    var versions = 1
}

struct MusicChartEntry: Identifiable, Equatable, Sendable {
    /// 1-based position in the chart, kept when unavailable rows are hidden.
    let rank: Int
    let original: MusicTrack
    var state: MusicChartRowState = .pending
    /// The playable track carrying the chart's own title and artists (see `MusicChartResolver.carry`).
    var resolved: MusicTrack?
    var version: MusicChartVersion?
    /// How long the last lookup took, in milliseconds.
    var elapsedMs = 0
    /// The other copies of this song from the same chart (the same song as another video id); `original` is the preferred one.
    var alternates: [MusicTrack] = []
    var versionCount: Int { 1 + alternates.count }

    var id: String { "\(rank)|" + original.uid }
    var isFinal: Bool { if case .pending = state { return false }; if case .resolving = state { return false }; return true }
    var isPlayable: Bool { state == .playable && resolved != nil }
    /// The row as drawn and played: the resolved track once there is one.
    var shown: MusicTrack { resolved ?? original }
    var isUnavailable: Bool { if case .unavailable = state { return true }; return false }

    var status: MusicChartRowStatus {
        switch state {
        case .pending, .resolving: return MusicChartRowStatus(rank: rank, phase: .resolving, note: nil, reason: nil, versions: versionCount)
        case .playable: return MusicChartRowStatus(rank: rank, phase: .ready, note: MusicChartVersionRules.note(version, original: original), reason: nil, versions: versionCount)
        case .unavailable(let r): return MusicChartRowStatus(rank: rank, phase: .unavailable, note: nil, reason: r.text, versions: versionCount)
        }
    }
}

struct MusicChartOutcome: Sendable, Equatable {
    var track: MusicTrack?
    var version: MusicChartVersion?
    var reason: MusicChartReason?
    var isPlayable: Bool { track != nil }
    /// A definite answer worth remembering for the day; a timeout, a lock or being offline is not.
    var cacheable: Bool { track != nil || reason == .noPlayableCopy }
}

// MARK: pure rules

enum MusicChartVersionRules {
    private static func has(_ padded: String, _ words: [String]) -> Bool { words.contains { padded.contains(" " + $0 + " ") } }

    /// What kind of upload or row a matched copy is.
    static func classify(_ twin: MusicCanonicalTwin) -> MusicChartVersion {
        let padded = " " + MusicText.normalize(twin.title) + " "
        if MusicTextMatch.isTopicChannel(twin.artist) { return .officialAudio }
        if has(padded, ["lyric video", "lyrical video", "lyrical", "lyrics", "lyric"]) { return .lyricVideo }
        if has(padded, ["official audio", "full audio", "audio song", "audio"]) { return .officialAudio }
        if has(padded, ["official video", "official music video", "music video", "video song", "full video", "video"]) { return .officialVideo }
        if let a = twin.album, !a.trimmingCharacters(in: .whitespaces).isEmpty { return .albumTrack }
        // A plain-titled row from the YouTube Music song search is the release's song row even when the reply names no album.
        if twin.providerID == "youtube-music" || twin.providerID == "ytmusic" { return .albumTrack }
        return .other
    }

    /// Accepted copies in the order they should be tried: close to the best score first by version preference, then by score; weaker ones last.
    static func ordered(_ twins: [MusicCanonicalTwin], window: Float = 0.2) -> [(twin: MusicCanonicalTwin, version: MusicChartVersion)] {
        guard let top = twins.map(\.score).max() else { return [] }
        let tagged = twins.map { ($0, classify($0)) }
        let near = tagged.filter { $0.0.score >= top - window }.sorted {
            $0.1.preference != $1.1.preference ? $0.1.preference < $1.1.preference : $0.0.score > $1.0.score
        }
        let rest = tagged.filter { $0.0.score < top - window }.sorted { $0.0.score > $1.0.score }
        return (near + rest).map { (twin: $0.0, version: $0.1) }
    }

    /// The small note under a title, only when the copy that plays differs materially from what the chart listed.
    static func note(_ v: MusicChartVersion?, original: MusicTrack) -> String? {
        guard let v else { return nil }
        let wasVideo = original.isVideo == true || MusicTwinRules.standard.youTubeFamily.contains(original.providerID)
        switch v {
        case .own, .albumTrack: return nil
        case .officialAudio: return wasVideo ? Localized.string("Audio version") : nil
        case .lyricVideo: return Localized.string("Lyric video")
        case .officialVideo: return wasVideo ? nil : Localized.string("Official video")
        case .other: return Localized.string("Other version")
        }
    }

    /// The chart's own words (title, artists, album, cover, rank signals) on the playable copy's identity (provider, id, streams), so Play uses it at once.
    static func carry(_ original: MusicTrack, playable p: MusicTrack) -> MusicTrack {
        if p.uid == original.uid && p.directStreams == original.directStreams { return original }
        var t = p
        t.title = original.title
        if !original.artists.isEmpty { t.artists = original.artists }
        t.album = original.album ?? p.album
        t.thumbnails = original.thumbnails.isEmpty ? p.thumbnails : original.thumbnails
        // The copy's own running time is kept: the stream check compares the file with it.
        if t.durationMs <= 0 { t.durationMs = original.durationMs }
        t.explicit = original.explicit
        t.popularity = original.popularity
        t.isrc = original.isrc ?? p.isrc
        return t
    }
}

/// Which lists are charts. A discovery source's lists always are; elsewhere the list's name decides.
enum MusicChartRules {
    private static let words: Set<String> = ["top", "chart", "charts", "trending", "viral", "billboard"]   // not "hits", "hot" or "popular": ordinary playlists carry those words

    static func isChart(title: String, providerID: String) -> Bool {
        if providerID.hasPrefix("discover-") { return true }
        let n = MusicText.normalize(title)
        if n.contains("new releases") || n.contains("new music") { return true }
        return !Set(n.split(separator: " ").map(String.init)).isDisjoint(with: words)
    }

}

// MARK: dependencies

/// Everything the pipeline asks of the rest of the app, as closures so tests supply fakes and the app supplies the real thing.
struct MusicChartDependencies: Sendable {
    var gated: @Sendable () async -> Bool = { false }
    var blacklisted: @Sendable (MusicTrack) async -> Bool = { _ in false }
    var online: @Sendable () async -> Bool = { true }
    /// False on a metered link or while the app is inactive: only rows in view are resolved then.
    var backgroundAllowed: @Sendable () async -> Bool = { true }
    var catalogueEnabled: @Sendable () async -> Bool = { true }
    /// Whether a source can play its own songs (an audio source in the registry).
    var providesAudio: @Sendable (String) async -> Bool = { _ in false }
    /// Opening read of the row's own stream; never plays.
    var verifyOwn: @Sendable (MusicTrack) async -> Bool = { _ in true }
    /// The catalogue matcher's answer: the song with its verified copies (cached 30 days, a miss for a day).
    var twin: @Sendable (MusicTrack) async -> MusicCanonicalTrack? = { _ in nil }
    var verifyTwin: @Sendable (MusicTrack) async -> Bool = { _ in true }
    /// Warms the first window of the top rows (the player's pre-resolver; read only).
    var prewarm: @Sendable ([MusicTrack]) async -> Void = { _ in }

    /// The app-wide defaults built on the installed matcher: its twin search, and a real stream check for rows that carry their own streams.
    static func standard(runtime: MusicCatalogRuntime = .shared) -> MusicChartDependencies {
        var d = MusicChartDependencies()
        d.catalogueEnabled = { runtime.isEnabled }
        d.twin = { t in await runtime.matcher?.twin(for: t) }
        d.providesAudio = { id in
            guard let m = runtime.matcher else { return false }
            return await m.environmentAudio().contains { $0.id == id }
        }
        d.verifyOwn = { t in
            guard let direct = t.directStreams?.first(where: { $0.expiresAt.map { $0 > Date() } ?? true }) else { return true }
            guard let reader = MusicStreamResolver.defaultVerifier else { return true }
            return await MusicStreamVerifier.verify(direct, catalogueMs: t.durationMs, reader: reader).isOK
        }
        return d
    }
}

struct MusicChartConfig: Sendable {
    var concurrency = 3
    /// Per row, all lookups together.
    var itemBudget: TimeInterval = 14
    /// Rows past the last one in view that are resolved first.
    var windowAhead = 10
    var prewarmCount = 3
    /// Rows fed to a running queue in one go.
    var feedBatch = 3
    var feedLookahead = 6
}

// MARK: engine (one song)

struct MusicChartEngine: Sendable {
    var deps: MusicChartDependencies
    var itemBudget: TimeInterval = 14

    func resolve(_ t: MusicTrack, avoid: Set<String> = []) async -> MusicChartOutcome {
        let r = await Self.race(seconds: itemBudget) { await self.attempt(t, avoid: avoid) }
        return r ?? MusicChartOutcome(reason: .timedOut)
    }

    private func attempt(_ t: MusicTrack, avoid: Set<String>) async -> MusicChartOutcome {
        if await deps.gated() { return MusicChartOutcome(reason: .held) }
        if await deps.blacklisted(t) { return MusicChartOutcome(reason: .blocked) }
        if Task.isCancelled { return MusicChartOutcome(reason: .timedOut) }
        let catalogue = await deps.catalogueEnabled()
        let ownCapable = !(t.directStreams ?? []).isEmpty ? true : await deps.providesAudio(t.providerID)
        // 1. The source's own track, when it plays and checks out (a YouTube chart video is such a row).
        if ownCapable, !avoid.contains(t.uid) {
            if await deps.verifyOwn(t) { return MusicChartOutcome(track: t, version: .own) }
            // 2. A video row's named audio twin.
            if let audio = MusicOfficialAudio.counterpart(of: t), !avoid.contains(audio.uid), await deps.verifyOwn(audio) {
                return MusicChartOutcome(track: MusicChartVersionRules.carry(t, playable: audio), version: .officialAudio)
            }
        }
        if !(await deps.online()) { return MusicChartOutcome(reason: .offline) }
        guard catalogue else { return MusicChartOutcome(reason: .catalogueOff) }
        if Task.isCancelled { return MusicChartOutcome(reason: .timedOut) }
        // 3. The matcher's verified copies: official audio or Topic, the album track, a lyric video, an official video, then the rest.
        guard let canon = await deps.twin(t) else { return MusicChartOutcome(reason: .noPlayableCopy) }
        for (twin, version) in MusicChartVersionRules.ordered(canon.twins) {
            if Task.isCancelled { return MusicChartOutcome(reason: .timedOut) }
            if avoid.contains(twin.uid) { continue }
            var one = canon
            one.twins = [twin]
            let candidate = MusicCatalogMatcher.playableTrack(from: one, catalogueRow: t)
            if await deps.verifyTwin(candidate) {
                return MusicChartOutcome(track: MusicChartVersionRules.carry(t, playable: candidate), version: version)
            }
        }
        return MusicChartOutcome(reason: .noPlayableCopy)
    }

    /// Waits for the work, never longer than `seconds`; nil when time ran out.
    static func race<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: chart cache

/// The chart-level result cache: per chart and calendar day, what each song resolved to, so reopening a chart is instant. Song matches themselves
/// live in the canonical store (30 days, a miss for a day); this only remembers which copy a chart row uses today.
final class MusicChartCache: @unchecked Sendable {
    struct Item: Codable, Sendable, Equatable {
        var track: MusicTrack?
        var version: MusicChartVersion?
        var reason: MusicChartReason?
    }
    struct Chart: Codable, Sendable { var key: String; var savedAt: Date; var items: [String: Item] }

    static let maxCharts = 40
    static let fileName = "ChartResults.json"
    static let shared = MusicChartCache(file: MusicStorage.root.appendingPathComponent("Catalogue", isDirectory: true).appendingPathComponent(fileName))

    private let lock = NSLock()
    private let file: URL
    private let now: @Sendable () -> Date
    private var charts: [String: Chart] = [:]
    private var loaded = false
    private var dirty = false

    init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) { self.file = file; self.now = now }

    func key(_ chartID: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return chartID + "|" + f.string(from: now())
    }

    func items(chartID: String) -> [String: Item] {
        lock.withLock { ensureLoaded(); return charts[key(chartID)]?.items ?? [:] }
    }

    func put(chartID: String, uid: String, _ item: Item) {
        lock.withLock {
            ensureLoaded()
            let k = key(chartID)
            var c = charts[k] ?? Chart(key: k, savedAt: now(), items: [:])
            c.items[uid] = item
            c.savedAt = now()
            charts[k] = c
            dirty = true
            if charts.count > Self.maxCharts {
                for old in charts.values.sorted(by: { $0.savedAt < $1.savedAt }).prefix(charts.count - Self.maxCharts) { charts[old.key] = nil }
            }
        }
    }

    func remove(chartID: String, uid: String) {
        lock.withLock {
            ensureLoaded()
            let k = key(chartID)
            guard charts[k]?.items[uid] != nil else { return }
            charts[k]?.items[uid] = nil
            dirty = true
        }
    }

    func clear() {
        lock.withLock { charts = [:]; loaded = true; dirty = false }
        try? FileManager.default.removeItem(at: file)
    }

    func flush() {
        let data: Data? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
            return try? enc.encode(Array(charts.values))
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let list = try? dec.decode([Chart].self, from: data) else { return }
        let cutoff = now().addingTimeInterval(-3 * 24 * 3600)
        for c in list where c.savedAt > cutoff { charts[c.key] = c }
    }
}

// MARK: the shared resolver

/// One per app, owned by `MusicCatalogRuntime`. Hands out one session per chart and resolves plain lists for shelves.
@MainActor
final class MusicChartResolver {
    var config = MusicChartConfig()
    private(set) var dependencies: MusicChartDependencies?
    let cache: MusicChartCache
    private var sessions: [String: MusicChartSession] = [:]
    private var order: [String] = []

    nonisolated init(cache: MusicChartCache = .shared) { self.cache = cache }

    /// The app wires the gate, the Never play list, the network rules and the stream checks in once the hub exists.
    func configure(_ d: MusicChartDependencies) { dependencies = d }

    var resolvedDependencies: MusicChartDependencies { dependencies ?? .standard() }

    func session(chartID: String, tracks: [MusicTrack]) -> MusicChartSession {
        if let s = sessions[chartID] { s.update(tracks: tracks); return s }
        let s = MusicChartSession(chartID: chartID, tracks: tracks, deps: resolvedDependencies, cache: cache, config: config)
        sessions[chartID] = s
        order.removeAll { $0 == chartID }
        order.append(chartID)
        while order.count > 6 { let old = order.removeFirst(); sessions[old]?.cancel(); sessions[old] = nil }
        return s
    }

    /// The dependencies, with the twin search taken from `matcher` when a caller (a test, a shelf of its own matcher) brings one.
    func dependencies(using matcher: MusicCatalogMatcher?) -> MusicChartDependencies {
        var d = resolvedDependencies
        guard let m = matcher else { return d }
        d.twin = { await m.twin(for: $0) }
        d.catalogueEnabled = { true }
        return d
    }

    /// For a shelf or a seed list: every row's entry after at most `budget` seconds. Rows still resolving then are left pending.
    /// With a `matcher` of the caller's own nothing is remembered between calls.
    func resolveList(_ tracks: [MusicTrack], chartID: String? = nil, matcher: MusicCatalogMatcher? = nil, budget: TimeInterval = 8) async -> [MusicChartEntry] {
        let remember = chartID != nil && matcher == nil
        let s = MusicChartSession(chartID: chartID ?? "shelf", tracks: tracks, deps: dependencies(using: matcher), cache: remember ? cache : nil, config: config)
        s.eager = true
        s.start()
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline, s.isResolving { try? await Task.sleep(nanoseconds: 60_000_000) }
        s.cancel()
        return s.entries
    }

    /// The playable form of each row, in the list's order; rows without a verified copy are left out.
    func playableShelf(_ tracks: [MusicTrack], chartID: String? = nil, matcher: MusicCatalogMatcher? = nil, budget: TimeInterval = 8) async -> [MusicTrack] {
        await resolveList(tracks, chartID: chartID, matcher: matcher, budget: budget).compactMap { $0.isPlayable ? $0.resolved : nil }
    }

    /// Browse sections: the songs of a section become their playable form (or drop out); other items stay as they are.
    func playableSection(_ section: MusicBrowseSection, matcher: MusicCatalogMatcher? = nil, budget: TimeInterval = 8) async -> MusicBrowseSection {
        let allSongs = section.items.compactMap { i -> MusicTrack? in if case .track(let t) = i { t } else { nil } }
        guard !allSongs.isEmpty else { return section }
        // One entry per song: other uploads of the same recording are dropped from the shelf (their best copy stays).
        let songs = MusicSongIdentity.collapse(allSongs).groups.map(\.best.track)
        let done = await resolveList(songs, chartID: "section:" + section.id, matcher: matcher, budget: budget)
        var byOriginal: [String: MusicTrack] = [:]
        for e in done where e.isPlayable { byOriginal[e.original.uid] = e.resolved }
        var s = section
        s.items = section.items.compactMap { i in
            guard case .track(let t) = i else { return i }
            return byOriginal[t.uid].map { .track($0) }
        }
        return s
    }
}

// MARK: a chart being resolved

/// Hooks into the player for Play, Shuffle and the lazily fed queue.
struct MusicChartPlayerHooks {
    var play: @MainActor ([MusicTrack], Int) -> Void
    var enqueue: @MainActor ([MusicTrack]) -> Void
    var currentUID: @MainActor () -> String?
    /// Shuffle Play of the first resolved block of the chart (the engine orders it once). Nil only where no player can shuffle (tests of the chart alone).
    var playShuffled: (@MainActor ([MusicTrack]) -> Void)? = nil
    /// Adds a late-confirmed batch to a shuffled run: shuffled with the rest of the queue's engine and without a toast per batch. Nil falls back to `enqueue`.
    var enqueueShuffled: (@MainActor ([MusicTrack]) -> Void)? = nil
}

@MainActor @Observable
final class MusicChartSession {
    let chartID: String
    private(set) var entries: [MusicChartEntry] = []
    /// Show the rows that could not be resolved (dimmed). Off by default.
    var showUnavailable = false
    private(set) var cacheHits = 0
    private(set) var active = true
    /// A shelf the person is looking at: every row counts as in view, whatever the network or app state.
    var eager = false

    @ObservationIgnored private let engine: MusicChartEngine
    @ObservationIgnored private let deps: MusicChartDependencies
    @ObservationIgnored private let cache: MusicChartCache?
    @ObservationIgnored private let config: MusicChartConfig
    @ObservationIgnored private var inflight: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var workers: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWorker = 0
    @ObservationIgnored private var byUID: [String: Int] = [:]
    @ObservationIgnored private var visible: Set<Int> = []
    @ObservationIgnored private var avoid: Set<String> = []
    @ObservationIgnored private var failedAvoids: [String: String] = [:]
    @ObservationIgnored private var prewarmed = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var feed: Feed?

    private struct Feed { var cursor: Int; var pending: [MusicTrack]; var player: MusicChartPlayerHooks; var shuffled = false }

    init(chartID: String, tracks: [MusicTrack], deps: MusicChartDependencies, cache: MusicChartCache?, config: MusicChartConfig) {
        self.chartID = chartID; self.deps = deps; self.cache = cache; self.config = config
        self.engine = MusicChartEngine(deps: deps, itemBudget: config.itemBudget)
        update(tracks: tracks)
    }

    // MARK: derived

    var unavailableCount: Int { entries.lazy.filter(\.isUnavailable).count }
    var resolvedCount: Int { entries.lazy.filter(\.isPlayable).count }
    var isResolving: Bool { entries.contains { !$0.isFinal } }
    var shownEntries: [MusicChartEntry] { showUnavailable ? entries : entries.filter { !$0.isUnavailable } }
    /// The rows to draw: the resolved track where there is one, the chart's own row while it resolves.
    var shownTracks: [MusicTrack] { shownEntries.map(\.shown) }
    /// Only the verified playable tracks, in chart order.
    var playableTracks: [MusicTrack] { entries.compactMap { $0.isPlayable ? $0.resolved : nil } }

    func entry(forUID uid: String) -> MusicChartEntry? { byUID[uid].map { entries[$0] } }
    func status(forUID uid: String) -> MusicChartRowStatus? { entry(forUID: uid)?.status }

    // MARK: input

    /// Adds rows that arrived (the next page of a chart) and keeps what is already known. Rank is the position in the list.
    /// The same song listed under several video ids (audio, lyric video, official video) is ONE row: it keeps the best chart rank of its copies, plays
    /// the preferred copy and offers the others as versions. Different recordings (cover, live, remix, re-recording ...) stay separate rows.
    func update(tracks: [MusicTrack]) {
        var seen = Set(entries.flatMap { [$0.original.uid] + $0.alternates.map(\.uid) })
        let known = cache?.items(chartID: chartID) ?? [:]
        // Later pages that repeat a song already shown join that row as another version.
        var fresh: [(position: Int, track: MusicTrack)] = []
        for (i, t) in tracks.enumerated() where seen.insert(t.uid).inserted {
            if let k = entries.firstIndex(where: { MusicSongIdentity.sameSong($0.original, t) }) { entries[k].alternates.append(t) } else { fresh.append((i + 1, t)) }
        }
        let grouped = MusicSongIdentity.collapse(fresh.map(\.track))
        for g in grouped.groups {
            var e = MusicChartEntry(rank: fresh[g.rank - 1].position, original: g.best.track)
            e.alternates = g.alternates.map(\.track)
            if let c = known[g.best.track.uid] { apply(cached: c, to: &e) }
            entries.append(e)
            index(entries.count - 1)
        }
        if started { pump() }
    }

    /// The person picked another copy of a song: it becomes the row's copy (the chart rank stays) and is looked up on its own. False when it is not one of the row's versions.
    @discardableResult
    func chooseVersion(rowUID uid: String, pick: MusicTrack) -> Bool {
        guard let i = byUID[uid] else { return false }
        var all = [entries[i].original] + entries[i].alternates
        guard let p = all.firstIndex(where: { $0.uid == pick.uid }), p != 0 else { return false }
        let chosen = all.remove(at: p)
        inflight[i]?.cancel(); inflight[i] = nil
        byUID[entries[i].original.uid] = nil
        if let r = entries[i].resolved { byUID[r.uid] = nil }
        var e = MusicChartEntry(rank: entries[i].rank, original: chosen)
        e.alternates = all
        entries[i] = e
        index(i)
        if started { pump() }
        return true
    }

    private func apply(cached c: MusicChartCache.Item, to e: inout MusicChartEntry) {
        if let t = c.track { e.state = .playable; e.resolved = t; e.version = c.version; cacheHits += 1 }
        else if let r = c.reason { e.state = .unavailable(r); cacheHits += 1 }
    }

    private func index(_ i: Int) {
        byUID[entries[i].original.uid] = i
        if let r = entries[i].resolved { byUID[r.uid] = i }
    }

    // MARK: running

    func start() {
        started = true
        active = true
        pump()
    }

    /// The page was left: nothing more is asked, rows mid-lookup go back to waiting.
    func cancel() {
        started = false
        for (_, t) in workers { t.cancel() }
        for (_, t) in inflight { t.cancel() }
        workers = [:]
        inflight = [:]
        for i in entries.indices where entries[i].state == .resolving { entries[i].state = .pending }
        feed = nil
        cache?.flush()
    }

    /// The app became inactive or active again: background rows wait while inactive.
    func setActive(_ on: Bool) {
        active = on
        if on, started { pump() }
    }

    /// Rows come into and leave the screen; the rows in view and the next ones are resolved first.
    func noteVisible(uid: String, _ on: Bool) {
        guard let i = byUID[uid] else { return }
        if on { visible.insert(i) } else { visible.remove(i) }
        if on, started { pump() }
    }

    private func nextPending(background: Bool) -> Int? {
        func pendingAt(_ i: Int) -> Bool { entries.indices.contains(i) && entries[i].state == .pending && inflight[i] == nil }
        if let f = feed, let i = (f.cursor..<min(entries.count, f.cursor + config.feedLookahead)).first(where: pendingAt) { return i }
        if let low = visible.min(), let high = visible.max() {
            let hi = min(entries.count - 1, high + config.windowAhead)
            if low <= hi, let i = (low...hi).first(where: pendingAt) { return i }
        } else if let i = (0..<min(entries.count, config.windowAhead)).first(where: pendingAt) { return i }
        guard background else { return nil }
        return entries.indices.first(where: pendingAt)
    }

    private func pump() {
        guard started else { return }
        while workers.count < config.concurrency, entries.contains(where: { $0.state == .pending }) {
            let id = nextWorker; nextWorker += 1
            workers[id] = Task { [weak self] in
                await self?.work()
                self?.workers[id] = nil
            }
        }
    }

    private func work() async {
        while !Task.isCancelled {
            var background = eager
            if !background, active { background = await deps.backgroundAllowed() }
            guard let i = nextPending(background: background) else { return }
            await task(for: i).value
        }
    }

    private func task(for i: Int) -> Task<Void, Never> {
        if let t = inflight[i] { return t }
        entries[i].state = .resolving
        let original = entries[i].original
        let engine = self.engine
        let skip = avoid
        let t = Task { [weak self] in
            let began = Date()
            let out = await engine.resolve(original, avoid: skip)
            // The row may have been given another copy while this one was being looked up.
            guard let self, self.entries.indices.contains(i), self.entries[i].original.uid == original.uid else { return }
            self.finish(i, out, ms: Int(Date().timeIntervalSince(began) * 1000))
        }
        inflight[i] = t
        return t
    }

    private func finish(_ i: Int, _ out: MusicChartOutcome, ms: Int) {
        inflight[i] = nil
        guard entries.indices.contains(i) else { return }
        entries[i].elapsedMs = ms
        if Task.isCancelled, !out.isPlayable { if entries[i].state == .resolving { entries[i].state = .pending }; return }
        let uid = entries[i].original.uid
        if let t = out.track {
            entries[i].state = .playable; entries[i].resolved = t; entries[i].version = out.version
            cache?.put(chartID: chartID, uid: uid, MusicChartCache.Item(track: t, version: out.version, reason: nil))
        } else {
            let r = out.reason ?? .noPlayableCopy
            entries[i].state = .unavailable(r); entries[i].resolved = nil; entries[i].version = nil
            if out.cacheable { cache?.put(chartID: chartID, uid: uid, MusicChartCache.Item(track: nil, version: nil, reason: r)) }
        }
        index(i)
        warmTop()
        advanceFeed()
        if !isResolving { cache?.flush() }
    }

    /// Hands the first window of the top rows to the player's pre-resolver, once.
    private func warmTop() {
        guard !prewarmed else { return }
        let head = entries.prefix(config.prewarmCount)
        guard head.count == min(config.prewarmCount, entries.count), head.allSatisfy(\.isFinal) else { return }
        prewarmed = true
        let tracks = head.compactMap { $0.isPlayable ? $0.resolved : nil }
        guard !tracks.isEmpty else { return }
        let d = deps
        Task { await d.prewarm(tracks) }
    }

    /// Resolves one row now, ahead of everything else (a tap on a row that is still resolving, or a retry of an unavailable one). Returns when it is final.
    @discardableResult
    func resolveNow(_ i: Int, force: Bool = false) async -> MusicChartEntry? {
        guard entries.indices.contains(i) else { return nil }
        if force, entries[i].isFinal {
            cache?.remove(chartID: chartID, uid: entries[i].original.uid)
            entries[i].state = .pending
        }
        if entries[i].isFinal { return entries[i] }
        await task(for: i).value
        return entries.indices.contains(i) ? entries[i] : nil
    }

    func resolveNow(uid: String, force: Bool = false) async -> MusicChartEntry? {
        guard let i = byUID[uid] else { return nil }
        return await resolveNow(i, force: force)
    }

    /// A copy that was chosen did not play: it is not chosen again, the row is looked up afresh when tapped.
    func noteFailed(uid: String) {
        guard let i = byUID[uid], entries[i].isPlayable else { return }
        avoid.insert(entries[i].shown.uid)
        failedAvoids[uid] = entries[i].shown.uid
        entries[i].state = .unavailable(.failedToPlay)
        cache?.remove(chartID: chartID, uid: entries[i].original.uid)
    }

    /// The mark on the player ended (the song played, or its time ran out): the copy may be chosen again and the row is looked up afresh.
    func clearFailed(uid: String) {
        guard let avoided = failedAvoids.removeValue(forKey: uid) else { return }
        avoid.remove(avoided)
        guard let i = byUID[uid], entries[i].state == .unavailable(.failedToPlay) else { return }
        entries[i].state = .pending
    }

    // MARK: playing

    /// Plays the chart from a row (or the top) with only verified playable tracks, in chart order. Rows still resolving join the queue as they are
    /// confirmed, in order, until the person plays something else. A first row that has no copy falls through to the next that has.
    @discardableResult
    func play(from uid: String? = nil, shuffle: Bool = false, player: MusicChartPlayerHooks) async -> Bool {
        guard !entries.isEmpty else { return false }
        started = true
        var i = uid.flatMap { byUID[$0] } ?? 0
        var tried = 0
        while i < entries.count, tried < 12 {
            let e = await resolveNow(i, force: entries[i].isUnavailable && uid != nil && tried == 0)
            if e?.isPlayable == true { break }
            i += 1; tried += 1
        }
        guard i < entries.count, entries[i].isPlayable else { return false }
        var run: [MusicTrack] = []
        var cursor = i
        while cursor < entries.count, entries[cursor].isFinal {
            if entries[cursor].isPlayable, let r = entries[cursor].resolved { run.append(r) }
            cursor += 1
        }
        if shuffle, let shuffled = player.playShuffled { shuffled(run) } else { player.play(run, 0) }
        feed = Feed(cursor: cursor, pending: [], player: player, shuffled: shuffle && player.playShuffled != nil)
        pump()
        return true
    }

    private func advanceFeed() {
        guard var f = feed else { return }
        let ours = Set(entries.compactMap { $0.resolved?.uid } + entries.map { $0.original.uid })
        if let cur = f.player.currentUID(), !ours.contains(cur) { feed = nil; return }
        while f.cursor < entries.count, entries[f.cursor].isFinal {
            if entries[f.cursor].isPlayable, let r = entries[f.cursor].resolved { f.pending.append(r) }
            f.cursor += 1
        }
        let done = f.cursor >= entries.count
        if f.pending.count >= config.feedBatch || (done && !f.pending.isEmpty) {
            if f.shuffled, let add = f.player.enqueueShuffled { add(f.pending) } else { f.player.enqueue(f.pending) }
            f.pending = []
        }
        feed = done && f.pending.isEmpty ? nil : f
    }
}
