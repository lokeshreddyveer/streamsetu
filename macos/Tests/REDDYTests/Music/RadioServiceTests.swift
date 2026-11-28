import Testing
import Foundation
@testable import REDDY

// Rules of Pandora-style stations, tested as behaviour with synthetic listeners: a new person, a heavy Telugu listener, a one-artist listener, a
// source that returns duplicates and songs that will not play, and a pool where everything is banned. Nothing here uses a real library.

private enum RT {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func track(_ n: Int, artist: String? = nil, title: String? = nil, provider: String = "p") -> MusicTrack {
        let a = artist ?? "Artist \(n)"
        return MusicTrack(id: "t\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: 200_000, artists: [MusicArtistRef(id: "a-" + a, name: a)])
    }

    static func candidates(_ tracks: [MusicTrack], source: RadioSource = .provider) -> [RadioCandidate] {
        tracks.enumerated().map { RadioCandidate(track: $1, source: source, rank: $0) }
    }

    static func station(mode: RadioMode = .mixed, history: [String] = [], banned: [String] = [], feedback: [RadioFeedback] = []) -> RadioStation {
        RadioStation(name: "Test", seeds: [.mood("test")], createdAt: now, mode: mode, feedback: feedback, history: history, bannedUIDs: banned)
    }

    static func context(_ s: RadioStation, familiar: Set<String> = [], tired: [String: Date] = [:], blocked: Set<String> = [], tail: [[String]] = []) -> RadioPickContext {
        var c = RadioPickContext(station: s)
        c.now = now; c.tired = tired; c.blocked = blocked; c.tailArtists = tail
        c.familiarArtists = familiar
        return c
    }

    /// The longest run of one artist in a row.
    static func longestRun(_ picks: [RadioPick]) -> Int {
        var best = 0, run = 0, last = ""
        for p in picks {
            let k = MusicAutoplaySelector.artistKeys(p.track).first ?? ""
            run = k == last ? run + 1 : 1
            last = k; best = max(best, run)
        }
        return best
    }
}

@Suite struct RadioSelectionTests {
    @Test func aNewPersonGetsAFullBatchWithNoRepeatsAndNoLongRuns() {
        let pool = RT.candidates((0..<40).map { RT.track($0, artist: "Artist \($0 % 10)") })
        let picks = RadioSelector.select(pool, context: RT.context(RT.station()), want: 15)
        #expect(picks.count == 15)
        #expect(Set(picks.map(\.track.uid)).count == picks.count)
        #expect(RT.longestRun(picks) <= RadioSpacing.maxRun)
    }

    @Test func songsAlreadyPlayedOrQueuedNeverComeBack() {
        let tracks = (0..<30).map { RT.track($0) }
        var station = RT.station()
        for t in tracks.prefix(10) { station.recordPlayed(t.uid) }
        var ctx = RT.context(station)
        ctx.queuedUIDs = Set(tracks[10..<15].map(\.uid))
        let picks = RadioSelector.select(RT.candidates(tracks), context: ctx, want: 15)
        #expect(picks.count == 15)
        #expect(picks.allSatisfy { !station.playedSet.contains($0.track.uid) && !ctx.queuedUIDs.contains($0.track.uid) })
    }

    @Test func twoBatchesInARowNeverRepeatASong() {
        let pool = RT.candidates((0..<60).map { RT.track($0, artist: "Artist \($0 % 12)") })
        var station = RT.station()
        var all: [String] = []
        for _ in 0..<3 {
            let picks = RadioSelector.select(pool, context: RT.context(station, tail: []), want: 15)
            for p in picks { station.recordPlayed(p.track.uid); all.append(p.track.uid) }
        }
        #expect(all.count == 45 && Set(all).count == 45)
    }

    @Test func aProviderThatReturnsDuplicatesAndVersionsOfTheSameSongGivesEachSongOnce() {
        let a = RT.track(1, artist: "X", title: "Moon")
        let remix = RT.track(2, artist: "X", title: "Moon (Remix)")
        let again = a
        let other = RT.track(3, artist: "Y", title: "Sun")
        let picks = RadioSelector.select(RT.candidates([a, remix, again, other]), context: RT.context(RT.station()), want: 10)
        #expect(Set(picks.map(\.track.uid)) == [a.uid, other.uid])
    }

