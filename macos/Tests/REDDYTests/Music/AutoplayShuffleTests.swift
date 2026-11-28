import Foundation
import Testing
@testable import REDDY

// Pure logic for the smart shuffle and smart autoplay engines: fakes for every source, a seeded generator for every random choice.

private func track(_ n: Int, _ title: String? = nil, artist: String = "A", album: String? = nil, provider: String = "p") -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: 200_000,
               artists: [MusicArtistRef(id: "ar-\(artist)", name: artist)],
               album: album.map { MusicAlbumRef(id: "al-\($0)", title: $0) })
}

private func entries(_ ts: [MusicTrack]) -> [MusicQueue.Entry] { ts.map { MusicQueue.Entry(track: $0) } }

private func maxRun(_ ts: [MusicTrack]) -> Int {
    var best = 0, run = 0, last = ""
    for t in ts { let a = MusicShuffleEngine.artistKey(t); run = (a == last) ? run + 1 : 1; last = a; best = max(best, run) }
    return best
}

/// Smallest distance between two songs of one artist (rows apart), over artists with at least two songs.
private func minGap(_ ts: [MusicTrack]) -> Int {
    var pos: [String: [Int]] = [:]
    for (i, t) in ts.enumerated() { pos[MusicShuffleEngine.artistKey(t), default: []].append(i) }
    var m = Int.max
    for (_, p) in pos where p.count > 1 { for (a, b) in zip(p, p.dropFirst()) { m = min(m, b - a) } }
    return m
}

private func library(sizes: [Int]) -> [MusicTrack] {
    var out: [MusicTrack] = [], n = 0
    for (a, s) in sizes.enumerated() { for _ in 0..<s { out.append(track(n, artist: "artist\(a)")); n += 1 } }
    return out
}

@Suite("Smart shuffle") struct SmartShuffleTests {
    @Test func balancedSpacingBeatsNaiveShuffle() {
        var balancedRuns = 0.0, naiveRuns = 0.0
        for seed in 0..<60 {
            var g = MusicSeededRNG(seed: UInt64(seed) &* 7919 &+ 1)
            let sizes = (0..<7).map { _ in Int.random(in: 3...12, using: &g) }
            let lib = library(sizes: sizes)
            let es = entries(lib)
            let total = Double(lib.count), biggest = Double(sizes.max() ?? 1)
            let smart = MusicShuffleEngine.order(es, mode: .smart, seed: UInt64(seed)).map(\.track)
            let naive = MusicShuffleEngine.order(es, mode: .random, seed: UInt64(seed)).map(\.track)
            #expect(Set(smart.map(\.uid)) == Set(lib.map(\.uid)) && smart.count == lib.count)
            balancedRuns += Double(maxRun(smart)); naiveRuns += Double(maxRun(naive))
            #expect(maxRun(smart) <= 2, "max run \(maxRun(smart)) seed \(seed) sizes \(sizes)")
            // Each artist's songs stay about count/size apart: at least half that, whatever the sizes.
            let bound = max(1, Int((total / biggest) * 0.5))
            #expect(minGap(smart) >= bound, "min gap \(minGap(smart)) < \(bound) seed \(seed) sizes \(sizes)")
        }
        #expect(balancedRuns < naiveRuns)
    }

    @Test func spreadsAlbumsAndLanguageBlocks() {
        // 20 Telugu-script songs and 6 Hindi-script songs: the Hindi ones must be spread, not clumped.
        var ts: [MusicTrack] = []
        for i in 0..<20 { ts.append(track(i, "తెలుగు పాట \(i)", artist: "te\(i % 5)")) }
        for i in 20..<26 { ts.append(track(i, "हिन्दी गाना \(i)", artist: "hi\(i % 3)")) }
        let out = MusicShuffleEngine.order(entries(ts), mode: .smart, seed: 3).map(\.track)
        let hindiPos = out.enumerated().filter { MusicShuffleEngine.languageKey($0.element) == "hindi" }.map(\.offset)
        #expect(hindiPos.count == 6)
        let gaps = zip(hindiPos, hindiPos.dropFirst()).map { $1 - $0 }
        #expect((gaps.min() ?? 0) >= 2)
        // Albums: two albums of 6 songs by different artists never touch more than twice in a row.
        var al: [MusicTrack] = []
        for i in 0..<12 { al.append(track(100 + i, artist: "x\(i)", album: i < 6 ? "One" : "Two")) }
        let o2 = MusicShuffleEngine.order(entries(al), mode: .smart, seed: 5).map(\.track)
        var run = 0, best = 0, last = ""
        for t in o2 { let k = MusicShuffleEngine.albumKey(t); run = k == last ? run + 1 : 1; last = k; best = max(best, run) }
        #expect(best <= 2)
    }

