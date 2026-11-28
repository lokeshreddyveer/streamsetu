import Foundation
import Observation

// RadioService: Pandora-style stations. A station is its seeds plus the person's thumbs; this service keeps the saved stations, runs the one that
// is playing (seeding, playing, refilling, recovering) and feeds the queue. The player stays the one coordinator: the service hands it songs
// through `appendRadioPicks` and a candidate source, and listens to its track events. The rules themselves are pure (`RadioLogic.swift`).

@MainActor @Observable
final class RadioService {
    static let shared = RadioService()

    enum Phase: Equatable, Sendable { case idle, seeding, playing, troubled }

    private(set) var stations: [RadioStation] = []
    private(set) var activeID: String?
    private(set) var phase: Phase = .idle
    /// Songs the person is tired of, with the day they said so.
    private(set) var tired: [String: Date] = [:]

    @ObservationIgnored weak var hub: MusicHub?
    @ObservationIgnored private let store: MusicJSONStore<RadioStoreFile>
    @ObservationIgnored private var recovery = RadioRecovery()
    @ObservationIgnored private var failedUIDs = Set<String>()
    @ObservationIgnored private var goneSeeds = Set<String>()
    @ObservationIgnored private var pool: [RadioCandidate] = []
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    /// The name the player shows as the queue's source while this station plays; a queue that moves away from it is no longer the station's.
    @ObservationIgnored private var playingSourceName: String?

    init(url: URL = MusicStorage.root.appendingPathComponent("radio-stations.json"), debounce: Duration = .seconds(1)) {
        store = MusicJSONStore<RadioStoreFile>(url: url, schemaVersion: RadioStoreFile.currentVersion, debounce: debounce)
        if let f = store.load()?.tidied() { stations = f.stations; tired = f.tired }
    }

    // MARK: state

    var activeStation: RadioStation? { activeID.flatMap { id in stations.first { $0.id == id } } }
    /// True while a station is the thing the player is playing from.
    var isActive: Bool { activeID != nil && (phase == .playing || phase == .troubled) && (hub?.player.isRadioQueue ?? false) }
    var isBusy: Bool { phase == .seeding }
    var isTroubled: Bool { phase == .troubled }
    func station(id: String) -> RadioStation? { stations.first { $0.id == id } }

    /// Stations the person played, newest first.
    var recentlyPlayed: [RadioStation] {
        stations.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    // MARK: wiring

    /// Connects the service to the hub's player. Safe to call again. The hub calls it once from `attach`.
    func attach(hub: MusicHub) {
        guard self.hub == nil else { return }
        self.hub = hub
        let player = hub.player
        player.radioSource = MusicClosureAutoplaySource(name: "radio-station") { request in await RadioService.shared.autoplayCandidates(request) }
        player.radioBlocked = { [weak self] in self?.blockedUIDs() ?? [] }
        let started = player.onTrackStarted
        player.onTrackStarted = { [weak self] t in started?(t); self?.trackStarted(t) }
        let changed = player.onCurrentChanged
        player.onCurrentChanged = { [weak self] t, why in changed?(t, why); self?.currentChanged(t) }
        player.onTrackFailed = { [weak self] uid in self?.trackFailed(uid) }
        let count = stations.count
        MusicDebugLog.log("radio", "service attached, \(count) stations")
    }

    func wipe() {
        deactivate(reason: "wipe")
        stations = []; tired = [:]
        store.delete()
    }

    func flush() { store.flush() }

    // MARK: saved stations

    /// Adds a station, or returns the saved one it duplicates (same derived id, or the same seeds). The list stays within its cap.
    @discardableResult
    func add(_ s: RadioStation) -> RadioStation {
        if let d = RadioDerived.existing(for: s, in: stations) { return d }
        let ids = Set(s.seeds.map(\.id))
        if s.derivedID == nil, !ids.isEmpty, let same = stations.first(where: { $0.derivedID == nil && Set($0.seeds.map(\.id)) == ids && $0.name == s.name }) { return same }
        stations.insert(s, at: 0)
        persist()
        MusicDebugLog.log("radio", "station added \(s.name) seeds=\(s.seeds.count)")
        return s
    }

    /// A station for seeds the person chose, named after them.
    static func makeStation(seeds: [RadioSeed], mode: RadioMode = .mixed) -> RadioStation {
        let names = seeds.map(\.name)
        let name: String
        switch names.count {
        case 0: name = Localized.string("Radio")
        case 1: name = Localized.string("%@ Radio", names[0])
        default: name = Localized.string("%@ and more", names.prefix(2).joined(separator: ", "))
        }
        return RadioStation(name: name, seeds: seeds, mode: mode, covers: seeds.compactMap { $0.thumbs.last }.prefix(RadioStation.coverCap).map { $0 })
    }

    func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        mutate(id) { $0.name = n }
    }