    @Test func songsThatFailedToPlayAreKeptOut() {
        let tracks = (0..<12).map { RT.track($0) }
        var ctx = RT.context(RT.station())
        ctx.failedUIDs = Set(tracks.prefix(6).map(\.uid))
        let picks = RadioSelector.select(RT.candidates(tracks), context: ctx, want: 10)
        #expect(picks.count == 6 && picks.allSatisfy { !ctx.failedUIDs.contains($0.track.uid) })
    }

    @Test func aOneArtistListenerStillGetsMusicBecauseSpacingRelaxes() {
        let pool = RT.candidates((0..<20).map { RT.track($0, artist: "Only") })
        let picks = RadioSelector.select(pool, context: RT.context(RT.station(mode: .familiar), familiar: ["a-Only"]), want: 10)
        #expect(picks.count >= 3)
        #expect(Set(picks.map(\.track.uid)).count == picks.count)
    }

    @Test func whenEverythingIsBannedNothingIsPicked() {
        let tracks = (0..<10).map { RT.track($0) }
        let station = RT.station(banned: tracks.map(\.uid))
        #expect(RadioSelector.select(RT.candidates(tracks), context: RT.context(station), want: 10).isEmpty)
        let tired = Dictionary(uniqueKeysWithValues: tracks.map { ($0.uid, RT.now) })
        #expect(RadioSelector.select(RT.candidates(tracks), context: RT.context(RT.station(), tired: tired), want: 10).isEmpty)
        #expect(RadioSelector.select(RT.candidates(tracks), context: RT.context(RT.station(), blocked: Set(tracks.map(\.uid))), want: 10).isEmpty)
    }

    @Test func aNeverPlayArtistBlocksAllTheirSongs() {
        let tracks = [RT.track(1, artist: "Blocked"), RT.track(2, artist: "Fine")]
        let picks = RadioSelector.select(RT.candidates(tracks), context: RT.context(RT.station(), blocked: ["a-Blocked"]), want: 5)
        #expect(picks.map(\.track.uid) == [tracks[1].uid])
    }
}

@Suite struct RadioModeAndTasteTests {
    private func pool() -> (candidates: [RadioCandidate], familiar: Set<String>) {
        // A heavy Telugu listener: ten artists they play and ten they do not, all different artists.
        let known = (0..<10).map { RT.track($0, artist: "Known \($0)") }
        let fresh = (10..<20).map { RT.track($0, artist: "Fresh \($0)") }
        let mixed = zip(known, fresh).flatMap { [$0, $1] }
        return (RT.candidates(mixed), Set(known.flatMap { MusicAutoplaySelector.artistKeys($0) }))
    }

    private func knownShare(_ mode: RadioMode) -> Double {
        let p = pool()
        let picks = RadioSelector.select(p.candidates, context: RT.context(RT.station(mode: mode), familiar: p.familiar), want: 10)
        let known = picks.filter { $0.track.artists.first?.name.hasPrefix("Known") == true }.count
        return Double(known) / Double(max(1, picks.count))
    }

    @Test func familiarModePlaysMostlyKnownSongsAndDiscoverMostlyNew() {
        #expect(knownShare(.familiar) >= 0.8)
        #expect(knownShare(.discover) <= 0.3)
        let mixed = knownShare(.mixed)
        #expect(mixed >= 0.4 && mixed <= 0.7)
    }

    @Test func mixingKeepsTheShareAsCloseAsWholeSongsAllow() {
        var familiar = 0
        for n in 0..<20 where RadioMixing.wantsFamiliar(picked: n, familiarPicked: familiar, share: 0.5) { familiar += 1 }
        #expect(familiar == 10)
    }

    @Test func aThumbsUpMakesThatArtistComeFirstAndAThumbsDownLast() {
        let liked = RT.track(1, artist: "Liked"), plain = RT.track(2, artist: "Plain"), disliked = RT.track(3, artist: "Disliked")
        let pool = RT.candidates([disliked, plain, liked])
        let before = RadioSelector.select(pool, context: RT.context(RT.station()), want: 3)
        #expect(before.first?.track.uid == disliked.uid)
        var up = RadioFeedback(track: RT.track(9, artist: "Liked"), kind: .up, at: RT.now)
        up.id = "up"
        var down = RadioFeedback(track: RT.track(8, artist: "Disliked"), kind: .down, at: RT.now)
        down.id = "down"
        let after = RadioSelector.select(pool, context: RT.context(RT.station(feedback: [up, down])), want: 3)
        #expect(after.map(\.track.uid) == [liked.uid, plain.uid, disliked.uid])
    }

