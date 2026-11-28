import Foundation

// MARK: - The race

/// One question to one source. A source may have several jobs (one per wording of the song's title and artist); they run side by side.
struct MusicLyricsRaceJob: Sendable {
    let id: String
    let variant: Int
    /// 0 starts at once, 1 when the second wave opens (or earlier, as soon as wave 0 has finished), 2 when the last wave opens (Genius).
    let wave: Int
    let timeout: Double
    let run: @Sendable () async throws -> MusicLyrics?

    init(id: String, variant: Int = 0, wave: Int = 0, timeout: Double, run: @escaping @Sendable () async throws -> MusicLyrics?) {
        self.id = id; self.variant = variant; self.wave = wave; self.timeout = timeout; self.run = run
    }
}

/// The time rules of one race. Every clock is injected so tests run without waiting.
struct MusicLyricsRaceConfig: Sendable {
    /// Requests in flight at once for one lookup.
    var maxConcurrent = 6
    /// Slow sources start now if nothing has been found by then.
    var secondWaveAt = 0.7
    var lastWaveAt = 1.6
    /// After the first plain or not-yet-wanted answer: how long a timed (or word-timed) one may still beat it.
    var plainWindow = 0.65
    /// After a plain answer was shown, how long the race keeps looking for timed lyrics.
    var upgradeWindow = 4.0
    /// When the person must have an answer even if sources are still working.
    var soft = 3.5
    /// The hard end of the race.
    var budget = 10.5
    var preferWords = false
    var durationSeconds: Double?
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    var now: @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }
}

struct MusicLyricsRaceOutcome: Sendable {
    var walk: MusicLyricsWalkOutcome
    var winnerVariant: Int?
    var winnerID: String?
    var elapsed: Double
}

/// Starts the healthy sources together, accepts the first good timed answer and stops everything else. Replaces the staggered walk.
enum MusicLyricsRace {
    private enum Tick: Sendable { case secondWave, lastWave, soft, budget, candidate, upgrade }
    private enum Event: Sendable {
        case done(Int, MusicLyricsAnswer, Double)
        case tick(Tick)
        case idle
    }

    /// A timed answer whose last line lies more than 10 s past the song's end is another cut or another song; a plain answer is never judged here.
    static func plausible(_ l: MusicLyrics, durationSeconds: Double?) -> Bool {
        guard !l.instrumental, let want = durationSeconds, want > 0, let last = l.synced?.last?.timeMs else { return true }
        let lastSeconds = Double(last) / 1000
        return lastSeconds <= want + 10
    }

    /// Higher is better: word timing, then line timing, then plain text.
    static func rank(_ l: MusicLyrics) -> Int { l.instrumental ? 4 : (l.isWordTimed ? 3 : (l.isSynced ? 2 : 1)) }

