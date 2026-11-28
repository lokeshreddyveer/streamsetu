import Testing
import Foundation
@testable import REDDY

// Playlist management as behaviour: repeats, merging, files in and out, rule-based smart playlists, and the numbers a playlist shows. Synthetic songs only.

private enum PT {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func song(_ n: Int, _ title: String? = nil, artist: String = "Ada", ms: Int64 = 200_000, isrc: String? = nil, provider: String = "p", album: String? = nil, released: String? = nil) -> MusicTrack {
        var t = MusicTrack(id: "t\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: ms, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])
        t.isrc = isrc
        if let album { t.album = MusicAlbumRef(id: "al-" + album, title: album, releaseDate: released) }
        return t
    }
}

@Suite("Duplicate detection") struct PlaylistDuplicateTests {
    @Test func theSameRecordingIsFoundByIdIsrcOrTitleAndLength() {
        let a = PT.song(1, "Tum Hi Ho", artist: "Arijit")
        let sameID = a
        let sameISRC = PT.song(2, "Totally different title", artist: "Other", isrc: "INX123")
        let withISRC = PT.song(3, "Another", artist: "Another", isrc: "inx123")
        let sameWords = PT.song(4, "Tum  hi HO", artist: "arijit", ms: 201_500, provider: "q")
        #expect(MusicPlaylistDuplicates.same(a, sameID))
        #expect(MusicPlaylistDuplicates.same(sameISRC, withISRC))
        #expect(MusicPlaylistDuplicates.same(a, sameWords))
    }

    @Test func aRemixOrALongerVersionIsNotARepeat() {
        let a = PT.song(1, "Tum Hi Ho", artist: "Arijit")
        #expect(!MusicPlaylistDuplicates.same(a, PT.song(2, "Tum Hi Ho (Remix)", artist: "Arijit")))
        #expect(!MusicPlaylistDuplicates.same(a, PT.song(3, "Tum Hi Ho", artist: "Arijit", ms: 330_000)))
        #expect(!MusicPlaylistDuplicates.same(a, PT.song(4, "Tum Hi Ho", artist: "Someone Else")))
        // Unknown length cannot tell two copies apart.
        #expect(MusicPlaylistDuplicates.same(a, PT.song(5, "Tum Hi Ho", artist: "Arijit", ms: 0)))
    }

    @Test func groupsKeepListOrderAndACleanUpKeepsTheFirstCopy() {
        let list = [PT.song(1, "A"), PT.song(2, "B"), PT.song(3, "A", provider: "q"), PT.song(4, "C"), PT.song(5, "B", provider: "r"), PT.song(6, "A", provider: "s")]
        let g = MusicPlaylistDuplicates.groups(list)
        #expect(g.count == 2 && g[0].indices == [0, 2, 5] && g[1].indices == [1, 4])
        let r = MusicPlaylistDuplicates.removing(list)
        #expect(r.kept.map(\.id) == ["t1", "t2", "t4"] && r.removed.count == 3)
        #expect(MusicPlaylistDuplicates.extraCopies(list) == 3)
        #expect(MusicPlaylistDuplicates.groups([]).isEmpty && MusicPlaylistDuplicates.removing([PT.song(1)]).removed.isEmpty)
    }

    @Test func aLongListIsCheckedQuickly() {
        let list = (0..<5_000).map { PT.song($0, "Title \($0 % 2_500)", artist: "A\(($0 % 2_500) % 7)", provider: "p\($0 / 2_500)") }
        let started = Date()
        let extra = MusicPlaylistDuplicates.extraCopies(list)
        #expect(extra == 2_500 && Date().timeIntervalSince(started) < 2)
    }
}

@Suite("Merging playlists") struct PlaylistMergeTests {
    @Test func listsJoinInOrderAndRepeatsAreLeftOutByDefault() {
        let a = [PT.song(1, "One"), PT.song(2, "Two")], b = [PT.song(3, "Two", provider: "q"), PT.song(4, "Four")], c = [PT.song(5, "One", provider: "r")]
        #expect(MusicPlaylistMerge.merge([a, b, c]).map(\.title) == ["One", "Two", "Four"])
        #expect(MusicPlaylistMerge.merge([a, b, c], dropRepeats: false).count == 5)
        #expect(MusicPlaylistMerge.merge([]).isEmpty)
    }