    @Test func deterministicGivenSeed() {
        let es = entries(library(sizes: [5, 4, 3, 6]))
        let a = MusicShuffleEngine.order(es, mode: .smart, seed: 42).map(\.id)
        #expect(a == MusicShuffleEngine.order(es, mode: .smart, seed: 42).map(\.id))
        #expect(a != MusicShuffleEngine.order(es, mode: .smart, seed: 43).map(\.id))
        let r = MusicShuffleEngine.order(es, mode: .random, seed: 9).map(\.id)
        #expect(r == MusicShuffleEngine.order(es, mode: .random, seed: 9).map(\.id) && Set(r) == Set(es.map(\.id)))
    }

    @Test func scoringPrefersSpacedFreshFavouriteSmoothAndNewOrders() {
        let a1 = track(1, artist: "A"), a2 = track(2, artist: "A"), b1 = track(3, artist: "B"), c1 = track(4, artist: "C")
        let clumped = entries([a1, a2, b1, c1]), spaced = entries([a1, b1, a2, c1]).enumerated().map { i, e in var x = e; x.id = clumped[[0, 2, 1, 3][i]].id; return x }
        let sig = MusicShuffleSignals()
        #expect(MusicShuffleEngine.score(spaced, signals: sig) > MusicShuffleEngine.score(clumped, signals: sig))
        let spacedWins = MusicShuffleEngine.score(spaced, signals: sig) > MusicShuffleEngine.score(clumped, signals: sig)
        #expect(spacedWins, "of two orders the better-spaced one scores higher")

        // Freshness: the song not played for a year goes ahead of the one played an hour ago.
        let now = Date()
        var fresh = MusicShuffleSignals(); fresh.now = now
        fresh.lastPlayed[a1.uid] = now.addingTimeInterval(-3600); fresh.lastPlayed[b1.uid] = now.addingTimeInterval(-365 * 86_400)
        let staleFirst = entries([b1, a1]), freshFirst = [staleFirst[1], staleFirst[0]]
        #expect(MusicShuffleEngine.score(staleFirst, signals: fresh) > MusicShuffleEngine.score(freshFirst, signals: fresh))

        // Affinity: a liked song slightly earlier.
        var aff = MusicShuffleSignals(); aff.favourites = [b1.uid]
        #expect(MusicShuffleEngine.score(staleFirst, signals: aff) > MusicShuffleEngine.score(freshFirst, signals: aff))

        // Not the same neighbours as the last shuffle.
        var prev = MusicShuffleSignals(); prev.previousOrder = [a1.uid, b1.uid, c1.uid]
        let same = entries([a1, b1, c1]), other = entries([a1, c1, b1])
        #expect(MusicShuffleEngine.score(other, signals: prev) > MusicShuffleEngine.score(same, signals: prev))

        // Energy smoothness.
        var en = MusicShuffleSignals(); en.energy = [a1.uid: 0.1, b1.uid: 0.9, c1.uid: 0.15]
        let smooth = entries([a1, c1, b1]), jumpy = entries([a1, b1, c1])
        #expect(MusicShuffleEngine.score(smooth, signals: en) > MusicShuffleEngine.score(jumpy, signals: en))
        #expect(MusicShuffleEngine.energy(bpm: 120, meanEnergy: 0.5) != nil && MusicShuffleEngine.energy(bpm: 0, meanEnergy: nil) == nil)
    }