    @Test func oldThumbsCountForLessThanNewOnes() {
        let t = RT.track(1, artist: "A")
        let fresh = RadioAffinity.build(from: [RadioFeedback(track: t, kind: .up, at: RT.now)], now: RT.now)
        let old = RadioAffinity.build(from: [RadioFeedback(track: t, kind: .up, at: RT.now.addingTimeInterval(-120 * 86_400))], now: RT.now)
        #expect((fresh.artists["a-A"] ?? 0) > (old.artists["a-A"] ?? 0) * 2)
    }
}

@Suite struct RadioBanTests {
    @Test func notForAWhileLastsThirtyDaysOnEveryStation() {
        let uid = "p:t1"
        let said = RT.now
        let tired = [uid: said]
        #expect(RadioBans.isTired(uid, tired: tired, now: said.addingTimeInterval(29 * 86_400)))
        #expect(!RadioBans.isTired(uid, tired: tired, now: said.addingTimeInterval(31 * 86_400)))
        #expect(RadioBans.pruned(tired, now: said.addingTimeInterval(31 * 86_400)).isEmpty)
        #expect(RadioBans.pruned(tired, now: said.addingTimeInterval(1)).count == 1)
    }

    @Test func aThumbsDownBansOnlyThatStation() {
        let t = RT.track(1)
        var a = RT.station(), b = RT.station()
        a.ban(t.uid)
        #expect(RadioBans.isBanned(t, station: a, tired: [:], blocked: [], now: RT.now))
        #expect(!RadioBans.isBanned(t, station: b, tired: [:], blocked: [], now: RT.now))
        b.ban(t.uid); b.ban(t.uid)
        #expect(b.bannedUIDs.count == 1)
    }
}

@Suite struct RadioRefillAndRecoveryTests {
    @Test func aRefillStartsUnderFiveSongsAndAsksForTenToTwenty() {
        #expect(RadioRefill.needsRefill(upcoming: 4, inFlight: false))
        #expect(!RadioRefill.needsRefill(upcoming: 5, inFlight: false))
        #expect(!RadioRefill.needsRefill(upcoming: 0, inFlight: true))
        #expect(RadioRefill.batchSize(upcoming: 0) == 20)
        #expect(RadioRefill.batchSize(upcoming: 4) == 16)
        #expect(RadioRefill.batchSize(upcoming: 19) == 10)
    }

    @Test func artistSpacingStopsAThirdSongInARow() {
        #expect(RadioSpacing.breaksRun(["x"], tail: [["x"], ["x"]]))
        #expect(!RadioSpacing.breaksRun(["x"], tail: [["y"], ["x"]]))
        #expect(!RadioSpacing.breaksRun(["x"], tail: [["x"]]))
        #expect(!RadioSpacing.breaksRun([""], tail: [[""], [""]]))
    }

    @Test func failuresSkipThenSwitchSourceThenSayTheyAreInTrouble() {
        var r = RadioRecovery()
        var steps: [RadioRecovery.Step] = []
        for _ in 0..<RadioRecovery.troubleAfter { steps.append(r.failed()) }
        #expect(steps[0] == .skip && steps[1] == .skip && steps[2] == .switchSource)
        #expect(steps[5] == .switchSource && steps.last == .trouble && r.troubled)
        #expect(r.rotation == 2)
        r.succeeded()
        #expect(!r.troubled && r.failures == 0)
    }

    @Test func theSourceOrderTurnsWithEachSwitch() {
        var r = RadioRecovery()
        let all: [RadioSource] = [.provider, .graph, .local]
        #expect(r.sourceOrder(all) == [.provider, .graph, .local])
        for _ in 0..<RadioRecovery.switchAfter { _ = r.failed() }
        #expect(r.sourceOrder(all) == [.graph, .local, .provider])
    }

    @Test func aVanishedSeedFallsBackToTheOthersAndToAllWhenAllVanished() {
        let a = RadioSeed.mood("a"), b = RadioSeed.mood("b")
        #expect(RadioRecovery.liveSeeds([a, b], gone: [a.id]) == [b])
        #expect(RadioRecovery.liveSeeds([a, b], gone: [a.id, b.id]) == [a, b])
    }