    @Test func theMergedNameIsShortAndNeverEmptyForRealNames() {
        #expect(MusicPlaylistMerge.name(for: ["Gym", "Road trip"]) == "Gym + Road trip")
        #expect(MusicPlaylistMerge.name(for: ["A", "B", "C", "D", "E"]) == "A + B + C +2")
        #expect(MusicPlaylistMerge.name(for: ["", "  "]) == "")
        #expect(MusicPlaylistMerge.name(for: [String(repeating: "x", count: 100)], limit: 20).count == 20)
    }
}

@Suite("Playlist files") struct PlaylistFileTests {
    @Test func m3uRoundTripsTitlesArtistsAndLengths() {
        let list = [PT.song(1, "Naatu Naatu", artist: "Rahul", ms: 208_000, album: "RRR"), PT.song(2, "Chikiri", artist: "Mohit", ms: 274_000)]
        let text = MusicPlaylistM3U.export(name: "Telugu hits", tracks: list)
        #expect(text.hasPrefix("#EXTM3U\n#PLAYLIST:Telugu hits\n"))
        let back = MusicPlaylistM3U.parse(text)
        #expect(back.name == "Telugu hits" && back.entries.count == 2)
        #expect(back.entries[0].title == "Naatu Naatu" && back.entries[0].artists == ["Rahul"] && back.entries[0].durationSeconds == 208 && back.entries[0].album == "RRR")
        #expect(back.entries[1].album == nil)
        #expect(back.entries[0].location?.hasPrefix("streamsetu://track/p/") == true)
    }

    @Test func m3uReadsWindowsLineEndsAByteOrderMarkAndFileNamesWithoutExtinf() {
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:-1,Plain title\r\nhttps://example.test/a.mp3\r\n\r\n/Music/01 - Ada - Night Drive.mp3\r\nrelative/02. Just A Name.flac\r\n"
        let f = MusicPlaylistM3U.parse(text)
        #expect(f.entries.map(\.title) == ["Plain title", "Night Drive", "Just A Name"])
        #expect(f.entries[0].durationSeconds == nil && f.entries[1].artists == ["Ada"] && f.entries[2].artists.isEmpty)
        #expect(MusicPlaylistM3U.parse("").entries.isEmpty && MusicPlaylistM3U.parse("#EXTM3U\n").entries.isEmpty)
    }

    @Test func m3uKeepsUnicodeAndEncodedNames() {
        let text = "#EXTM3U\n#EXTINF:200,గాయకుడు - పాట\n/m/%E0%B0%AA%E0%B0%BE%E0%B0%9F.mp3\n/m/%E0%B0%AA%E0%B0%BE%E0%B0%9F2.mp3\n"
        let f = MusicPlaylistM3U.parse(text)
        #expect(f.entries.count == 2 && f.entries[0].title == "పాట" && f.entries[0].artists == ["గాయకుడు"])
        #expect(f.entries[1].title == "పాట2")
    }

    @Test func jsonRoundTripsAndKeepsTheSongsTheAppAlreadyKnew() throws {
        let list = [PT.song(1, "One", artist: "Ada", isrc: "ISRC1", album: "Alb"), PT.song(2, "Two", artist: "Bo")]
        let data = try MusicPlaylistJSON.export(name: "Mine", description: "Notes", tracks: list)
        let f = MusicPlaylistJSON.parse(data)
        #expect(f.name == "Mine" && f.description == "Notes" && f.entries.count == 2)
        #expect(f.entries[0].known?.uid == "p:t1" && f.entries[0].isrc == "ISRC1" && f.entries[0].album == "Alb")
        #expect(f.entries[1].known?.title == "Two")
    }