    @Test func freshnessShapesTheChosenOrderOverManySeeds() {
        let lib = library(sizes: [4, 4, 4, 4, 4])
        let now = Date()
        var sig = MusicShuffleSignals(); sig.now = now
        for (i, t) in lib.enumerated() { sig.lastPlayed[t.uid] = i < 10 ? now.addingTimeInterval(-3600) : now.addingTimeInterval(-90 * 86_400) }
        let es = entries(lib)
        var plain = 0.0, aware = 0.0
        for s in 0..<40 {
            for (mode, sign) in [(false, MusicShuffleSignals()), (true, sig)] {
                let o = MusicShuffleEngine.order(es, mode: .smart, signals: sign, seed: UInt64(s)).prefix(8)
                let stale = Double(o.filter { !(sig.lastPlayed[$0.track.uid].map { now.timeIntervalSince($0) < 7200 } ?? false) }.count)
                if mode { aware += stale } else { plain += stale }
            }
        }
        #expect(aware > plain)
    }

    @Test func wholeContextIsShuffledAndPreviousGoesBack() {
        var q = MusicQueue()
        let lib = library(sizes: [10, 10, 10, 10, 10, 10, 10, 10, 10, 10])   // 100 songs, more than a visible page
        q.replace(with: lib, startAt: 0)
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 1))
        #expect(q.count == 100 && q.current?.track.uid == lib[0].uid)
        #expect(q.tracks.dropFirst().map(\.uid) != lib.dropFirst().map(\.uid))
        #expect(maxRun(Array(q.tracks.dropFirst())) <= 2)
        var played = [q.current!.track.uid]
        for _ in 0..<6 { played.append(q.advance(auto: false)!.track.uid) }
        var back: [String] = []
        for _ in 0..<6 { back.append(q.retreat()!.track.uid) }
        #expect(back == played.dropLast().reversed())
        // Un-shuffle restores the original order (the pointer is back on row 0, nothing is history).
        q.setShuffle(false)
        #expect(q.tracks.map(\.uid) == lib.map(\.uid))
    }

    @Test func queueEditsDoNotReshuffleAndPlayNextRespectsOrder() {
        var q = MusicQueue()
        let lib = library(sizes: [6, 6, 6, 6])
        q.replace(with: lib, startAt: 0)
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 2))
        let before = q.tracks.map(\.uid)
        let extra = track(900, "Added", artist: "Z")
        q.playNext([extra])
        #expect(q.entries[1].track.uid == extra.uid)
        var without = q.tracks.map(\.uid); without.remove(at: 1)
        #expect(without == before)
        q.remove(at: 5)
        var expect = before; expect.remove(at: 4)   // row 5 now was original row 4 (extra sits at 1)
        #expect(q.tracks.map(\.uid).filter { $0 != extra.uid } == expect)
        let before2 = q.tracks.map(\.uid)
        q.moveUpcoming(from: 10, to: 3)
        var moved = before2; let m = moved.remove(at: 10); moved.insert(m, at: 3)
        #expect(q.tracks.map(\.uid) == moved)
    }

    @Test func repeatAllRegeneratesEachLapWithoutTheLastFifthOpeningIt() {
        var q = MusicQueue()
        let lib = library(sizes: [5, 5, 5, 5, 5, 5, 5, 5, 5, 5])   // 50
        q.replace(with: lib, startAt: 0)
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 7))
        q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: 11)
        q.repeatMode = .all
        var lap1: [String] = [q.current!.track.uid]
        for _ in 0..<49 { lap1.append(q.advance(auto: true)!.track.uid) }
        #expect(Set(lap1).count == 50)
        let peek = q.peekNext()
        let first = q.advance(auto: true)
        #expect(first?.id == peek?.id)           // the lookahead showed the real first song of the next lap
        var lap2 = [first!.track.uid]
        for _ in 0..<49 { lap2.append(q.advance(auto: true)!.track.uid) }
        #expect(Set(lap2) == Set(lap1) && lap2 != lap1)
        #expect(Set(lap2.prefix(10)).isDisjoint(with: Set(lap1.suffix(10))))
    }

    @Test func repeatAllLapRuleWorksForTinyAndRandomQueues() {
        for n in [2, 3, 5] {
            let es = entries(library(sizes: [n]))
            let next = MusicShuffleEngine.lap(es, mode: .random, seed: 4)
            #expect(Set(next.map(\.id)) == Set(es.map(\.id)))
            #expect(next.first?.id != es.last?.id)
        }
    }

    @Test func smartShuffleInsertsMarkedSuggestionsEveryThreeToFive() {
        let own = entries(library(sizes: [8, 8, 8]))
        let sugg = entries((0..<10).map { track(500 + $0, artist: "s\($0)") })
        var rng = MusicSeededRNG(seed: 5)
        let out = MusicSmartSuggest.interleave(own: own, suggestions: sugg, using: &rng)
        let idx = out.enumerated().filter { $0.element.suggested }.map(\.offset)
        #expect(!idx.isEmpty && out.last?.suggested == false && out.first?.suggested == false)
        var prev = -1
        for i in idx { #expect((3...5).contains(i - prev - 1)); prev = i }
        #expect(out.filter { !$0.suggested }.map(\.id) == own.map(\.id))
        #expect(MusicSmartSuggest.needed(ownUpcoming: 24, suggestedUpcoming: 0) == 6)
        #expect(MusicSmartSuggest.needed(ownUpcoming: 24, suggestedUpcoming: 9) == 0)
    }

    @Test func suggestionsAreRemovableKeepableAndLeaveWithShuffle() {
        var q = MusicQueue()
        let lib = library(sizes: [6, 6, 6, 6])
        q.replace(with: lib, startAt: 0)
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 1))
        let picks = (0..<5).map { MusicAutoplayPick(track: track(700 + $0, artist: "s\($0)"), reason: MusicAutoplayReason(.artist, "S")) }
        let n = q.insertSuggestions(picks, seed: 9)
        #expect(n == 5 && q.upcomingSuggestedCount == 5 && q.entries.filter(\.suggested).allSatisfy { $0.reason != nil })
        let i = q.entries.firstIndex { $0.suggested }!
        let gone = q.entries[i].id
        q.remove(at: i)
        #expect(q.upcomingSuggestedCount == 4 && !q.entries.contains { $0.id == gone })
        let keep = q.entries.first { $0.suggested }!
        let kept1 = q.keepSuggested(id: keep.id)
        #expect(kept1 && q.upcomingSuggestedCount == 3)
        // A second top-up goes after the last suggestion already there.
        q.insertSuggestions([MusicAutoplayPick(track: track(800, artist: "n"), reason: MusicAutoplayReason(.radio, "x"))], seed: 1)
        q.setShuffle(false)
        #expect(q.upcomingSuggestedCount == 0 && q.entries.contains { $0.id == keep.id } == true)
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 1))
        q.insertSuggestions(picks, seed: 2)
        q.reshuffleUpcoming(shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 3))
        #expect(q.upcomingSuggestedCount == 0 && q.shuffle)
    }

    @Test func rowsRoundTripAndOldFilesStillLoad() throws {
        var e = MusicQueue.Entry(track: track(1), auto: true); e.reason = "Same film: Awaara"; e.suggested = true
        let data = try JSONEncoder().encode(MusicQueue.Row(e))
        let back = try JSONDecoder().decode(MusicQueue.Row.self, from: data).entry
        #expect(back.suggested && back.reason == "Same film: Awaara" && back.auto)
        let old = #"{"track":\#(String(data: try JSONEncoder().encode(track(2)), encoding: .utf8)!)}"#
        let r = try JSONDecoder().decode(MusicQueue.Row.self, from: Data(old.utf8))
        #expect(!r.suggested && r.reason == nil)
    }
}