    @Test func mergingSourcesKeepsTheBestRankedCopyOfEachSong() {
        let t = RT.track(1)
        let merged = RadioPool.merge([[RadioCandidate(track: t, source: .graph, rank: 30)], [RadioCandidate(track: t, source: .provider, rank: 0)]])
        #expect(merged.count == 1 && merged[0].source == .graph)
    }
}

@Suite struct RadioPersistenceTests {
    @Test func theHistoryNeverGrowsPastTwoHundredAndAReplayMovesToTheEnd() {
        var s = RT.station()
        for n in 0..<250 { s.recordPlayed("u\(n)", at: RT.now) }
        #expect(s.history.count == RadioStation.historyCap && s.history.last == "u249" && s.history.first == "u50")
        s.recordPlayed("u100", at: RT.now)
        #expect(s.history.last == "u100" && s.history.count == RadioStation.historyCap)
    }

    @Test func aStoreFileSurvivesAnEncodeAndDecode() throws {
        var s = RadioStation(name: "Mix", seeds: [.song(RT.track(1)), .genre("Folk"), .language(key: "telugu", name: "Telugu")], createdAt: RT.now,
                             lastPlayedAt: RT.now, mode: .discover, history: ["a", "b"], bannedUIDs: ["x"], covers: [MusicThumbnail(url: "https://img/1", width: 300, height: 300)])
        s.feedback = [RadioFeedback(track: RT.track(2), kind: .up, at: RT.now)]
        let file = RadioStoreFile(stations: [s], tired: ["p:t9": RT.now])
        let data = try #require(file.encoded())
        let back = try #require(RadioStoreFile.decode(data))
        #expect(back.stations == [s])
        #expect(back.tired == ["p:t9": RT.now])
    }

    @Test func anOlderFileWithMissingFieldsStillLoads() throws {
        let json = #"{"stations":[{"name":"Old"},{"id":"x","seeds":[{"kind":"artist","name":"Someone"}],"mode":"nonsense"}]}"#
        let f = try #require(RadioStoreFile.decode(Data(json.utf8)))
        #expect(f.version == RadioStoreFile.currentVersion && f.stations.count == 2)
        #expect(f.stations[0].name == "Old" && f.stations[0].mode == .mixed && f.stations[0].history.isEmpty)
        #expect(f.stations[1].seeds.first?.kind == .artist && f.stations[1].mode == .mixed)
        #expect(RadioStoreFile.decode(Data("not json".utf8)) == nil)
    }

    @Test func tidyingCapsTheStationsKeepsTheNewestAndDropsExpiredBans() {
        let stations = (0..<60).map { n in RadioStation(id: "s\(n)", name: "S\(n)", seeds: [.mood("m")], createdAt: RT.now.addingTimeInterval(Double(n))) }
        var file = RadioStoreFile(stations: stations + [stations[3]], tired: ["old": RT.now.addingTimeInterval(-40 * 86_400), "new": RT.now])
        file.version = 0
        let tidy = file.tidied(now: RT.now)
        #expect(tidy.stations.count == RadioStoreFile.stationCap)
        #expect(tidy.stations.contains { $0.id == "s59" } && !tidy.stations.contains { $0.id == "s0" })
        #expect(Set(tidy.stations.map(\.id)).count == tidy.stations.count)
        #expect(tidy.tired.keys.sorted() == ["new"] && tidy.version == RadioStoreFile.currentVersion)
    }

    @MainActor @Test func theServiceSavesStationsAndFeedbackAndReadsThemBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("radio-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("radio.json")
        let service = RadioService(url: url, debounce: .milliseconds(1))
        let made = service.add(RadioService.makeStation(seeds: [.artist(MusicArtist(id: "a1", providerID: "p", name: "Someone"))]))
        service.rename(made.id, to: "Evening")
        service.setMode(made.id, .discover)
        let copy = try #require(service.duplicate(made.id))
        service.flush()
        let reloaded = RadioService(url: url, debounce: .milliseconds(1))
        #expect(reloaded.stations.map(\.name).sorted() == ["Evening", "Evening copy"].sorted())
        #expect(reloaded.station(id: made.id)?.mode == .discover && reloaded.station(id: copy.id)?.seeds.first?.kind == .artist)
        reloaded.delete(made.id)
        #expect(reloaded.stations.count == 1)
        reloaded.wipe()
        #expect(reloaded.stations.isEmpty)
    }

