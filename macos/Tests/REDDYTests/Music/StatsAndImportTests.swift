import Testing
import Foundation
@testable import REDDY

// Listening stats, history buckets, list ordering, Spotify import, matching, adaptive colour and the Music palette rules. Pure logic: no network, no audio, no screen.

private func tr(_ id: String, _ title: String = "T", artists: [(String, String)] = [("a1", "Artist")], provider: String = "audius", ms: Int64 = 200_000, album: (String, String)? = nil, explicit: Bool = false) -> MusicTrack {
    MusicTrack(id: id, providerID: provider, title: title, durationMs: ms, artists: artists.map { MusicArtistRef(id: $0.0, name: $0.1) },
               album: album.map { MusicAlbumRef(id: $0.0, title: $0.1) }, explicit: explicit)
}

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

@Suite struct PlayCountingTests {
    @Test func thresholdIsHalfTheTrackAtMostThirtySeconds() {
        #expect(MusicStatsRules.playThreshold(duration: 40) == 20)
        #expect(MusicStatsRules.playThreshold(duration: 200) == 30)
        #expect(MusicStatsRules.playThreshold(duration: 0) == 30)
        #expect(MusicStatsRules.playThreshold(duration: 1) == 30)
    }

    @Test func aPlayCountsOnceAtTheThreshold() {
        var c = MusicPlayCounter(); c.start(uid: "x")
        var events: [MusicPlayCounter.Event] = []
        _ = c.tick(position: 0, duration: 200, isPlaying: true)
        for i in 1...40 { events += c.tick(position: Double(i), duration: 200, isPlaying: true) }
        #expect(events == [.counted(secs: 30)])
    }

    @Test func seeksAndPausedTicksAddNoTime() {
        var c = MusicPlayCounter(); c.start(uid: "x")
        _ = c.tick(position: 0, duration: 200, isPlaying: true)
        _ = c.tick(position: 1, duration: 200, isPlaying: true)
        _ = c.tick(position: 60, duration: 200, isPlaying: true)         // a forward jump of 59 s is a seek
        _ = c.tick(position: 61, duration: 200, isPlaying: false)        // paused
        _ = c.tick(position: 62, duration: 200, isPlaying: false)
        #expect(c.heardSeconds == 1)
        #expect(c.latched)
    }

    @Test func timeIsRewrittenEveryThirtySecondsAndOnPause() {
        var c = MusicPlayCounter(); c.start(uid: "x")
        var events: [MusicPlayCounter.Event] = []
        _ = c.tick(position: 0, duration: 400, isPlaying: true)
        for i in 1...65 { events += c.tick(position: Double(i), duration: 400, isPlaying: true) }
        #expect(events == [.counted(secs: 30), .update(secs: 60)])
        let pause = c.tick(position: 65.5, duration: 400, isPlaying: false)
        #expect(pause == [.update(secs: 65)])
    }

    @Test func repeatOneRestartIsANewPlay() {
        var c = MusicPlayCounter(); c.start(uid: "x")
        var events: [MusicPlayCounter.Event] = []
        _ = c.tick(position: 0, duration: 40, isPlaying: true)
        for i in 1...25 { events += c.tick(position: Double(i), duration: 40, isPlaying: true) }
        events += c.tick(position: 0.2, duration: 40, isPlaying: true)
        for i in 1...25 { events += c.tick(position: Double(i), duration: 40, isPlaying: true) }
        let counted = events.filter { if case .counted = $0 { return true } else { return false } }
        #expect(counted.count == 2)
    }

    @Test func finishSettlesTheTimeHeard() {
        var c = MusicPlayCounter(); c.start(uid: "x")
        _ = c.tick(position: 0, duration: 40, isPlaying: true)
        for i in 1...25 { _ = c.tick(position: Double(i), duration: 40, isPlaying: true) }
        #expect(c.finish() == .update(secs: 25))
        #expect(c.uid == nil)
    }
}

@Suite struct StatsReportTests {
    private func file(_ rows: [(MusicTrack, Date, Int)]) -> MusicStatsFile {
        var f = MusicStatsFile()
        let math = MusicDayMath(calendar: utc)
        _ = math
        for (t, at, secs) in rows {
            f.listens.append(MusicListenRow(id: f.nextID, uid: t.uid, at: at, secs: secs)); f.nextID += 1
            let first = f.songs[t.uid]?.firstAt ?? at
            f.songs[t.uid] = MusicSongEntry(track: t, firstAt: min(first, at))
            if f.firstAt == nil || at < f.firstAt! { f.firstAt = at }
        }
        return f
    }

    @Test func rangesStartAtLocalMidnight() {
        let now = date(2026, 11, 25, 15)
        #expect(MusicStatsRange.week.start(now: now, calendar: utc) == date(2026, 11, 19, 0))
        #expect(MusicStatsRange.month.start(now: now, calendar: utc) == date(2026, 10, 27, 0))
        #expect(MusicStatsRange.year.start(now: now, calendar: utc) == date(2025, 12, 1, 0))
        #expect(MusicStatsRange.all.start(now: now, calendar: utc) == nil)
    }

    @Test func totalsTopListsAndOrdering() {
        let a = tr("1", "Alpha", artists: [("A", "Ann")], album: ("al1", "Album One")), b = tr("2", "Beta", artists: [("B", "Bob")], album: ("al2", "Album Two"))
        let now = date(2026, 11, 25, 15)
        var rows: [(MusicTrack, Date, Int)] = []
        for i in 0..<3 { rows.append((a, date(2026, 11, 20 + i, 10), 100)) }
        rows.append((b, date(2026, 11, 24, 21), 400))
        let r = MusicStatsEngine.report(file(rows), since: MusicStatsRange.week.start(now: now, calendar: utc), now: now, calendar: utc)
        #expect(r.plays == 4 && r.totalSecs == 700 && r.songs == 2 && r.artists == 2)
        #expect(r.topSongs.map(\.track.id) == ["1", "2"])        // plays desc
        #expect(r.topArtists.map(\.name) == ["Bob", "Ann"])      // time desc
        #expect(r.topAlbums.first?.title == "Album Two")
        #expect(r.newSongs == 2)
        #expect(r.hours[MusicDayMath.weekday(ofDay: MusicDayMath(calendar: utc).day(date(2026, 11, 24)))][21] == 400)
        #expect(r.busiestHour == 10 || r.busiestHour == 21)
    }