// MARK: autoplay

private func src(_ name: String, offline: Bool = false, _ list: @escaping @Sendable (MusicAutoplayRequest) -> [MusicAutoplayCandidate]) -> MusicClosureAutoplaySource {
    MusicClosureAutoplaySource(name: name, worksOffline: offline) { list($0) }
}

private func cands(_ ts: [MusicTrack], _ kind: MusicAutoplayReasonKind = .artist, language: MusicLanguage? = nil) -> [MusicAutoplayCandidate] {
    ts.enumerated().map { MusicAutoplayCandidate(track: $1, reason: MusicAutoplayReason(kind, "X"), rank: $0, language: language) }
}

private func teluguSong(_ n: Int, artist: String) -> MusicTrack { track(n, "తెలుగు పాట \(n)", artist: artist) }
private func hindiSong(_ n: Int, artist: String) -> MusicTrack { track(n, "हिन्दी गाना \(n)", artist: artist) }

private func request(_ seed: MusicTrack, want: Int = 15, rs: UInt64 = 1) -> MusicAutoplayRequest {
    var r = MusicAutoplayRequest(seed: seed); r.want = want; r.randomSeed = rs; return r
}

@Suite("Smart autoplay") struct SmartAutoplayTests {
    @Test func refillThresholds() {
        #expect(MusicAutoplayEngine.needsRefill(upcomingAuto: 4, contextRemaining: 0))
        #expect(!MusicAutoplayEngine.needsRefill(upcomingAuto: 5, contextRemaining: 0))
        #expect(!MusicAutoplayEngine.needsRefill(upcomingAuto: 0, contextRemaining: 9))
        #expect(MusicAutoplayEngine.wantCount(upcomingAuto: 4) == 11 && MusicAutoplayEngine.wantCount(upcomingAuto: 15) == 0)
        #expect(MusicAutoplayEngine.fillTo >= MusicAutoplayEngine.floorUpcoming)
    }