    @Test func jsonReadsOtherToolsShapesAndRefusesNonsense() {
        let bare = Data(#"[{"title":"A","artist":"X"},{"name":"B","artists":[{"name":"Y"},{"name":"Z"}],"duration_ms":180000}]"#.utf8)
        let f = MusicPlaylistJSON.parse(bare)
        #expect(f.entries.count == 2 && f.entries[0].artists == ["X"] && f.entries[1].artists == ["Y", "Z"] && f.entries[1].durationSeconds == 180)
        let wrapped = Data(#"{"title":"Road","items":[{"title":"A"},{"nothing":1}]}"#.utf8)
        #expect(MusicPlaylistJSON.parse(wrapped).name == "Road" && MusicPlaylistJSON.parse(wrapped).entries.count == 1)
        #expect(MusicPlaylistJSON.parse(Data("not json".utf8)).entries.isEmpty && MusicPlaylistJSON.parse(Data()).entries.isEmpty)
    }

    @Test func theFormatIsRecognisedFromNameAndContent() {
        #expect(MusicPlaylistFileFormat.detect(fileName: "a.json", text: "") == .json)
        #expect(MusicPlaylistFileFormat.detect(fileName: "noext", text: "  [ {\"title\":\"x\"} ]") == .json)
        #expect(MusicPlaylistFileFormat.detect(fileName: "a.m3u", text: "#EXTM3U") == .m3u)
        #expect(MusicPlaylistFileFormat.detect(fileName: "a.m3u8", text: "#EXTM3U") == .m3u8)
        #expect(MusicPlaylistFileFormat.detect(fileName: "list.txt", text: "#EXTM3U") == .m3u8)
    }
}

@Suite("Reading a file into songs") struct PlaylistImportTests {
    @Test func aResultIsAcceptedOnlyWhenItReallyIsThatSong() {
        let e = MusicPlaylistFileEntry(title: "Naatu Naatu", artists: ["Rahul Sipligunj"], durationSeconds: 208)
        let right = PT.song(1, "Naatu Naatu", artist: "Rahul Sipligunj", ms: 207_000)
        let wrongArtist = PT.song(2, "Naatu Naatu", artist: "Someone Else", ms: 207_000)
        let wrongSong = PT.song(3, "Chikiri", artist: "Rahul Sipligunj")
        let tooLong = PT.song(4, "Naatu Naatu", artist: "Rahul Sipligunj", ms: 400_000)
        #expect(MusicPlaylistImporter.best(e, in: [wrongSong, wrongArtist, right])?.id == "t1")
        #expect(MusicPlaylistImporter.best(e, in: [wrongSong, wrongArtist]) == nil)
        #expect(MusicPlaylistImporter.best(e, in: [tooLong]) == nil)
        // No artist in the file: the title alone can be enough.
        #expect(MusicPlaylistImporter.best(MusicPlaylistFileEntry(title: "Naatu Naatu"), in: [right]) != nil)
    }

    @Test func resolvingKeepsFileOrderUsesKnownSongsAndReportsWhatWasNotFound() async {
        let entries = [MusicPlaylistFileEntry(title: "One", artists: ["Ada"]),
                       MusicPlaylistFileEntry(title: "Known", known: PT.song(9, "Known")),
                       MusicPlaylistFileEntry(title: "Nothing here", artists: ["Nobody"]),
                       MusicPlaylistFileEntry(title: "Four", artists: ["Ada"])]
        let r = await MusicPlaylistImporter.resolve(entries, search: { q in
            if q.contains("One") { return [PT.song(1, "One", artist: "Ada")] }
            if q.contains("Four") { return [PT.song(4, "Four", artist: "Ada")] }
            return []
        })
        #expect(r.found.map(\.title) == ["One", "Known", "Four"] && r.missing.map(\.title) == ["Nothing here"])
        let none = await MusicPlaylistImporter.resolve([], search: { _ in [] })
        #expect(none.found.isEmpty && none.missing.isEmpty)
    }
}

@Suite("Smart playlist rules") struct SmartRuleTests {
    private func pool() -> [MusicTrack] {
        [PT.song(1, "తెలుగు పాట", artist: "గాయకుడు", ms: 240_000, album: "A", released: "2026-03-01"),
         PT.song(2, "Hindi Song", artist: "Arijit", ms: 300_000, album: "B", released: "2019"),
         PT.song(3, "Night Drive", artist: "Ada", ms: 180_000, album: "C", released: "2026"),
         PT.song(4, "Night Moves", artist: "Bo", ms: 200_000)]
    }
    private func signals() -> MusicSmartSignals {
        var s = MusicSmartSignals(now: PT.now)
        s.plays = ["p:t1": 5, "p:t2": 1, "p:t3": 0]
        s.lastPlayed = ["p:t1": PT.now.addingTimeInterval(-2 * 86_400), "p:t2": PT.now.addingTimeInterval(-200 * 86_400)]
        s.likedOrder = ["p:t3": 0, "p:t4": 1]
        s.liked = ["p:t3", "p:t4"]
        return s
    }
    private func rule(_ f: MusicSmartField, _ o: MusicSmartOperator, _ v: String = "") -> MusicSmartCondition { MusicSmartCondition(field: f, op: o, value: v) }
    private func run(_ rules: [MusicSmartCondition], match: MusicSmartMatch = .all, sort: MusicSmartSort = .title, limit: Int = 100) -> [String] {
        MusicSmartEvaluator.tracks(for: MusicSmartPlaylist(name: "S", match: match, conditions: rules, sort: sort, limit: limit), in: pool(), signals: signals()).map(\.id)
    }

    @Test func textRulesContainNotContainAndEqual() {
        #expect(run([rule(.title, .contains, "night")]) == ["t3", "t4"].sorted { $0 < $1 } || Set(run([rule(.title, .contains, "night")])) == ["t3", "t4"])
        #expect(Set(run([rule(.title, .notContains, "night")])) == ["t1", "t2"])
        #expect(run([rule(.artist, .equals, "ada")]) == ["t3"])
        #expect(run([rule(.album, .contains, "b")]) == ["t2"])
    }

    @Test func numberRulesUsePlaysDatesLengthAndYear() {
        #expect(run([rule(.plays, .atLeast, "3")]) == ["t1"])
        #expect(Set(run([rule(.plays, .equals, "0")])) == ["t3", "t4"])
        #expect(run([rule(.lastPlayedDays, .atMost, "7")]) == ["t1"])
        #expect(Set(run([rule(.minutes, .atLeast, "4")])) == ["t1", "t2"])
        #expect(Set(run([rule(.year, .atLeast, "2025")])) == ["t1", "t3"])
    }

    @Test func likedAndLanguageRules() {
        #expect(Set(run([rule(.liked, .isTrue)])) == ["t3", "t4"])
        #expect(Set(run([rule(.liked, .isFalse)])) == ["t1", "t2"])
        #expect(run([rule(.language, .contains, "telugu")]) == ["t1"])
    }

    @Test func allAndAnyCombineRules() {
        #expect(run([rule(.liked, .isTrue), rule(.title, .contains, "drive")]) == ["t3"])
        #expect(Set(run([rule(.liked, .isTrue), rule(.title, .contains, "drive")], match: .any)) == ["t3", "t4"])
    }

    @Test func incompleteRulesAreLeftOutAndAnEmptyListMatchesNothing() {
        #expect(run([]).isEmpty)
        #expect(run([rule(.title, .contains, "  ")]).isEmpty)
        #expect(run([rule(.plays, .atLeast, "many")]).isEmpty)
        // An incomplete rule beside a good one does not change the good one.
        #expect(run([rule(.liked, .isTrue), rule(.title, .contains, "")]).count == 2)
    }

    @Test func sortLimitAndRandomBehave() {
        #expect(run([rule(.liked, .isFalse)], sort: .mostPlayed) == ["t1", "t2"])
        #expect(run([rule(.liked, .isFalse)], sort: .leastPlayed) == ["t2", "t1"])
        #expect(Array(run([rule(.minutes, .atLeast, "1")], sort: .recentlyAdded).prefix(2)) == ["t3", "t4"])
        #expect(run([rule(.minutes, .atLeast, "1")], limit: 2).count == 2)
        let list = MusicSmartPlaylist(name: "R", conditions: [rule(.minutes, .atLeast, "1")], sort: .random, limit: 0)
        let a = MusicSmartEvaluator.tracks(for: list, in: pool(), signals: signals(), seed: 1).map(\.id)
        let b = MusicSmartEvaluator.tracks(for: list, in: pool(), signals: signals(), seed: 1).map(\.id)
        #expect(a == b && a.count == 4)
        let many = (0..<60).map { PT.song($0, "T\($0)") }
        let x = MusicSmartEvaluator.tracks(for: list, in: many, signals: MusicSmartSignals(now: PT.now), seed: 1).map(\.id)
        let y = MusicSmartEvaluator.tracks(for: list, in: many, signals: MusicSmartSignals(now: PT.now), seed: 2).map(\.id)
        #expect(x != y)
    }

    @Test func aSongsListedTwiceAppearsOnce() {
        let t = PT.song(1, "Dup")
        let list = MusicSmartPlaylist(name: "D", conditions: [rule(.title, .contains, "dup")])
        #expect(MusicSmartEvaluator.tracks(for: list, in: [t, t], signals: MusicSmartSignals(now: PT.now)).count == 1)
    }

    @Test func rulesSurviveSavingAndAnOldOrOddFileStillLoads() throws {
        let list = MusicSmartPlaylist(name: "Keep", match: .any, conditions: [rule(.plays, .atLeast, "3")], sort: .mostPlayed, limit: 25)
        let back = try JSONDecoder().decode(MusicSmartPlaylist.self, from: JSONEncoder().encode(list))
        #expect(back == list)
        let odd = try JSONDecoder().decode(MusicSmartPlaylist.self, from: Data(#"{"name":"Old","sort":"nonsense","limit":-5}"#.utf8))
        #expect(odd.name == "Old" && odd.sort == .recentlyAdded && odd.limit == 0 && odd.match == .all && odd.conditions.isEmpty)
    }

    @Test func aSummarySentenceNamesTheRules() {
        let list = MusicSmartPlaylist(name: "S", conditions: [rule(.language, .contains, "Telugu"), rule(.plays, .atLeast, "3"), rule(.liked, .isTrue), rule(.title, .contains, "")])
        let s = MusicSmartEvaluator.summary(list)
        #expect(s.contains("Telugu") && s.contains("3") && !s.hasSuffix("·"))
    }

    @MainActor @Test func theBookSavesEditsDuplicatesAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = MusicSmartRuleBook(directory: dir, debounce: .milliseconds(1))
        let list = MusicSmartPlaylist(name: "  Loved   songs ", conditions: [rule(.liked, .isTrue)])
        book.save(list)
        #expect(book.lists.first?.name == "Loved songs")
        var edited = list; edited.name = "Loved"
        book.save(edited)
        #expect(book.lists.count == 1 && book.lists[0].name == "Loved")
        book.duplicate(list.id)
        #expect(book.lists.count == 2 && book.lists[1].id != list.id && book.lists[1].conditions[0].id != list.conditions[0].id)
        book.flush()
        let again = MusicSmartRuleBook(directory: dir, debounce: .milliseconds(1))
        #expect(again.lists.count == 2)
        again.delete(list.id)
        #expect(again.lists.count == 1)
    }
}

@Suite("Playlist statistics") struct PlaylistStatsTests {
    @Test func sizeLengthArtistsAndListeningAreCounted() {
        let list = [PT.song(1, "A", artist: "Ada", ms: 180_000, album: "X"), PT.song(2, "B", artist: "Ada", ms: 240_000, album: "X"), PT.song(3, "C", artist: "Bo", ms: 60_000, album: "Y"), PT.song(4, "D", artist: "Cy", ms: 0)]
        let history = [PlayRecord(track: list[0], at: PT.now.addingTimeInterval(-5 * 86_400), playedMs: 100),
                       PlayRecord(track: list[0], at: PT.now.addingTimeInterval(-1 * 86_400), playedMs: 100),
                       PlayRecord(track: list[2], at: PT.now.addingTimeInterval(-9 * 86_400), playedMs: 100),
                       PlayRecord(track: PT.song(99, "Elsewhere"), at: PT.now, playedMs: 100)]
        let s = MusicPlaylistListening.summary(tracks: list, history: history)
        #expect(s.songs == 4 && s.totalSeconds == 480 && s.artists == 3 && s.albums == 2)
        #expect(s.plays == 3 && s.songsPlayed == 2 && s.neverPlayed == 2)
        #expect(s.lastPlayed == PT.now.addingTimeInterval(-1 * 86_400))
        #expect(s.topArtists.first?.name == "Ada" && s.topArtists.first?.songs == 2)
        #expect(s.longestSeconds == 240 && s.shortestSeconds == 60 && s.repeats == 0)
    }

    @Test func anEmptyPlaylistIsAllZeros() {
        let s = MusicPlaylistListening.summary(tracks: [], history: [])
        #expect(s == MusicPlaylistListening.Summary() && s.lastPlayed == nil)
    }

    @Test func repeatsAreCounted() {
        #expect(MusicPlaylistListening.summary(tracks: [PT.song(1, "Same"), PT.song(2, "Same", provider: "q")], history: []).repeats == 1)
    }

    @Test func lengthReadsInPlainUnits() {
        #expect(MusicPlaylistListening.lengthWords(seconds: 0) == "")
        #expect(MusicPlaylistListening.lengthWords(seconds: 45) == "45 s")
        #expect(MusicPlaylistListening.lengthWords(seconds: 200) == "3 min 20 s")
        #expect(MusicPlaylistListening.lengthWords(seconds: 47 * 60) == "47 min")
        #expect(MusicPlaylistListening.lengthWords(seconds: 7_500) == "2 h 5 min")
        #expect(MusicPlaylistListening.lengthWords(seconds: 7_200) == "2 h")
    }
}