    @Test func longVideosCountTimeButNeverSongsOrArtists() {
        let song = tr("1", "Song", provider: "youtube-music", ms: 200_000)
        let mix = tr("2", "Two hour mix", artists: [("x", "Channel")], provider: "youtube-music", ms: 7_200_000)
        let podcastOnAudioSource = tr("3", "Long audio", provider: "audius", ms: 7_200_000)
        let now = date(2026, 11, 25)
        let r = MusicStatsEngine.report(file([(song, date(2026, 11, 24), 100), (mix, date(2026, 11, 24), 5000), (podcastOnAudioSource, date(2026, 11, 24), 60)]), since: nil, now: now, calendar: utc)
        #expect(r.plays == 3 && r.totalSecs == 5160)
        #expect(r.songs == 2)                                     // the mix is not a song; long audio is
        #expect(!r.topArtists.contains { $0.name == "Channel" })
    }

    @Test func collaborationCreditsEachArtistAndPlainLinesUseTheLeadName() {
        let collab = tr("1", artists: [("a", "Ann"), ("b", "Bob")])
        #expect(MusicStatsRules.credits(for: collab).map(\.name) == ["Ann", "Bob"])
        let plain = tr("2", artists: [("", "Drake feat. Future; Other")])
        #expect(MusicStatsRules.credits(for: plain).map(\.name) == ["Drake"])
        #expect(MusicStatsRules.leadName("Unknown artist") == nil)
        #expect(MusicStatsRules.leadName("  ") == nil)
        #expect(MusicStatsRules.leadName("A ft. B") == "A")
        #expect(MusicStatsRules.leadName("Tyler, The Creator & Friends") == "Tyler, The Creator & Friends")
    }

    @Test func streaksCurrentSurvivesUntilAWholeDayPasses() {
        #expect(MusicStatsEngine.streaks(days: [8, 9, 10], today: 10) == (3, 3))
        #expect(MusicStatsEngine.streaks(days: [8, 9, 10], today: 11) == (3, 3))
        #expect(MusicStatsEngine.streaks(days: [8, 9, 10], today: 12) == (0, 3))
        #expect(MusicStatsEngine.streaks(days: [1, 2, 3, 4, 20], today: 20) == (1, 4))
        #expect(MusicStatsEngine.streaks(days: [], today: 5) == (0, 0))
    }

    @Test func changeComparesWithTheWindowBefore() {
        let t = tr("1")
        let now = date(2026, 11, 25, 15)
        let rows = [(t, date(2026, 11, 10), 600), (t, date(2026, 11, 22), 900)]       // previous week 600, this week 900
        let r = MusicStatsEngine.report(file(rows), since: MusicStatsRange.week.start(now: now, calendar: utc), now: now, calendar: utc)
        #expect(r.prevSecs == 0 || r.prevSecs == 600)
        let month = MusicStatsEngine.report(file(rows + [(t, date(2026, 10, 5), 1000)]), since: MusicStatsRange.month.start(now: now, calendar: utc), now: now, calendar: utc)
        #expect(month.prevSecs == 1000)
        #expect(month.changePercent == 50)
        let all = MusicStatsEngine.report(file(rows), since: nil, now: now, calendar: utc)
        #expect(all.allTime && all.changePercent == nil)
    }

    @Test func heatLevelsAreFiveShades() {
        var r = MusicStatsReport()
        r.hours[1][8] = 100; r.hours[2][9] = 50; r.hours[3][10] = 1
        #expect(r.heatLevel(weekday: 1, hour: 8) == 4)
        #expect(r.heatLevel(weekday: 2, hour: 9) == 2)
        #expect(r.heatLevel(weekday: 3, hour: 10) == 1)
        #expect(r.heatLevel(weekday: 0, hour: 0) == 0)
        var q = MusicStatsReport()
        q.hours[1][3] = 10; q.hours[2][3] = 5; q.hours[4][9] = 12
        #expect(q.busiestWeekday == 4)
        #expect(q.busiestHour == 3)
    }

    @Test func onRepeatIsThirtyDaysTopTwentyWithoutLocalFiles() {
        let now = date(2026, 11, 25)
        var rows: [(MusicTrack, Date, Int)] = []
        let loud = tr("1"), local = tr("2", provider: "local"), old = tr("3")
        for _ in 0..<5 { rows.append((loud, date(2026, 11, 20), 60)) }
        for _ in 0..<9 { rows.append((local, date(2026, 11, 21), 60)) }
        for _ in 0..<9 { rows.append((old, date(2026, 9, 1), 60)) }
        let list = MusicStatsEngine.onRepeat(file(rows), now: now, calendar: utc)
        #expect(list.map(\.id) == ["1"])
        var many: [(MusicTrack, Date, Int)] = []
        for i in 0..<30 { many.append((tr("s\(i)"), date(2026, 11, 20), 60)) }
        #expect(MusicStatsEngine.onRepeat(file(many), now: now, calendar: utc).count == 20)
    }

    @Test func oldRowsFoldIntoRollupsWithoutLosingTotals() {
        var f = MusicStatsFile()
        let t = tr("1")
        f.songs[t.uid] = MusicSongEntry(track: t, firstAt: date(2026, 1, 1))
        f.firstAt = date(2026, 1, 1)
        for i in 0..<30 { f.listens.append(MusicListenRow(id: Int64(i), uid: t.uid, at: date(2026, 1, 1 + i % 20, 8 + i % 3), secs: 10)) }
        let before = MusicStatsEngine.report(f, since: nil, now: date(2026, 2, 1), calendar: utc)
        let folded = f.foldIfNeeded(cap: 20, batch: 5, math: MusicDayMath(calendar: utc))
        #expect(folded)
        #expect(f.listens.count == 15)
        let after = MusicStatsEngine.report(f, since: nil, now: date(2026, 2, 1), calendar: utc)
        #expect(after.plays == before.plays && after.totalSecs == before.totalSecs && after.bestStreak == before.bestStreak)
        #expect(after.hours == before.hours)
    }

    @Test func recordingKeepsFirstPlayAndHonoursTheCap() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = await MainActor.run { MusicStats(directory: dir, debounce: .milliseconds(5), calendar: utc) }
        await MainActor.run {
            s.recordCounted(tr("1"), secs: 40, at: date(2026, 3, 1))
            let id = s.recordCounted(tr("1"), secs: 10, at: date(2026, 3, 2))
            s.updateSecs(rowID: id, secs: 90)
            #expect(s.file.listens.map(\.secs) == [40, 90])
            #expect(s.file.songs["audius:1"]?.firstAt == date(2026, 3, 1))
            #expect(s.hasAnyPlays)
            s.flush()
            let again = MusicStats(directory: dir, calendar: utc)
            #expect(again.file.listens.count == 2)
            again.clear()
            #expect(!again.hasAnyPlays)
        }
        #expect(MusicStatsRules.playCap == 50_000)
    }
}