    @MainActor @Test func startingTheSameDerivedStationTwiceFindsTheSavedOne() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("radio-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = RadioService(url: dir.appendingPathComponent("radio.json"), debounce: .milliseconds(1))
        let draft = RadioStation(id: "artist:x", name: "X Radio", seeds: [.mood("x")], derivedID: "artist:x")
        let first = service.add(draft)
        let second = service.add(RadioStation(id: "other", name: "X Radio", seeds: [.mood("x")], derivedID: "artist:x"))
        #expect(first.id == second.id && service.stations.count == 1)
    }
}

@Suite struct RadioDerivedTests {
    private func telugu(_ n: Int, artist: String) -> MusicTrack {
        var t = MusicTrack(id: "te\(n)", providerID: "p", title: "ప్రేమ కథ \(n)", durationMs: 200_000, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])
        t.hints = MusicProviderHints(genre: "Folk")
        return t
    }

    @Test func aNewPersonGetsNoPersonalStationsAndRegionStationsNamedByTheSource() {
        let songs = (0..<5).map { RT.track($0) }
        let section = MusicBrowseSection(id: "chart-1", title: "Whatever The Source Calls It", items: songs.map { .track($0) }, scope: .regional("xx"))
        let r = RadioDerived.build(.init(chartSections: [section], region: "xx"))
        #expect(!r.hasPersonal && r.daily == nil)
        #expect(r.regional.count == 1 && r.regional[0].name == "Whatever The Source Calls It")
        #expect(r.regional[0].seeds.count == 3 && r.regional[0].derivedID == "region:xx:chart-1")
    }

    @Test func aListWithTooFewSongsMakesNoStation() {
        let section = MusicBrowseSection(id: "tiny", title: "Tiny", items: [.track(RT.track(1))], scope: .regional("xx"))
        #expect(RadioDerived.regional([section], region: "xx").isEmpty)
    }

    @Test func aHeavyTeluguListenerGetsTheirArtistsLanguageGenreAndADailyMix() {
        let names = ["Singer A", "Singer B", "Singer C"]
        let history = (0..<18).map { PlayRecord(track: telugu($0, artist: names[$0 % 3]), at: RT.now.addingTimeInterval(Double(-$0 * 60)), playedMs: 200_000) }
        let r = RadioDerived.build(.init(history: history))
        #expect(Set(r.artists.map(\.name)) == Set(names.map { "\($0) Radio" }))
        #expect(r.languages.contains { $0.derivedID == "language:" + MusicLanguage.telugu.rawValue })
        #expect(r.genres.first?.seeds.first?.kind == .genre)
        let daily = r.daily
        #expect(daily != nil && daily?.seeds.count == 4 && daily?.derivedID == "daily")
        #expect(Set(r.all.map(\.id)).count == r.all.count)
    }

    @Test func aOneArtistListenerGetsOneArtistStation() {
        let history = (0..<8).map { PlayRecord(track: RT.track($0, artist: "Solo"), at: RT.now.addingTimeInterval(Double(-$0)), playedMs: 100_000) }
        let r = RadioDerived.build(.init(history: history))
        #expect(r.artists.count == 1 && r.daily != nil)
    }
}

@Suite struct RadioSeedWordsTests {
    @Test func aLanguageNamedInWordsIsFoundByTheAppsOwnNames() {
        #expect(RadioSeedWords.language(in: "Telugu songs") == .telugu)
        #expect(RadioSeedWords.language(in: " hindi ") == .hindi)
        #expect(RadioSeedWords.language(in: "folk") == nil)
    }

    @Test func anArtistMatchNeedsTheNameOrAFairPrefix() {
        #expect(RadioSeedWords.matches(artist: "Daft Punk", typed: "daft punk"))
        #expect(RadioSeedWords.matches(artist: "Daft Punk", typed: "daft"))
        #expect(!RadioSeedWords.matches(artist: "Daft Punk", typed: "da"))
        #expect(!RadioSeedWords.matches(artist: "Daft Punk", typed: ""))
    }
}