    @Test func singleSongFromSearchContinuesGaplessly() async {
        var q = MusicQueue()
        let seed = track(1, artist: "Seed")
        q.replace(with: [seed], startAt: 0)
        #expect(q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        let pool = (10..<60).map { track($0, artist: "a\($0 % 9)") }
        let engine = MusicAutoplayEngine(sources: [src("fake") { _ in cands(pool) }])
        let built = MusicAutoplayBuilder.make(entries: q.entries, currentIndex: q.index, recent: [], history: [], blocked: [], offline: false,
                                              want: MusicAutoplayEngine.wantCount(upcomingAuto: q.upcomingAutoCount), randomSeed: 3)!
        let picks = await engine.fetch(built.request, context: built.context)
        #expect(picks.count >= MusicAutoplayEngine.floorUpcoming)
        let merged = q.mergeAutoplayPicks(picks)
        #expect(merged == picks.count)
        #expect(q.current?.track.uid == seed.uid)                       // the playing song is untouched
        #expect(q.peekNext() != nil && q.hasNext)                       // there is a next song: no stop at the end
        #expect(q.entries.dropFirst().allSatisfy { $0.auto && $0.reason != nil })
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))   // enough waiting, nothing more to fetch
        // Skipping through until fewer than 5 remain asks for more.
        for _ in 0..<(picks.count - 4) { q.advance(auto: true) }
        #expect(q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
    }

    @Test func endOfAlbumPlaylistOrChartContinues() {
        var q = MusicQueue()
        q.replace(with: library(sizes: [12]), startAt: 0)
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        for _ in 0..<9 { q.advance(auto: true) }
        #expect(q.contextRemaining == 2 && q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
    }

    @Test func toggleOffAndGuestAndRepeatDoNotAutoplay() {
        var q = MusicQueue()
        q.replace(with: [track(1)], startAt: 0)
        #expect(!q.wantsAutoplay(enabled: false, isGuest: false, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: true, isGuest: true, hydrating: false))     // Listen Together guest follows the host
        q.repeatMode = .all
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        q.repeatMode = .off
        q.mergeAutoplayPicks([MusicAutoplayPick(track: track(2), reason: MusicAutoplayReason(.radio, "x"))])
        q.clearAuto()
        #expect(q.autoCount == 0)
    }

    @Test func teluguSeedGetsTeluguAndMixedHistoryGetsBoth() async {
        let seed = teluguSong(1, artist: "Seed")
        let te = (10..<20).map { teluguSong($0, artist: "te\($0)") }
        let hi = (20..<30).map { hindiSong($0, artist: "hi\($0)") }
        let en = (30..<40).map { track($0, "English tune \($0)", artist: "en\($0)") }
        let engine = MusicAutoplayEngine(sources: [src("f") { _ in cands(te + hi + en, .radio) }])
        let picks = await engine.fetch(request(seed, want: 8), context: MusicAutoplayContext())
        #expect(picks.count == 8)
        #expect(picks.allSatisfy { MusicLanguageDetector.language(of: $0.track)?.script == .telugu })

        // A listener who plays Telugu and Hindi alike gets both.
        var ctx = MusicAutoplayContext()
        ctx.profile = MusicLanguageProfile.build(from: Array(te.prefix(6)) + Array(hi.prefix(6)))
        let mixed = await engine.fetch(request(seed), context: ctx)
        let langs = Set(mixed.compactMap { MusicLanguageDetector.language(of: $0.track)?.script })
        #expect(langs == [.telugu, .hindi])
        #expect(!mixed.contains { MusicLanguageDetector.language(of: $0.track)?.script == .latin })
    }

    @Test func languageNeutralSongsOnlyFillWhenNothingElseDoes() async {
        let seed = teluguSong(1, artist: "Seed")
        let latinOnly = (10..<20).map { track($0, "Samajavaragamana \($0)", artist: "l\($0)") }
        let engine = MusicAutoplayEngine(sources: [src("f") { _ in cands(latinOnly, .radio) }])
        #expect(await engine.fetch(request(seed, want: 6), context: MusicAutoplayContext()).count == 6)    // never silent
        let te = (30..<33).map { teluguSong($0, artist: "t\($0)") }
        let both = MusicAutoplayEngine(sources: [src("f") { _ in cands(latinOnly + te, .radio) }])
        let picks = await both.fetch(request(seed, want: 6), context: MusicAutoplayContext())
        #expect(picks.prefix(3).allSatisfy { MusicLanguageDetector.language(of: $0.track)?.script == .telugu })
        // A strong link (same film) lets a Latin-lettered song through even with Telugu available.
        let strong = MusicAutoplayEngine(sources: [src("f") { _ in cands(latinOnly, .film) }])
        #expect(await strong.fetch(request(seed, want: 4), context: MusicAutoplayContext()).count == 4)
    }

    @Test func noRepeatsBlacklistAndVersions() async {
        let seed = track(1, artist: "Seed")
        let pool = (10..<40).map { track($0, "Tune \($0)", artist: "a\($0)") }
        var ctx = MusicAutoplayContext()
        ctx.recentUIDs = Set(pool[0..<10].map(\.uid))            // played in the last 100
        ctx.queuedUIDs = Set(pool[10..<15].map(\.uid))           // already queued
        ctx.queuedKeys = Set(pool[10..<15].map(MusicAutoplaySelector.versionKey))
        ctx.blocked = [pool[15].uid, "ar-a17"]                   // never play: a song and an artist
        let remix = track(99, "Tune 20 (Remix)", artist: "a20")  // another version of a queued song's twin
        let engine = MusicAutoplayEngine(sources: [src("f") { _ in cands(pool + [remix]) }])
        let picks = await engine.fetch(request(seed, want: 30), context: ctx)
        let uids = Set(picks.map(\.track.uid))
        #expect(uids.isDisjoint(with: ctx.recentUIDs) && uids.isDisjoint(with: ctx.queuedUIDs))
        #expect(!uids.contains(pool[15].uid) && !uids.contains(pool[7].uid))
        #expect(!uids.contains(remix.uid))                        // "Tune 20" is already in; its remix is not offered again
        #expect(picks.count == Set(picks.map(\.track.uid)).count)
        var gate = MusicAutoplayContext(); gate.allow = { $0.uid != pool[20].uid }
        let kids = await engine.fetch(request(seed, want: 30), context: gate)
        #expect(!kids.contains { $0.track.uid == pool[20].uid })
    }

    @Test func artistSpacingInTheAutoQueue() async {
        let seed = track(1, artist: "Seed")
        let pool: [MusicTrack] = (0..<60).map { i in track(100 + i, artist: i < 30 ? "big\(i % 2)" : "small\(i)") }   // two artists own half the pool
        var ctx = MusicAutoplayContext()
        ctx.tailArtists = [["ar-big0"], ["ar-big0"]]
        let engine = MusicAutoplayEngine(sources: [src("f") { _ in cands(pool) }])
        let picks = await engine.fetch(request(seed, want: 25), context: ctx)
        #expect(picks.count == 25)
        let seq = ctx.tailArtists + picks.map { MusicAutoplaySelector.artistKeys($0.track) }
        for i in 0..<(seq.count - 5) {
            let window = seq[i..<(i + 6)].flatMap { $0 }
            for k in Set(window) { #expect(window.filter { $0 == k }.count <= 2, "window at \(i)") }
        }
    }

    @Test func mixesFamiliarAndDiscoveryAboutSeventyThirty() async {
        let seed = track(1, artist: "Seed")
        let familiarArtists = (0..<10).map { "fam\($0)" }
        let pool = (0..<80).map { track(100 + $0, artist: $0 < 40 ? familiarArtists[$0 % 10] : "new\($0)") }
        var ctx = MusicAutoplayContext()
        ctx.familiarArtists = Set(familiarArtists.map { "ar-" + $0 })
        var share = 0.0
        for s in 0..<30 {
            let engine = MusicAutoplayEngine(sources: [src("f") { _ in cands(pool) }])
            let picks = await engine.fetch(request(seed, want: 15, rs: UInt64(s)), context: ctx)
            share += Double(picks.filter { ctx.familiarArtists.contains(MusicAutoplaySelector.artistKeys($0.track)[0]) }.count) / Double(picks.count)
        }
        let avg = share / 30
        #expect(avg > 0.55 && avg < 0.85, "familiar share \(avg)")
    }

    @Test func failingSourceAndFailingSongAreReplacedQuietly() async {
        let seed = track(1, artist: "Seed")
        let backup = (10..<40).map { track($0, artist: "b\($0)") }
        let engine = MusicAutoplayEngine(sources: [src("graph") { _ in [] }, src("radio") { _ in cands(backup, .radio) }])
        let picks = await engine.fetch(request(seed), context: MusicAutoplayContext())
        #expect(picks.count == 15)
        var q = MusicQueue()
        q.replace(with: [seed], startAt: 0)
        q.mergeAutoplayPicks(picks)
        let failing = q.entries[1]
        let before = q.upcomingAutoCount
        q.advance(auto: false)
        #expect(q.current?.id == failing.id)
        q.advance(auto: false)                        // the failed row is skipped on ...
        if let k = q.entries.firstIndex(where: { $0.id == failing.id }) { q.remove(at: k) }   // ... and dropped
        #expect(q.upcomingAutoCount == before - 2 && q.entries.filter(\.auto).count == before - 1)
        let again = await engine.fetch(request(seed, want: MusicAutoplayEngine.wantCount(upcomingAuto: q.upcomingAutoCount), rs: 2),
                                       context: MusicAutoplayBuilder.make(entries: q.entries, currentIndex: q.index, recent: [], history: [], blocked: [], offline: false, want: 3)!.context)
        #expect(!again.isEmpty && !again.contains { q.entries.map(\.track.uid).contains($0.track.uid) })
    }

    @Test func retryGateAsksAgainAfterAnEmptyAnswer() {
        let tail = UUID()
        var g = MusicAutoplayRetryGate()
        let t0 = Date()
        #expect(g.shouldFetch(tail: tail, now: t0))
        g.begin(tail: tail)
        #expect(!g.shouldFetch(tail: tail, now: t0))
        g.failed(now: t0)
        #expect(!g.shouldFetch(tail: tail, now: t0.addingTimeInterval(1)))
        #expect(g.shouldFetch(tail: tail, now: t0.addingTimeInterval(3.1)))
        g.begin(tail: tail); g.failed(now: t0.addingTimeInterval(4))
        g.begin(tail: tail); g.failed(now: t0.addingTimeInterval(20))
        g.begin(tail: tail); g.failed(now: t0.addingTimeInterval(60))
        #expect(!g.shouldFetch(tail: tail, now: t0.addingTimeInterval(500)))      // tries used up
        #expect(g.shouldFetch(tail: UUID(), now: t0))                              // a new tail starts fresh
        var q = MusicEndlessGate()
        let k = UUID()
        q.begin(k); q.finish(); q.noteEmpty(now: t0)
        #expect(!q.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: k, now: t0))
        #expect(q.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: k, now: t0.addingTimeInterval(4)) && q.retryDelay == 3)
    }

    @Test func seedSwitchingFollowsTheSongThePersonChose() {
        let a = track(1, artist: "A"), auto1 = track(2, artist: "B"), auto2 = track(3, artist: "C")
        var q = MusicQueue()
        q.replace(with: [a], startAt: 0)
        q.mergeAutoplayPicks([auto1, auto2].map { MusicAutoplayPick(track: $0, reason: MusicAutoplayReason(.radio, "A")) })
        q.advance(auto: true); q.advance(auto: true)
        #expect(MusicAutoplayBuilder.anchor(entries: q.entries, currentIndex: q.index!)?.uid == a.uid)   // no drift along the autoplay run
        let d = track(4, artist: "D")
        q.replace(with: [d], startAt: 0)
        let built = MusicAutoplayBuilder.make(entries: q.entries, currentIndex: q.index, recent: [a], history: [], blocked: [], offline: false, want: 15)!
        #expect(built.request.seed.uid == d.uid && built.context.queuedUIDs == [d.uid])
    }

    @Test func manualAddsStayAheadOfAutoplayAndKeepPromotes() {
        var q = MusicQueue()
        q.replace(with: [track(1)], startAt: 0)
        q.mergeAutoplayPicks((10..<14).map { MusicAutoplayPick(track: track($0), reason: MusicAutoplayReason(.radio, "x")) })
        q.addToQueue([track(50)])
        q.playNext([track(51)])
        #expect(q.entries[1].track.id == "t51" && q.entries[2].track.id == "t50" && q.entries[3].auto)
        let keepID = q.entries[4].id
        let kept0 = q.keepAuto(id: keepID)
        #expect(kept0)
        let kept = q.entries.first { $0.id == keepID }!
        #expect(!kept.auto && kept.reason == nil)
        #expect(q.entries.firstIndex { $0.id == keepID }! < q.entries.firstIndex { $0.auto }!)
    }

    @Test func offlineUsesOnlyOfflineSourcesAndPlayableSongs() async {
        let seed = track(1, artist: "Seed")
        let net = (10..<30).map { track($0, artist: "n\($0)") }
        let local = (100..<120).map { track($0, artist: "l\($0)", provider: "local") }
        let engine = MusicAutoplayEngine(sources: [src("radio") { _ in cands(net) }, src("local", offline: true) { _ in cands(local, .local) }])
        var r = request(seed, want: 10); r.offline = true
        var ctx = MusicAutoplayContext()
        ctx.playableOffline = { $0.providerID == "local" }
        let picks = await engine.fetch(r, context: ctx)
        #expect(picks.count == 10 && picks.allSatisfy { $0.track.providerID == "local" })
    }

    @Test func localSourceFollowsArtistThenLanguageAndReasonsRead() async {
        let seed = teluguSong(1, artist: "Anirudh")
        let lib = [teluguSong(2, artist: "Anirudh"), teluguSong(3, artist: "Other"), track(4, "Plain", artist: "Third")]
        let c = await MusicLocalAffinitySource(library: { lib }).candidates(for: request(seed))
        #expect(c.first { $0.track.id == "t2" }?.reason.kind == .artist && c.first { $0.track.id == "t3" }?.reason.kind == .language)
        #expect(MusicAutoplayReason(.artist, "Yuvan Shankar Raja").text == "Autoplay: more from Yuvan Shankar Raja")
        #expect(MusicAutoplayReason(.film, "Awaara").text == "Same film: Awaara")
        #expect(MusicAutoplayReason(.language, "Telugu").text == "More Telugu songs")
    }
}