@Suite struct StatsViewLogicTests {
    @Test func durationFormat() {
        #expect(MusicStatsFormat.duration(20) == "0m")
        #expect(MusicStatsFormat.duration(60 * 59) == "59m")
        #expect(MusicStatsFormat.duration(42 * 3600 + 17 * 60) == "42h 17m")
        #expect(MusicStatsFormat.duration(5 * 3600) == "5h")
        #expect(MusicStatsFormat.duration(100 * 3600 + 20 * 60) == "100h")
    }

    @Test func chartBarsIncludeZeroDaysAndLabelTheNewest() {
        var r = MusicStatsReport()
        let now = date(2026, 11, 25, 15)
        let math = MusicDayMath(calendar: utc)
        r.todayDay = math.day(now); r.windowStartDay = r.todayDay - 6
        r.days[r.todayDay] = 600; r.days[r.todayDay - 3] = 300
        let (bars, monthly) = MusicStatsChartData.bars(r, range: .week, now: now, calendar: utc)
        #expect(!monthly && bars.count == 7 && bars.last?.secs == 600 && bars[3].secs == 300 && bars[0].secs == 0)
        #expect(MusicStatsChartData.labelled(count: 7, monthly: false) == [0, 1, 2, 3, 4, 5, 6])
        #expect(MusicStatsChartData.labelled(count: 30, monthly: false).last == 29)
        #expect(MusicStatsChartData.labelled(count: 30, monthly: false) == stride(from: 29, through: 0, by: -5).reversed().map { $0 })
        var y = MusicStatsReport()
        y.todayDay = r.todayDay; y.windowStartDay = math.day(date(2025, 12, 1))
        y.days[math.day(date(2026, 3, 3))] = 100; y.days[math.day(date(2026, 3, 9))] = 50
        let months = MusicStatsChartData.bars(y, range: .year, now: now, calendar: utc)
        #expect(months.monthly && months.bars.count == 12 && months.bars.first { $0.secs > 0 }?.secs == 150)
    }
}

@Suite struct HistoryBucketTests {
    @Test func bucketsUseLocalDays() {
        let now = date(2026, 11, 25, 15)
        func rec(_ d: Date) -> PlayRecord { PlayRecord(track: tr("x"), at: d, playedMs: 1000) }
        let recs = [rec(date(2026, 11, 25, 9)), rec(date(2026, 11, 24, 23)), rec(date(2026, 11, 22, 8)), rec(date(2026, 11, 15)), rec(date(2026, 10, 3)), rec(date(2026, 10, 1))]
        let b = MusicHistoryBuckets.buckets(recs, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(b.map(\.id).prefix(2) == ["today", "yesterday"])
        #expect(b[2].title == "Sunday")
        #expect(b[3].id == "last-week")
        #expect(b[4].title == "October 2026" && b[4].items.count == 2)
        #expect(b.flatMap(\.items).map(\.index) == [0, 1, 2, 3, 4, 5])
    }

    @Test func filterKeepsIndicesAndLimitCountsAcrossBuckets() {
        let now = date(2026, 11, 25)
        let recs = (0..<10).map { PlayRecord(track: tr("\($0)", $0 % 2 == 0 ? "Even song" : "Odd tune"), at: date(2026, 11, 25 - $0 / 5, 10), playedMs: 1) }
        let b = MusicHistoryBuckets.buckets(recs, now: now, calendar: utc)
        let f = MusicHistoryBuckets.filtered(b, query: "EVEN")
        #expect(f.flatMap(\.items).map(\.index) == [0, 2, 4, 6, 8])
        #expect(MusicHistoryBuckets.filtered(b, query: "zzz").isEmpty)
        #expect(MusicHistoryBuckets.limited(b, rows: 7).flatMap(\.items).count == 7)
        #expect(MusicHistoryBuckets.revealStep == 80)
    }
}

@Suite struct LibraryOrderingTests {
    private let lib: [MusicTrack] = [
        tr("1", "Track 10", artists: [("a", "Zed")], album: ("b", "B Album")), tr("2", "track 9", artists: [("a", "Zed")], album: ("a", "A Album")),
        tr("3", "Solo", artists: [("c", "Amy")]), tr("4", "Other", artists: [("c", "Amy")], album: ("b", "B Album")),
    ]

    @Test func titleSortIsNumericAwareAndStable() {
        #expect(MusicLibraryOrdering.sorted(lib, by: .title).map(\.id) == ["4", "3", "2", "1"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .title, descending: true).map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func artistTiesBreakOnTitle() {
        #expect(MusicLibraryOrdering.sorted(lib, by: .artist).map(\.id) == ["4", "3", "2", "1"])
    }

    @Test func albumSortKeepsAlbumOrderAndPutsAlbumlessLast() {
        #expect(MusicLibraryOrdering.sorted(lib, by: .album).map(\.id) == ["2", "1", "4", "3"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .album, descending: true).map(\.id) == ["1", "4", "2", "3"])
    }

    @Test func mostPlayedAndNewest() {
        let counts = ["audius:3": 5, "audius:1": 2]
        #expect(MusicLibraryOrdering.sorted(lib, by: .mostPlayed, playCounts: counts).map(\.id) == ["3", "1", "2", "4"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .mostPlayed, descending: true, playCounts: counts).map(\.id) == ["2", "4", "1", "3"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .newest).map(\.id) == ["4", "3", "2", "1"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .newest, arrivesNewestFirst: true).map(\.id) == ["1", "2", "3", "4"])
        #expect(MusicLibraryOrdering.sorted(lib, by: .default, descending: true).map(\.id) == ["4", "3", "2", "1"])
    }

    @Test func filterAndLocalSearchRanking() {
        #expect(MusicLibraryOrdering.filter(lib, query: " amy ").map(\.id) == ["3", "4"])
        #expect(MusicLibraryOrdering.filter(lib, query: "b alb").map(\.id) == ["1", "4"])
        let names = ["Night Drive Intro", "Drive", "Driven", "My drive home"]
        let hits = MusicLibraryOrdering.localSearch(names, query: "drive", title: { $0 }, text: { $0 })
        #expect(hits == ["Drive", "Night Drive Intro", "My drive home", "Driven"].sorted { a, b in
            func rank(_ s: String) -> Int { s.lowercased() == "drive" ? 0 : s.lowercased().hasPrefix("drive") ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : names.firstIndex(of: a)! < names.firstIndex(of: b)!
        })
        #expect(MusicLibraryOrdering.localSearch(names, query: "home my", title: { $0 }, text: { $0 }) == ["My drive home"])
    }