    /// Replaces the seeds (at least one stays). When the station is playing, the queue is not rebuilt until "New station".
    func setSeeds(_ id: String, _ seeds: [RadioSeed]) {
        guard !seeds.isEmpty else { return }
        mutate(id) { $0.seeds = seeds }
        goneSeeds.removeAll()
        MusicDebugLog.log("radio", "seeds edited \(id) count=\(seeds.count)")
    }

    func setMode(_ id: String, _ mode: RadioMode) {
        mutate(id) { $0.mode = mode }
        if id == activeID { MusicDebugLog.log("radio", "mode \(mode.rawValue)") }
    }

    func delete(_ id: String) {
        if id == activeID { stop() }
        stations.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func duplicate(_ id: String) -> RadioStation? {
        guard let s = station(id: id) else { return nil }
        let copy = RadioStation(name: Localized.string("%@ copy", s.name), seeds: s.seeds, mode: s.mode, covers: s.covers)
        stations.insert(copy, at: 0)
        persist()
        return copy
    }

    private func mutate(_ id: String, _ change: (inout RadioStation) -> Void) {
        guard let i = stations.firstIndex(where: { $0.id == id }) else { return }
        change(&stations[i])
        persist()
    }

    private func persist() {
        let f = RadioStoreFile(stations: stations, tired: tired).tidied()
        if f.stations.count != stations.count { stations = f.stations }
        tired = f.tired
        store.save(f)
    }

    // MARK: starting and stopping

    /// Starts a station: resolves its seeds into songs, fills a first batch and plays it. Returns true when a station began.
    @discardableResult
    func start(_ station: RadioStation) async -> Bool {
        startTask?.cancel()
        let task = Task { await self.run(station) }
        startTask = task
        return await task.value
    }

    private func run(_ station: RadioStation) async -> Bool {
        guard let hub, hub.canReplaceQueue() else { return false }
        let queueAtStart = hub.player.queueEpoch
        let st = add(station)
        refillTask?.cancel(); refillTask = nil
        activeID = st.id; phase = .seeding
        recovery.reset(); failedUIDs = []; goneSeeds = []; pool = []
        MusicDebugLog.log("radio", "start \(st.name) seeds=\(st.seeds.map { "\($0.kind.rawValue):\($0.name)" }.joined(separator: ",")) mode=\(st.mode.rawValue)")
        let found = await fetchPool(for: st, wantEligible: 12)
        if Task.isCancelled { return false }
        var ctx = context(for: st, tail: [])
        ctx.queuedUIDs = []; ctx.queuedKeys = []
        let picks = RadioSelector.select(found, context: ctx, want: 15)
        guard !picks.isEmpty else {
            MusicDebugLog.log("radio", "start found nothing for \(st.name) (pool \(found.count))")
            activeID = nil; phase = .idle
            MusicToasts.shared.show(Localized.string("Nothing to play here yet."))
            return false
        }
        // The person started something else while the songs were being found: that wins, and the radio does not cut it off.
        guard hub.player.queueEpoch == queueAtStart, hub.canReplaceQueue() else { activeID = nil; phase = .idle; return false }
        pool = Array(found.prefix(120))
        playingSourceName = st.name
        hub.player.play(picks.map(\.track), startAt: 0, sourceName: st.name, sourceID: "radio:" + st.id, radioSeed: "radio:" + st.id, isRadio: true)
        phase = .playing
        mutate(st.id) { $0.lastPlayedAt = Date() }
        MusicRadioNow.shared.started(Self.legacyStation(st))
        MusicDebugLog.log("radio", "playing \(st.name) first batch \(picks.count) from \(Set(picks.map(\.source.rawValue)).sorted().joined(separator: "+"))")
        return true
    }

    /// "New station": the same station again from its own seeds, with a fresh queue. Songs it already played stay out for a while.
    @discardableResult
    func restart(_ id: String) async -> Bool {
        guard let s = station(id: id) else { return false }
        return await start(s)
    }

    /// Stops the station and the player.
    func stop() {
        hub?.player.stopAndClear()
        deactivate(reason: "stopped")
    }

    private func deactivate(reason: String) {
        guard activeID != nil || phase != .idle else { return }
        MusicDebugLog.log("radio", "deactivate (\(reason))")
        refillTask?.cancel(); refillTask = nil
        activeID = nil; phase = .idle; pool = []; playingSourceName = nil
        MusicRadioNow.shared.clear()
        store.flush()
    }

    /// The old launcher type the "Now on radio" card still reads.
    private static func legacyStation(_ s: RadioStation) -> MusicStation {
        MusicStation(id: s.id, kind: .mix, title: s.name, subtitle: s.seeds.map(\.name).joined(separator: ", "), badge: Localized.string("Radio"),
                     seed: .search(query: s.name, languageKey: nil), thumbs: s.covers)
    }

    // MARK: asking for songs

    func context(for st: RadioStation, tail: [[String]]) -> RadioPickContext {
        var ctx = RadioPickContext(station: st)
        ctx.tired = tired
        ctx.failedUIDs = failedUIDs
        ctx.tailArtists = tail
        if let hub {
            ctx.blocked = hub.library.blacklist.union(MusicHiddenRecommendations.shared.set.blockedKeys)
            let history = MusicTasteReset.visible(hub.library.history).prefix(2000).map(\.track)
            ctx.familiarUIDs = Set(history.map(\.uid)).union(hub.library.liked.map(\.uid))
            ctx.familiarArtists = Set(history.flatMap { MusicAutoplaySelector.artistKeys($0) }).union(MusicTastePreferences.shared.prefs.artists.map { $0.id.isEmpty ? MusicEndlessSource.normalise($0.name) : $0.id })
            ctx.allow = hub.player.autoplayAllow
            let queue = hub.player.queue
            ctx.queuedUIDs = Set(queue.map(\.uid))
            ctx.queuedKeys = Set(queue.map { MusicAutoplaySelector.versionKey($0) })
        }
        return ctx
    }

    /// Asks the sources, turned by the recovery rotation, until enough songs could play. Seeds that returned nothing are remembered as gone.
    private func fetchPool(for st: RadioStation, wantEligible: Int) async -> [RadioCandidate] {
        guard let hub else { return [] }
        let adapters = RadioAdapters(hub: hub)
        var lists: [[RadioCandidate]] = []
        var anchor: MusicTrack? = hub.player.isRadioQueue ? hub.player.current : nil
        for source in recovery.sourceOrder([.provider, .graph, .local]) {
            if Task.isCancelled { break }
            var got: [RadioCandidate] = []
            switch source {
            case .provider:
                for seed in RadioRecovery.liveSeeds(st.seeds, gone: goneSeeds).prefix(4) {
                    let r = await adapters.provider(for: seed, mode: st.mode)
                    if !r.found { goneSeeds.insert(seed.id); MusicDebugLog.log("radio", "seed \(seed.name) found nothing, falling back to the other seeds") }
                    got += r.candidates
                }
                // What the person gave a thumb up is a seed too: more songs like those.
                for f in st.feedback.filter({ $0.kind == .up }).suffix(2) where !f.trackID.isEmpty {
                    if let t = hub.library.liked.first(where: { $0.uid == f.trackUID }) ?? lookup(f) { got += await adapters.recommendations(from: t, limit: 15, startRank: 15) }
                }
            case .graph:
                if let a = anchor ?? lists.flatMap({ $0 }).first?.track { got = await adapters.graph(around: a, want: 20) }
            case .local:
                if let a = anchor ?? lists.flatMap({ $0 }).first?.track { got = await adapters.local(around: a, want: 20) }
            }
            if anchor == nil { anchor = got.first?.track }
            let gotCount = got.count
            MusicDebugLog.log("radio", "source \(source.rawValue) gave \(gotCount)")
            lists.append(got)
            let merged = RadioPool.merge(lists)
            if RadioSelector.eligible(merged, context: context(for: st, tail: [])).count >= wantEligible { return lean(merged) }
        }
        return lean(RadioPool.merge(lists))
    }

    /// Songs that match what the person said they like (artists, genres, languages) move up within their source.
    private func lean(_ pool: [RadioCandidate]) -> [RadioCandidate] {
        let prefs = MusicTastePreferences.shared.prefs
        guard !prefs.isEmpty else { return pool }
        return pool.map { var c = $0; c.rank = max(0, c.rank - prefs.matches(c.track) * 4); return c }
    }

    /// Forgets what this run learned about tired and failed songs. Stations, thumbs and the person's library are not touched.
    func forgetLearned() { tired = [:]; failedUIDs = [] }

    /// A thumbs-up song from the queue or the history, so it can seed provider recommendations.
    private func lookup(_ f: RadioFeedback) -> MusicTrack? {
        hub?.library.history.first { $0.track.uid == f.trackUID }?.track
    }

    /// Candidates for the player's own autoplay when it asks while a station plays: the station's pool, ranked and filtered by the station rules.
    func autoplayCandidates(_ request: MusicAutoplayRequest) async -> [MusicAutoplayCandidate] {
        guard isActive, let st = activeStation, phase == .playing else { return [] }
        if pool.count < 15 { pool = RadioPool.merge([pool, await fetchPool(for: st, wantEligible: 20)]) }
        let ctx = context(for: st, tail: tail())
        let picks = RadioSelector.select(pool, context: ctx, want: max(request.want, RadioRefill.minBatch))
        MusicDebugLog.log("radio", "autoplay asked, gave \(picks.count)")
        return picks.enumerated().map { MusicAutoplayCandidate(track: $1.track, reason: $1.reason, rank: $0) }
    }

    private func tail() -> [[String]] {
        guard let hub else { return [] }
        return hub.player.queue.suffix(RadioSpacing.maxRun + 3).map { MusicAutoplaySelector.artistKeys($0) }
    }

    /// Song uids the player must keep out of a radio queue: this station's bans, "not for a while" songs and songs that failed to play.
    func blockedUIDs() -> Set<String> {
        var s = failedUIDs.union(RadioBans.pruned(tired, now: Date()).keys)
        if let st = activeStation { s.formUnion(st.bannedUIDs) }
        return s
    }

    // MARK: refill

    private func refillSoon() { Task { await refill(force: true) } }

    /// Fetches the next batch when fewer than five songs are queued after the playing one. Several calls in a row make one fetch.
    func refill(force: Bool = false) async {
        guard let hub, isActive, phase == .playing, let st = activeStation else { return }
        let upcoming = hub.player.upcomingCount
        guard force || RadioRefill.needsRefill(upcoming: upcoming, inFlight: refillTask != nil) else { return }
        guard refillTask == nil else { return }
        let id = st.id
        let want = RadioRefill.batchSize(upcoming: upcoming)
        let task = Task { [weak self] in
            guard let self else { return }
            guard let current = self.activeStation else { self.refillTask = nil; return }
            var picks = RadioSelector.select(self.pool, context: self.context(for: current, tail: self.tail()), want: want)
            if picks.count < want / 2, let fresh = self.activeStation {
                self.pool = RadioPool.merge([self.pool, await self.fetchPool(for: fresh, wantEligible: want * 2)])
                if Task.isCancelled || self.activeID != id { return }
                picks = RadioSelector.select(self.pool, context: self.context(for: fresh, tail: self.tail()), want: want)
            }
            self.refillTask = nil
            guard self.activeID == id, let hub = self.hub else { return }
            self.pool = Array(self.pool.suffix(120))
            let chosen = picks
            if chosen.isEmpty {
                let step = self.recovery.failed()
                MusicDebugLog.log("radio", "refill empty, recovery step \(step)")
                self.apply(step)
                return
            }
            let added = hub.player.appendRadioPicks(chosen.map { MusicAutoplayPick(track: $0.track, reason: $0.reason) })
            if added > 0 { self.recovery.succeeded() }
            let sources = Set(chosen.map(\.source.rawValue)).sorted().joined(separator: "+")
            MusicDebugLog.log("radio", "refill added \(added) of \(chosen.count) from \(sources), upcoming was \(upcoming)")
        }
        refillTask = task
        await task.value
    }

    private func apply(_ step: RadioRecovery.Step) {
        switch step {
        case .skip: break
        case .switchSource:
            pool = []
            let rotation = recovery.rotation
            MusicDebugLog.log("radio", "switching pool source (rotation \(rotation))")
            refillSoon()
        case .trouble:
            phase = .troubled
            MusicDebugLog.log("radio", "troubled: no songs after \(RadioRecovery.troubleAfter) failures")
        }
    }

    /// "Retry" on the calm trouble state.
    func retry() {
        guard activeID != nil else { return }
        recovery.reset(); failedUIDs = []; goneSeeds = []; pool = []
        phase = .playing
        MusicDebugLog.log("radio", "retry")
        refillSoon()
    }

    // MARK: player events

    private func trackStarted(_ t: MusicTrack) {
        adoptRestoredIfNeeded()
        guard let id = activeID, hub?.player.isRadioQueue == true else { return }
        mutate(id) { $0.recordPlayed(t.uid); $0.noteCover(t) }
        if phase == .troubled { phase = .playing }
        recovery.succeeded()
        Task { await refill() }
    }

    private func trackFailed(_ uid: String) {
        guard isActive else { return }
        failedUIDs.insert(uid)
        let step = recovery.failed()
        let failures = recovery.failures
        MusicDebugLog.log("radio", "unavailable \(uid), step \(step), failures \(failures)")
        apply(step)
        Task { await refill() }
    }

    private func currentChanged(_ t: MusicTrack?) {
        guard activeID != nil, phase == .playing || phase == .troubled else { return }
        // RD-3: the station ends when the queue moves to something that is not this station.
        guard let hub, t != nil, hub.player.isRadioQueue, hub.player.sourceName == playingSourceName else {
            deactivate(reason: "queue changed")
            return
        }
    }

    /// A radio queue restored after a relaunch belongs to the saved station of that name.
    private func adoptRestoredIfNeeded() {
        guard activeID == nil, phase == .idle, let p = hub?.player, p.isRadioQueue, let name = p.sourceName,
              let st = stations.first(where: { $0.name == name }) else { return }
        activeID = st.id; phase = .playing; playingSourceName = name
        MusicRadioNow.shared.started(Self.legacyStation(st))
        MusicDebugLog.log("radio", "adopted restored queue for \(st.name)")
    }

    // MARK: feedback

    /// The person's latest thumb for a song on the playing station.
    func feedback(for uid: String) -> RadioFeedbackKind? {
        activeStation?.feedback.last { $0.trackUID == uid }?.kind
    }

    /// Thumbs up: the song's artists and language weigh more on this station, and the song is liked in the library.
    func thumbsUp(_ t: MusicTrack) {
        guard let id = activeID else { return }
        if let f = activeStation?.feedback.last(where: { $0.trackUID == t.uid }), f.kind == .up { undo(f.id); return }   // a second tap takes it back
        let wasLiked = hub?.library.isLiked(t) ?? true
        let fb = RadioFeedback(track: t, kind: .up)
        mutate(id) { s in
            s.feedback.removeAll { $0.trackUID == t.uid }
            s.bannedUIDs.removeAll { $0 == t.uid }
            s.feedback.append(fb)
        }
        if !wasLiked { hub?.library.toggleLike(t) }
        MusicDebugLog.log("radio", "thumbs up \(t.uid) artists=\(fb.artistKeys.count) liked=\(!wasLiked)")
        MusicToasts.shared.show(Localized.string("You'll hear more like this"), kind: .success, actionTitle: Localized.string("Undo")) { [weak self] in
            self?.undo(fb.id, unlike: !wasLiked)
        }
    }

    /// Thumbs down: the song never plays again on this station, and the player moves on.
    func thumbsDown(_ t: MusicTrack) {
        guard let id = activeID else { return }
        let fb = RadioFeedback(track: t, kind: .down)
        mutate(id) { s in
            s.feedback.removeAll { $0.trackUID == t.uid }
            s.feedback.append(fb)
            s.ban(t.uid)
        }
        MusicDebugLog.log("radio", "thumbs down \(t.uid), banned on station")
        skipIfCurrent(t)
        MusicToasts.shared.show(Localized.string("Won't play this on this station"), actionTitle: Localized.string("Undo")) { [weak self] in self?.undo(fb.id) }
    }

    /// "Not for a while": the song is kept off every station for 30 days.
    func notForAWhile(_ t: MusicTrack) {
        guard let id = activeID else { return }
        let fb = RadioFeedback(track: t, kind: .tired)
        mutate(id) { s in s.feedback.removeAll { $0.trackUID == t.uid }; s.feedback.append(fb) }
        tired[t.uid] = fb.at
        persist()
        MusicDebugLog.log("radio", "tired of \(t.uid), banned for \(RadioBans.tiredDays) days on all stations")
        skipIfCurrent(t)
        MusicToasts.shared.show(Localized.string("Won't play this for a while"), actionTitle: Localized.string("Undo")) { [weak self] in self?.undo(fb.id) }
    }

    /// Takes a thumb back: its weight, its ban and (for a thumbs up the service itself liked) the like.
    func undo(_ feedbackID: String, unlike: Bool = false) {
        for s in stations {
            guard let f = s.feedback.first(where: { $0.id == feedbackID }) else { continue }
            mutate(s.id) { st in
                st.feedback.removeAll { $0.id == feedbackID }
                if f.kind == .down { st.bannedUIDs.removeAll { $0 == f.trackUID } }
            }
            if f.kind == .tired { tired[f.trackUID] = nil; persist() }
            if unlike, let hub, let t = hub.library.liked.first(where: { $0.uid == f.trackUID }) { hub.library.toggleLike(t) }
            MusicDebugLog.log("radio", "feedback undone \(f.kind.rawValue) \(f.trackUID)")
            return
        }
    }

    private func skipIfCurrent(_ t: MusicTrack) {
        if hub?.player.current?.uid == t.uid { hub?.player.next() }
    }
}