    static func run(_ jobs: [MusicLyricsRaceJob], config c: MusicLyricsRaceConfig, stats: MusicLyricsSourceStats? = nil,
                    progress: (@Sendable (String, MusicLyricsWalkEvent) -> Void)? = nil,
                    onProvisional: (@Sendable (MusicLyrics) -> Void)? = nil,
                    onSoftMiss: (@Sendable () -> Void)? = nil) async -> MusicLyricsRaceOutcome {
        let t0 = c.now()
        guard !jobs.isEmpty else { return MusicLyricsRaceOutcome(walk: MusicLyricsWalkOutcome(lyrics: nil, answered: false), winnerVariant: nil, winnerID: nil, elapsed: 0) }
        // Wave first, then the wording (the main wording of every source before any alternate), then the person's order.
        let order = jobs.indices.sorted { a, b in
            let (x, y) = (jobs[a], jobs[b])
            if x.wave != y.wave { return x.wave < y.wave }
            if x.variant != y.variant { return x.variant < y.variant }
            return a < b
        }
        return await withTaskGroup(of: Event.self) { group in
            var pending = order
            var active = 0
            var openWave = 0
            var started = Set<String>()
            var left: [String: Int] = [:]
            for j in jobs { left[j.id, default: 0] += 1 }
            var sourceNone = Set<String>(), sourceErr = Set<String>(), sourceHit = Set<String>()
            var answered = false
            var best: MusicLyrics?, bestJob = -1
            var candidateAt: Double?
            var provisionalSent = false, softSent = false
            var errored = 0

            func tick(_ t: Tick, after s: Double, _ g: inout TaskGroup<Event>) {
                g.addTask { do { try await c.sleep(s) } catch { return .idle }; return .tick(t) }
            }
            func launch(_ g: inout TaskGroup<Event>) {
                while active < c.maxConcurrent, let k = pending.firstIndex(where: { jobs[$0].wave <= openWave }) {
                    let i = pending.remove(at: k)
                    let job = jobs[i]
                    active += 1
                    if started.insert(job.id).inserted { progress?(job.id, .started) }
                    g.addTask {
                        let s = c.now()
                        do {
                            let r = try await MusicDeadline.race(seconds: job.timeout, sleep: c.sleep, { try await job.run() }, onTimeout: MusicError.network("timed out"))
                            if let r { return .done(i, .hit(r), c.now() - s) }
                            return .done(i, .none, c.now() - s)
                        } catch { return .done(i, .error("\(error)"), c.now() - s) }
                    }
                }
                // Nothing left to start in the open waves and nothing running: open the next one now instead of waiting for its time.
                if active == 0, !pending.isEmpty, openWave < 2 { openWave += 1; launch(&g) }
            }
            func finishSource(_ id: String) {
                guard left[id] == 0 else { return }
                if sourceHit.contains(id) { return }
                if sourceNone.contains(id) { progress?(id, .none) } else { progress?(id, .error) }
            }
            func finish(_ g: inout TaskGroup<Event>) -> MusicLyricsRaceOutcome {
                g.cancelAll()
                for k in pending { if !started.contains(jobs[k].id) { progress?(jobs[k].id, .cancelled) } }
                var walk = MusicLyricsWalkOutcome(lyrics: best, answered: answered || best != nil, errored: errored, noneIDs: sourceNone.subtracting(sourceHit), errorIDs: sourceErr)
                if best != nil { walk.answered = true }
                return MusicLyricsRaceOutcome(walk: walk, winnerVariant: best == nil ? nil : jobs[bestJob].variant, winnerID: best == nil ? nil : jobs[bestJob].id, elapsed: c.now() - t0)
            }

            tick(.secondWave, after: c.secondWaveAt, &group)
            tick(.lastWave, after: c.lastWaveAt, &group)
            tick(.soft, after: c.soft, &group)
            tick(.budget, after: c.budget, &group)
            launch(&group)

            while let event = await group.next() {
                switch event {
                case .idle: break
                case .tick(let t):
                    switch t {
                    case .secondWave: openWave = max(openWave, 1); launch(&group)
                    case .lastWave: openWave = max(openWave, 2); launch(&group)
                    case .budget: return finish(&group)
                    case .soft:
                        if best == nil, answered, !softSent { softSent = true; onSoftMiss?() }
                    case .candidate:
                        guard let b = best else { break }
                        // A timed answer that was only waiting for a word-timed one is final now; plain text is shown while the race goes on.
                        if b.isSynced || b.instrumental { return finish(&group) }
                        if !provisionalSent { provisionalSent = true; onProvisional?(b); tick(.upgrade, after: c.upgradeWindow, &group) }
                    case .upgrade: return finish(&group)
                    }
                case .done(let i, let answer, let took):
                    active -= 1
                    let job = jobs[i]
                    left[job.id, default: 1] -= 1
                    switch answer {
                    case .error(let why):
                        errored += 1; sourceErr.insert(job.id)
                        stats?.record(job.id, seconds: took, answered: false, hit: false)
                        _ = why
                    case .none:
                        answered = true; sourceNone.insert(job.id)
                        stats?.record(job.id, seconds: took, answered: true, hit: false)
                    case .hit(let raw):
                        guard let n = MusicLyricsNormalizer.normalize(raw), plausible(n, durationSeconds: c.durationSeconds) else {
                            answered = true; sourceNone.insert(job.id)
                            stats?.record(job.id, seconds: took, answered: true, hit: false)
                            break
                        }
                        answered = true
                        sourceHit.insert(job.id)
                        stats?.record(job.id, seconds: took, answered: true, hit: true)
                        progress?(job.id, .hit(n))
                        if MusicLyricsWalk.settles(n, preferWords: c.preferWords) { best = n; bestJob = i; return finish(&group) }
                        if best == nil || rank(n) > rank(best!) { best = n; bestJob = i }
                        if candidateAt == nil {
                            candidateAt = c.now()
                            tick(.candidate, after: c.plainWindow, &group)
                        }
                    }
                    finishSource(job.id)
                    launch(&group)
                }
                if active == 0, pending.isEmpty { return finish(&group) }
            }
            return finish(&group)
        }
    }
}