    @Test func reorderRules() {
        #expect(MusicLibraryOrdering.moveBefore(["a", "b", "c", "d"], moving: "d", before: "b") == ["a", "d", "b", "c"])
        #expect(MusicLibraryOrdering.moveBefore(["a", "b", "c"], moving: "a", before: nil) == ["b", "c", "a"])
        #expect(MusicLibraryOrdering.moveBefore(["a", "b"], moving: "a", before: "a") == nil)
        #expect(MusicLibraryOrdering.moveBefore(["a", "b"], moving: "z", before: "a") == nil)
        #expect(MusicLibraryOrdering.dropTarget(rows: ["a", "b"], hovered: "a", upperHalf: false) == "b")
        #expect(MusicLibraryOrdering.dropTarget(rows: ["a", "b"], hovered: "b", upperHalf: false) == nil)
        #expect(MusicLibraryOrdering.canReorder(filterActive: false, sort: .default, descending: false, selecting: false, saving: false))
        #expect(!MusicLibraryOrdering.canReorder(filterActive: true, sort: .default, descending: false, selecting: false, saving: false))
        #expect(!MusicLibraryOrdering.canReorder(filterActive: false, sort: .title, descending: false, selecting: false, saving: false))
    }

    @Test func columnsFitTheWidth() {
        let all = MusicLibraryOrdering.defaultColumns + [.yourPlays]
        #expect(MusicLibraryOrdering.fitting(all, width: 600) == [.addedBy, .plays, .duration])
        #expect(MusicLibraryOrdering.fitting(all, width: 700) == [.album, .addedBy, .plays, .duration])
        #expect(MusicLibraryOrdering.fitting(all, width: 900).contains(.dateAdded))
        #expect(MusicLibraryOrdering.parseColumns(["album", "bogus"]) == [.album])
        #expect(MusicLibraryOrdering.parseColumns(["bogus"]) == MusicLibraryOrdering.defaultColumns)
        #expect(MusicLibraryOrdering.offered(.init(onAlbumPage: true)).contains(.album) == false)
    }

    @Test func recentSearchesAndPins() {
        var l: [String] = []
        for q in ["a b", "  x  ", "A   B", ""] { l = MusicLibraryOrdering.addingRecentSearch(q, to: l) }
        #expect(l == ["A B", "x"])
        for i in 0..<15 { l = MusicLibraryOrdering.addingRecentSearch("q\(i)", to: l) }
        #expect(l.count == 10 && l.first == "q14")
        #expect(MusicLibraryOrdering.pinning("d", in: ["a", "b", "c"]) == nil)
        #expect(MusicLibraryOrdering.pinning("b", in: ["a", "b"]) == ["a", "b"])
    }
}

@Suite struct SpotifyImportParsingTests {
    @Test func linksInEveryShape() {
        #expect(SpotifyLink.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc") == SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M"))
        #expect(SpotifyLink.parse("open.spotify.com/intl-fr/album/4aawyAB9vmqN3uQ7FjRGTy")?.kind == .album)
        #expect(SpotifyLink.parse("https://open.spotify.com/embed/playlist/abc123")?.id == "abc123")
        #expect(SpotifyLink.parse("https://open.spotify.com/user/someone/playlist/xyz789")?.id == "xyz789")
        #expect(SpotifyLink.parse("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")?.kind == .track)
        #expect(SpotifyLink.parse("https://play.spotify.com/artist/abc")?.kind == .artist)
        #expect(SpotifyLink.parse("https://open.spotify.com/show/abc") == nil)
        #expect(SpotifyLink.parse("https://example.com/playlist/abc") == nil)
        #expect(SpotifyLink.parse("https://open.spotify.com/playlist/") == nil)
    }

    @Test func localFileUris() {
        let t = SpotifyLocalURI.decode("spotify:local:My+Artist:Some+Album:Fancy%20Title:215")
        #expect(t?.title == "Fancy Title" && t?.artists == ["My Artist"] && t?.album == "Some Album" && t?.durationMs == 215_000)
        #expect(SpotifyLocalURI.decode("spotify:local:a:b:c") == nil)
        #expect(SpotifyLocalURI.decode("spotify:local:a:b::10") == nil)
    }

    @Test func csvWithBomQuotesAndColumns() throws {
        let csv = "\u{FEFF}Track Name,Artist Name(s),Album Name,Duration (ms),Explicit,Track URI,Playlist Name\n\"Song, One\",\"A;B\",Alb,215000,true,spotify:track:abcdefghijklmnopqrstuv,Mix\nTwo,C,,3:05,no,,Mix\n,,,,,,Mix\nThree,D,,,,,Other\n"
        let lists = try SpotifyExportReader.lists(fromCSV: Data(csv.utf8), fileName: "file")
        #expect(lists.map(\.name) == ["Mix", "Other"])
        let mix = lists[0]
        #expect(mix.tracks.count == 2 && mix.skipped == 1)
        #expect(mix.tracks[0].title == "Song, One" && mix.tracks[0].artists == ["A", "B"] && mix.tracks[0].durationMs == 215_000 && mix.tracks[0].explicit == true && mix.tracks[0].spotifyID == "abcdefghijklmnopqrstuv")
        #expect(mix.tracks[1].durationMs == 185_000 && mix.tracks[1].explicit == false)
        #expect(throws: ImportError.csvColumns) { try SpotifyExportReader.lists(fromCSV: Data("foo,bar\n1,2\n".utf8), fileName: "x") }
        let noList = try SpotifyExportReader.lists(fromCSV: Data("title,artist\nA,B\n".utf8), fileName: "My Songs")
        #expect(noList.first?.name == "My Songs")
        #expect(SpotifyExportReader.duration("30") == 30_000 && SpotifyExportReader.duration("30000") == 30_000)
    }

    @Test func exportJSONPlaylistsAndLibrary() throws {
        let pl = #"{"playlists":[{"name":"Road","items":[{"track":{"trackName":"Hi","artistName":"Me","albumName":"Al","trackUri":"spotify:track:aaa"}},{"localTrack":{"uri":"spotify:local:x:y:Zed:60"}},{"episode":{"x":1}}]},{"name":"Empty","items":[]}]}"#
        let lists = try SpotifyExportReader.lists(fromJSON: Data(pl.utf8))
        #expect(lists.count == 1 && lists[0].tracks.count == 2 && lists[0].skipped == 1 && lists[0].tracks[0].spotifyID == "aaa")
        let lib = #"{"tracks":[{"artist":"A","album":"B","track":"C","uri":"spotify:track:ccc"}],"albums":[{"x":1}],"artists":[{"name":"n"}]}"#
        let l2 = try SpotifyExportReader.lists(fromJSON: Data(lib.utf8))
        #expect(l2.count == 1 && l2[0].kind == .liked && l2[0].name == "Liked Songs")
        #expect(throws: ImportError.unreadable) { try SpotifyExportReader.lists(fromJSON: Data("nope".utf8)) }
    }

    /// A zip with stored (uncompressed) entries, built by hand.
    private func storedZip(_ files: [(String, String)]) -> Data {
        var out = [UInt8](), dir = [UInt8]()
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        for (name, body) in files {
            let n = Array(name.utf8), b = Array(body.utf8), off = out.count
            out += le(0x04034b50, 4) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4) + le(b.count, 4) + le(b.count, 4) + le(n.count, 2) + le(0, 2) + n + b
            dir += le(0x02014b50, 4) + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4) + le(b.count, 4) + le(b.count, 4) + le(n.count, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(off, 4) + n
        }
        let start = out.count
        out += dir
        out += le(0x06054b50, 4) + le(0, 2) + le(0, 2) + le(files.count, 2) + le(files.count, 2) + le(dir.count, 4) + le(start, 4) + le(0, 2)
        return Data(out)
    }

    @Test func zipExportListsLikedFirstThenPlaylistsInNumericOrder() throws {
        func pl(_ n: String) -> String { #"{"playlists":[{"name":"\#(n)","items":[{"track":{"trackName":"T\#(n)","artistName":"A","albumName":"","trackUri":""}}]}]}"# }
        let zip = storedZip([("Spotify Account Data/Playlist10.json", pl("ten")), ("Spotify Account Data/Playlist2.json", pl("two")), ("Spotify Account Data/YourLibrary.json", #"{"tracks":[{"artist":"A","album":"B","track":"C","uri":""}]}"#), ("readme.txt", "x")])
        let lists = try SpotifyExportReader.lists(fromZip: zip)
        #expect(lists.map(\.name) == ["Liked Songs", "two", "ten"])
        #expect(throws: ImportError.unreadable) { try SpotifyExportReader.lists(fromZip: Data([1, 2, 3])) }
    }

    @Test func embedPageIsReadAndPrivateListsAreRecognised() throws {
        let json = #"{"props":{"pageProps":{"state":{"settings":{"session":{"accessToken":"tok"}},"data":{"entity":{"name":"Mix","subtitle":"Owner","trackList":[{"uri":"spotify:track:t1","title":"One","subtitle":"A, B","duration":200000,"isExplicit":true,"entityType":"track"},{"uri":"spotify:episode:e1","title":"Pod","subtitle":"X","entityType":"episode"}],"visualIdentity":{"image":[{"url":"small","maxWidth":64},{"url":"big","maxWidth":640}]}}}}}}}"#
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
        let list = try SpotifyEmbedParser.parse(html: Data(html.utf8), link: SpotifyLink(kind: .playlist, id: "p"))
        #expect(list.name == "Mix" && list.owner == "Owner" && list.coverURL == "big")
        #expect(list.tracks.count == 1 && list.skipped == 1 && list.tracks[0].artists == ["A", "B"] && list.tracks[0].explicit == true && !list.truncated)
        let priv = "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"status\":404}}}</script>"
        #expect(throws: ImportError.private) { try SpotifyEmbedParser.parse(html: Data(priv.utf8), link: SpotifyLink(kind: .playlist, id: "p")) }
        #expect(throws: ImportError.spotifyChanged) { try SpotifyEmbedParser.parse(html: Data("<html></html>".utf8), link: SpotifyLink(kind: .playlist, id: "p")) }
    }
}

@Suite struct ImportMatcherTests {
    private func src(_ title: String, _ artists: [String] = ["Artist"], ms: Int64? = 200_000, album: String? = nil, explicit: Bool? = nil) -> ImportSourceTrack {
        ImportSourceTrack(spotifyID: nil, title: title, artists: artists, album: album, durationMs: ms, explicit: explicit)
    }

    @Test func normalisation() {
        #expect(ImportMatcher.norm("Rock & Roll's  Café!") == "rock and rolls cafe")
        #expect(ImportMatcher.norm("日本語 テスト") == "日本語 テスト")
    }

    @Test func dressingSplitsBracketsDashTailsAndFeat() {
        #expect(ImportMatcher.dressing("Song (Live at X) [Remix]") == ImportDressing(base: "Song", dressing: "Live at X  Remix"))
        #expect(ImportMatcher.dressing("Song - 2011 Remaster").base == "Song")
        #expect(ImportMatcher.dressing("Song feat. Someone").base == "Song")
        #expect(ImportMatcher.dressing("(Intro)").base == "(Intro)")
        #expect(ImportMatcher.versionSet("Live at X") == ["live"])
        #expect(ImportMatcher.versionSet("Remastered radio edit mono").isEmpty)
        #expect(ImportMatcher.searchQuery(for: src("Song (Acoustic)", ["A", "B"])) == "Song acoustic A")
    }

    @Test func similarityMeasures() {
        #expect(ImportMatcher.dice("Night", "night") == 1)
        #expect(ImportMatcher.dice("abc", "xyz") == 0)
        #expect(ImportMatcher.jaroWinkler("martha", "marhta") > 0.95)
        #expect(ImportMatcher.durationScore(200_000, 203_000) == 1)
        #expect(ImportMatcher.durationScore(200_000, 220_000) == 0)
        #expect(ImportMatcher.durationScore(200_000, 211_500) == 1 - 8.5 / 17)
    }

    @Test func artistScoring() {
        #expect(ImportMatcher.artistScore(source: [], candidateArtists: ["x"], candidateTitle: "t") == 0.5)
        #expect(ImportMatcher.artistScore(source: ["Adele"], candidateArtists: ["Adele"], candidateTitle: "t") == 1)
        #expect(abs(ImportMatcher.artistScore(source: ["Adele", "Bob"], candidateArtists: ["Adele"], candidateTitle: "t") - 0.7) < 1e-9)
        #expect(abs(ImportMatcher.artistScore(source: ["Adele", "Bob"], candidateArtists: ["Adele", "Bob"], candidateTitle: "t") - 1.0) < 1e-9)
        #expect(abs(ImportMatcher.artistScore(source: ["Bob", "Adele"], candidateArtists: ["Adele"], candidateTitle: "t") - 0.35) < 1e-9)
        #expect(ImportMatcher.artistScore(source: ["Adele"], candidateArtists: ["Channel"], candidateTitle: "Adele - Hello (Official)") == 1)
    }

    @Test func tiersAndPenalties() {
        let s = src("Hello", ["Adele"], album: "25")
        let exact = tr("1", "Hello", artists: [("a", "Adele")], ms: 200_000, album: ("al", "25"))
        let live = tr("2", "Hello (Live)", artists: [("a", "Adele")], ms: 200_000, album: ("al", "25"))
        let other = tr("3", "Something Else", artists: [("z", "Other")], ms: 90_000)
        #expect(ImportMatcher.score(source: s, candidate: exact) == 1)
        #expect(ImportMatcher.score(source: s, candidate: live) < 0.8)       // the version words differ
        #expect(ImportMatcher.tier(ImportMatcher.score(source: s, candidate: exact)) == .matched)
        #expect(ImportMatcher.tier(ImportMatcher.score(source: s, candidate: other)) == .missing)
        #expect(ImportMatcher.tier(0.80) == .matched && ImportMatcher.tier(0.79) == .check && ImportMatcher.tier(0.55) == .check && ImportMatcher.tier(0.54) == .missing)
        let far = tr("4", "Hello", artists: [("a", "Adele")], ms: 260_000, album: ("al", "25"))
        #expect(ImportMatcher.score(source: s, candidate: far) < ImportMatcher.score(source: s, candidate: exact) - 0.1)
        let ranked = ImportMatcher.rank(source: s, results: [other, exact, exact, live])
        #expect(ranked.first?.track.id == "1" && ranked.count == 3)
    }

    @Test func cacheKeysAndMissingRetry() async {
        #expect(src("Hello (Live)", ["Adele"]).key == "~hello live|adele")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await MainActor.run {
            let c = ImportMatchCache(directory: dir, debounce: .milliseconds(5))
            let now = Date()
            c.set(ImportMatchRecord(key: "m", tier: .missing, updatedAt: now.addingTimeInterval(-8 * 86_400)))
            c.set(ImportMatchRecord(key: "p", tier: .missing, manual: true, updatedAt: now.addingTimeInterval(-30 * 86_400)))
            c.set(ImportMatchRecord(key: "ok", tier: .matched, pick: tr("1"), updatedAt: now))
            #expect(c.lookup("m", now: now) == nil)
            #expect(c.lookup("p", now: now) != nil && c.lookup("ok", now: now) != nil)
            c.clearCaches()
            #expect(c.records.keys.sorted() == ["p"])
        }
    }
}

@Suite struct ImportPacingAndUpdateTests {
    @Test func budgetAllowsSixHundredSearchesAnHourThenWaits() {
        var b = ImportBudget()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<600 { #expect(b.admit(now: t0) == .go) }
        #expect(b.admit(now: t0.addingTimeInterval(10)) == .wait(until: t0.addingTimeInterval(3600)))
        #expect(b.admit(now: t0.addingTimeInterval(3601)) == .go)
        b.trip(now: t0.addingTimeInterval(4000))
        #expect(b.admit(now: t0.addingTimeInterval(4100)) == .cooldown(until: t0.addingTimeInterval(7600)))
        #expect(b.admit(now: t0.addingTimeInterval(7601)) == .go)
    }

    @Test func pacing() {
        #expect(abs(ImportPacing.delay(afterRequest: 1, random: { $0.lowerBound }) - 1.2) < 1e-9)
        #expect(abs(ImportPacing.delay(afterRequest: 40, random: { $0.lowerBound }) - 16.2) < 1e-9)
        #expect(abs(ImportPacing.delay(afterRequest: 3, random: { $0.upperBound }) - 2.0) < 1e-9)
    }

    @Test func updatePlanAddsNewRemovesGoneAndKeepsSharedSongs() {
        let uid: (String) -> String? = { ["k1": "u1", "k2": "u2", "k3": "u3", "k4": "u3", "k5": "u5"][$0] }
        let plan = ImportUpdate.plan(previousKeys: ["k1", "k2", "k3"], newKeys: ["k1", "k4", "k5"], currentUIDs: ["u1", "u2", "u3", "manual"], uid: uid)
        #expect(plan.add == ["u5"])
        #expect(plan.remove == ["u2"])           // u3 stays: k4 still maps to it
    }

    @Test func orderPutsSpotifySongsInSpotifyOrderAroundManualRows() {
        let cur = ["a", "m1", "b", "m2", "c"]
        #expect(ImportUpdate.order(current: cur, spotify: ["c", "a", "b"]) == ["c", "m1", "a", "m2", "b"])
        #expect(ImportUpdate.order(current: ["a", "b", "a"], spotify: ["b", "a"]) == ["b", "a", "a"])
    }

    @Test func minimalMovesMoveOnlyWhatIsNeeded() {
        let current = ["a", "b", "c", "d", "e"]
        let top = ["e", "a", "b", "c", "d"]
        let m1 = ImportUpdate.minimalMoves(current: current, target: top)
        #expect(m1.count == 1)
        #expect(ImportUpdate.apply(m1, to: current) == top)
        for target in [["c", "b", "a", "e", "d"], ["b", "a", "d", "c", "e"], current] {
            let m = ImportUpdate.minimalMoves(current: current, target: target)
            #expect(ImportUpdate.apply(m, to: current) == target)
        }
        #expect(ImportUpdate.minimalMoves(current: current, target: current).isEmpty)
    }

    @Test func autoUpdateSchedule() {
        let now = Date(timeIntervalSince1970: 100 * 3600)
        let recs = ["a": SpotifySourceRecord(url: "u", keys: [], auto: true, checked: now.addingTimeInterval(-7 * 3600)),
                    "b": SpotifySourceRecord(url: "u", keys: [], auto: true, checked: now.addingTimeInterval(-30 * 3600)),
                    "c": SpotifySourceRecord(url: "u", keys: [], auto: true, checked: now.addingTimeInterval(-3600)),
                    "d": SpotifySourceRecord(url: "u", keys: [], auto: false, checked: now.addingTimeInterval(-30 * 3600))]
        #expect(ImportUpdate.due(recs, now: now) == ["b", "a"])
    }

    @Test func importMessagesCoverEveryCode() {
        for e: ImportError in [.private, .notSpotify, .notAList, .empty, .spotifyChanged, .unreadable, .csvColumns, .busy, .nothingRead, .gone, .cooldown(until: Date()), .network("x")] {
            #expect(!ImportMessages.text(e).isEmpty)
        }
    }
}

@Suite struct AdaptiveColorTests {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, a: UInt8 = 255, count: Int = 1024) -> [UInt8] { (0..<count).flatMap { _ in [r, g, b, a] } }

    @Test func dominantColourFavoursSaturatedMidBrightPixels() throws {
        var px = solid(250, 250, 250, count: 800)                      // a mostly white cover
        px += solid(200, 30, 40, count: 200)                            // with a red patch
        let c = try #require(MusicAdaptiveColor.dominant(rgba: px))
        #expect(c.r > 0.7 && c.g < 0.2)
        #expect(MusicAdaptiveColor.dominant(rgba: solid(128, 128, 128)) == nil)             // grey: no colour
        #expect(MusicAdaptiveColor.dominant(rgba: solid(255, 0, 0, a: 100)) == nil)         // transparent pixels ignored
    }

    @Test func bandingHitsTheTargetBrightnessAndKeepsHue() {
        let teal = MusicRGB(0.1, 0.7, 0.6)
        let dark = MusicAdaptiveColor.toAccent(teal, dark: true), light = MusicAdaptiveColor.toAccent(teal, dark: false)
        #expect(abs(MusicAdaptiveColor.brightness(dark) - 0.65) < 0.02)
        #expect(abs(MusicAdaptiveColor.brightness(light) - 0.39) < 0.02)
        #expect(abs(MusicAdaptiveColor.hsv(dark).h - MusicAdaptiveColor.hsv(teal).h) < 5)
        let navy = MusicRGB(0.0, 0.0, 0.8)
        let band = MusicAdaptiveColor.toAccent(navy, dark: true)
        #expect(MusicAdaptiveColor.hsv(band).s >= 0.3)
        #expect(abs(MusicAdaptiveColor.brightness(band) - 0.65) < 0.03)
    }

    @Test func lightnessReferencePoints() {
        func hex(_ v: Int) -> MusicRGB { MusicRGB(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255) }
        #expect(MusicAdaptiveColor.isLight(hex(0xa3e635)) && MusicAdaptiveColor.isLight(hex(0x5eead4)))
        #expect(!MusicAdaptiveColor.isLight(hex(0x6366f1)) && !MusicAdaptiveColor.isLight(MusicRGB(0, 0, 0)))
    }

    @Test func oklchRoundTripAndFills() {
        let c = MusicAdaptiveColor.oklch(0.7, 0.08, 200)
        #expect(abs(MusicAdaptiveColor.oklchHue(c) - 200) < 2)
        let dark = MusicAdaptiveColor.fills(hue: 200, dark: true), light = MusicAdaptiveColor.fills(hue: 200, dark: false)
        #expect(MusicAdaptiveColor.brightness(dark.background) < MusicAdaptiveColor.brightness(light.background))
        #expect(MusicAdaptiveColor.brightness(dark.card) > MusicAdaptiveColor.brightness(dark.background))
    }

    @Test func washBlurAndOpacityCaps() {
        let n = 16
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) { let v: UInt8 = i % n < n / 2 ? 0 : 255; px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v }
        let baked = MusicCoverWash.bake(rgba: px, side: n, radius: 3)
        #expect(baked.rgba.count == px.count && baked.darkest < baked.brightest)
        #expect(MusicCoverWash.opacity(dark: true, darkest: 0, brightest: 0.4) == 0.5)
        #expect(MusicCoverWash.opacity(dark: true, darkest: 0, brightest: 0.1) == 1)
        #expect(abs(MusicCoverWash.opacity(dark: false, darkest: 0.5, brightest: 1) - 0.3) < 1e-9)
    }
}

@Suite struct LocalGapTests {
    private func e(_ title: String, artist: String = "A", album: String = "Al", path: String, albumArtist: String? = nil, disc: Int? = nil, track: Int? = nil, tagged: Bool? = nil) -> LocalEntry {
        LocalEntry(id: LocalLibraryIndex.trackID(path: path), folderID: "f", path: path, title: title, artist: artist, album: album, trackNumber: track, durationMs: 1000,
                   modified: Date(timeIntervalSince1970: 0), artworkFile: nil, ext: "mp3", albumArtist: albumArtist, discNumber: disc, albumTagged: tagged)
    }

    @Test func compilationStaysOneAlbumAndSameNamesInOtherFoldersStayApart() {
        let idx = LocalLibraryIndex(entries: [
            e("a", artist: "X", album: "Hits", path: "/m/hits/1.mp3"), e("b", artist: "Y", album: "Hits", path: "/m/hits/2.mp3"),
            e("c", artist: "X", album: "Hits", path: "/m/other/3.mp3"),
        ])
        let albums = idx.albums()
        #expect(albums.count == 2)
        #expect(albums.first { $0.entries.count == 2 }?.artist == "Various artists")
        #expect(albums.first { $0.entries.count == 1 }?.artist == "X")
    }

    @Test func albumArtistTagGroupsAcrossFoldersAndCreditsIt() {
        let idx = LocalLibraryIndex(entries: [e("a", artist: "X", album: "Disc", path: "/m/cd1/1.mp3", albumArtist: "Band", disc: 1, track: 1), e("b", artist: "Y", album: "Disc", path: "/m/cd2/1.mp3", albumArtist: "Band", disc: 2, track: 1)])
        let g = idx.albums()
        #expect(g.count == 1 && g[0].artist == "Band" && g[0].entries.map(\.title) == ["a", "b"])
    }

    @Test func untaggedAlbumUsesTheFolderAndDiscNumberWins() {
        let untagged = e("t", album: "Folder Name", path: "/m/Folder Name/t.mp3", tagged: false)
        #expect(LocalLibraryIndex.albumKey(of: untagged).hasPrefix("dir-"))
        let d1 = e("late", path: "/m/x/a.mp3", albumArtist: "B", disc: 1, track: 9), d2 = e("early", path: "/m/x/b.mp3", albumArtist: "B", disc: 2, track: 1)
        #expect(LocalLibraryIndex.trackOrder(d1, d2))
    }

    @Test func albumKeysAreFixedAndSanitised() {
        #expect(LocalLibraryIndex.fnv12("") == "9ce484222325")        // the low 48 bits of the FNV-1a offset basis
        #expect(LocalLibraryIndex.fnv12("a") == LocalLibraryIndex.fnv12("a") && LocalLibraryIndex.fnv12("a").count == 12)
        #expect(LocalLibraryIndex.sanitizeKey("Band -- Disc: 1!") == "band----disc--1-")
        let long = String(repeating: "x", count: 100)
        #expect(LocalLibraryIndex.sanitizeKey(long).count == 92)
    }

    @Test func primaryArtistRuleKeepsCommasAndAmpersands() {
        let idx = LocalLibraryIndex(entries: [e("a", artist: "Drake feat. Future", path: "/1.mp3"), e("b", artist: "Drake", path: "/2.mp3"), e("c", artist: "Tyler, The Creator", path: "/3.mp3"), e("d", artist: "Simon & Garfunkel", path: "/4.mp3")])
        #expect(idx.artists().map(\.name).sorted() == ["Drake", "Simon & Garfunkel", "Tyler, The Creator"])
        #expect(idx.artists().first { $0.name == "Drake" }?.entries.count == 2)
        // The id an older release gave the whole credit still opens the right artist.
        #expect(idx.artist(id: LocalLibraryIndex.artistID("Drake feat. Future"))?.name == "Drake")
    }

    @Test func fileNameFallbackAndExtensions() {
        let split = LocalTagText.artistAndTitle(fromFileName: "07 - Artist - Song Name.mp3")
        #expect(split.artist == "Artist" && split.title == "Song Name")
        #expect(LocalTagText.artistAndTitle(fromFileName: "Just A Title.flac").artist == nil)
        #expect(LocalTagText.artistAndTitle(fromFileName: "Artist - .mp3").artist == nil)
        #expect(LocalLibraryIndex.audioExtensions.isSuperset(of: ["m4b", "aif"]))
        #expect(LocalTagText.coverFileNames == ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "album.jpg"])
    }

    @Test func singleWordSearchPutsExactTitlesFirst() {
        let idx = LocalLibraryIndex(entries: [e("Long Night Drive", path: "/1.mp3"), e("Night", path: "/2.mp3"), e("Nightfall", path: "/3.mp3")])
        #expect(idx.search("night").tracks.first?.title == "Night")
    }

    @Test func oldIndexFilesStillDecode() throws {
        let old = #"{"version":1,"entries":[{"id":"i","folderID":"f","path":"/a.mp3","title":"T","artist":"A","album":"B","durationMs":1,"modified":0,"ext":"mp3"}]}"#
        let idx = try JSONDecoder().decode(LocalLibraryIndex.self, from: Data(old.utf8))
        #expect(idx.entries.count == 1 && idx.entries[0].albumArtist == nil && idx.scanVersion == nil)
    }
}

@Suite(.serialized) struct PaletteAndSearchTests {
    @Test func paletteRules() {
        #expect(!MusicPaletteRules.shouldSearch("a") && !MusicPaletteRules.shouldSearch(" a ") && MusicPaletteRules.shouldSearch("ab"))
        #expect(MusicPaletteRules.debounce == .milliseconds(300))
        #expect(MusicPaletteRules.isCurrent(reply: "abc", now: " abc ") && !MusicPaletteRules.isCurrent(reply: "ab", now: "abc"))
        #expect(MusicPaletteRules.move(nil, by: 1, count: 3) == 0 && MusicPaletteRules.move(nil, by: -1, count: 3) == 2)
        #expect(MusicPaletteRules.move(2, by: 1, count: 3) == 0 && MusicPaletteRules.move(0, by: -1, count: 3) == 2)
        #expect(MusicPaletteRules.move(0, by: 1, count: 0) == nil)
    }

    @Test func musicIsAResultKindButNotConnectedByDefault() async {
        #expect(SearchResultKind.allCases.last == .music)
        MusicGlobalSearch.uninstall()
        #expect(!MusicGlobalSearch.isInstalled)
        #expect(await MusicGlobalSearch.rows(for: "anything").isEmpty)
        let empty = GlobalSearchResults(query: "q")
        let out = await GlobalSearchService.withMusic(empty, query: "q", kinds: Set(SearchResultKind.allCases), limit: 5)
        #expect(out.byKind[.music] == nil)
    }

    @Test func musicRowsAreRankedAndLimitedWhenConnected() async {
        let row = SearchResult(id: "music:track:x:1", kind: .music, title: "Hello", subtitle: "Adele", sourceID: nil, sourceName: "Src", artworkURL: nil, destination: .music(.track(tr("1", "Hello"))), score: 1000)
        // Connect a stand-in the way the hub does, without a registry.
        MusicGlobalSearch.installForTesting { _, _ in [row] }
        defer { MusicGlobalSearch.uninstall() }
        let out = await GlobalSearchService.withMusic(GlobalSearchResults(query: "he"), query: "he", kinds: [.music], limit: 5)
        #expect(out.byKind[.music]?.map(\.id) == ["music:track:x:1"])
        let none = await GlobalSearchService.withMusic(GlobalSearchResults(query: "h"), query: "h", kinds: [.music], limit: 5)
        #expect(none.byKind[.music] == nil)                      // under two characters Music is never asked
        let other = await GlobalSearchService.withMusic(GlobalSearchResults(query: "he"), query: "he", kinds: [.movie], limit: 5)
        #expect(other.byKind[.music] == nil)
        if case .music(.track(let t)) = row.destination { #expect(t.id == "1") } else { Issue.record("destination") }
    }
}


@Suite struct VideoFlagStatsTests {
    private let long: Int64 = 7_200_000

    @Test func theVideoFlagDecidesWhenSet() {
        var flaggedSong = tr("1", provider: "youtube-music", ms: long); flaggedSong.isVideo = false
        var flaggedVideo = tr("2", provider: "audius", ms: long); flaggedVideo.isVideo = true
        #expect(MusicStatsRules.isSong(flaggedSong))            // a long track the service calls a song stays a song
        #expect(!MusicStatsRules.isSong(flaggedVideo))          // a long video counts as no song even from a source that is normally audio
        flaggedVideo.durationMs = 600_000
        #expect(MusicStatsRules.isSong(flaggedVideo))           // under 15 minutes is a song either way
    }

    @Test func theProviderListIsOnlyTheFallback() {
        #expect(!MusicStatsRules.isSong(tr("1", provider: "youtube-music", ms: long)))
        #expect(MusicStatsRules.isSong(tr("2", provider: "audius", ms: long)))
        #expect(MusicStatsRules.isSong(tr("3", provider: "piped", ms: 0)))
    }

    @Test func oldSavedTracksStillDecode() throws {
        let old = #"{"id":"x","providerID":"audius","title":"T","durationMs":1000,"artists":[],"thumbnails":[],"explicit":false}"#
        let t = try JSONDecoder().decode(MusicTrack.self, from: Data(old.utf8))
        #expect(t.isVideo == nil)
        var v = t; v.isVideo = true
        let back = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(v))
        #expect(back.isVideo == true)
        let s = try JSONDecoder().decode(MusicStream.self, from: Data(#"{"url":"u","codec":"c","container":"m","proto":"hls","headers":{}}"#.utf8))
        #expect(s.hasVideo == nil)
    }

    @Test func youTubeMusicRowsSetTheFlagFromTheirVideoType() {
        func node(_ type: String?) -> [String: Any] { type.map { ["overlay": ["musicItemThumbnailOverlayRenderer": ["content": ["musicPlayButtonRenderer": ["playNavigationEndpoint": ["watchEndpoint": ["watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": $0]]]]]]]]] } ?? [:] }
        #expect(YTMItems.videoFlag(of: node("MUSIC_VIDEO_TYPE_OMV")) == true)
        #expect(YTMItems.videoFlag(of: node("MUSIC_VIDEO_TYPE_UGC")) == true)
        #expect(YTMItems.videoFlag(of: node("MUSIC_VIDEO_TYPE_ATV")) == false)
        #expect(YTMItems.videoFlag(of: node("MUSIC_VIDEO_TYPE_PODCAST_EPISODE")) == false)
        #expect(YTMItems.videoFlag(of: node(nil)) == nil)
    }
}
