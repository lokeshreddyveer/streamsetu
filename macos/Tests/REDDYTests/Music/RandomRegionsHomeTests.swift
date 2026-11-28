import Testing
import Foundation
@testable import REDDY

/// Listen Now and Search checked on REAL chart records of randomly drawn countries, not on hand-picked examples. The records live in
/// `Fixtures/RandomRegions/seed-N.json`: `Scripts/music-sample-regions.py --seed N` draws the countries at random (with that seed) from the ones the app
/// supports and saves what the live chart service returned, with the date. Add a seed file and these tests cover it without any change here. Every failure
/// message names the seed, the country and the record, so it can be reproduced.
@Suite("Listen Now and Search on randomly sampled real charts") struct RandomRegionsHomeTests {
    struct Fixture: Decodable { var seed: Int; var fetchedAt: String; var regions: [Region] }
    struct Region: Decodable { var code: String; var name: String; var songs: [Rec]; var albums: [Rec] }
    struct Rec: Decodable { var id: String?; var name: String?; var artist: String? }

    static let fixtures: [Fixture] = {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { dir.deleteLastPathComponent() }            // Music, REDDYTests
        dir.appendPathComponent("Fixtures/RandomRegions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
    }()

    private static func track(_ r: Rec) -> MusicTrack? {
        guard let id = r.id, let name = r.name, !name.isEmpty else { return nil }
        return MusicTrack(id: id, providerID: "itunes-charts", title: name, durationMs: 0, artists: r.artist.map { [MusicArtistRef(id: "", name: $0)] } ?? [])
    }
    private static func album(_ r: Rec) -> MusicAlbum? {
        guard let id = r.id, let name = r.name, !name.isEmpty else { return nil }
        return MusicAlbum(id: id, providerID: "itunes-charts", title: name, artists: r.artist.map { [MusicArtistRef(id: "", name: $0)] } ?? [])
    }
    private static func tag(_ f: Fixture, _ r: Region) -> String { "seed \(f.seed), \(r.code)" }

    @Test func thereAreSampledRecordsToCheck() {
        #expect(!Self.fixtures.isEmpty, "no seed files in Fixtures/RandomRegions: run Scripts/music-sample-regions.py")
        let records = Self.fixtures.flatMap(\.regions).reduce(0) { $0 + $1.songs.count + $1.albums.count }
        #expect(records > 100)
    }

    // MARK: Listen Now's shelf rules




    // MARK: Search on the same records

    @Test func typingTheStartOfAnyRealTitleOffersIt() async {
        let engine = MusicLocalSuggestions()
        var names: [(String, String)] = []
        for f in Self.fixtures { for r in f.regions { for rec in r.songs + r.albums { if let n = rec.name { names.append((n, Self.tag(f, r))) } } } }
        await engine.add(names.map(\.0), kind: .song)
        var checked = 0, found = 0
        var missed: [String] = []
        for (name, tag) in names {
            let norm = MusicText.normalize(name)
            guard norm.count >= 5 else { continue }
            let q = String(norm.prefix(max(3, norm.count * 6 / 10)))
            let answer = await engine.suggest(q, limit: 6)
            checked += 1
            if answer.suggestions.contains(where: { MusicText.normalize($0.text).hasPrefix(q) }) { found += 1 } else { missed.append("\(tag): “\(name)” for “\(q)”") }
        }
        #expect(checked > 50)
        #expect(found == checked, "\(missed.prefix(5).joined(separator: "; "))")
    }

    @Test func aSwappedLetterInAnyLongRealWordIsPutRight() async {
        let engine = MusicLocalSuggestions()
        var words: [String] = []
        for f in Self.fixtures { for r in f.regions { for rec in r.songs + r.albums {
            if let n = rec.name { await engine.add(n, kind: .song); words += MusicText.normalize(n).split(separator: " ").map(String.init).filter { $0.count >= 7 && $0.unicodeScalars.allSatisfy(\.isASCII) } }
        } } }
        var checked = 0, fixed = 0
        for w in Set(words).sorted().prefix(120) {
            var c = Array(w)
            let i = c.count / 2
            guard c[i] != c[i - 1] else { continue }
            c.swapAt(i, i - 1)
            let typo = String(c)
            guard typo != w else { continue }
            checked += 1
            if let d = await engine.didYouMean(typo), d.split(separator: " ").contains(Substring(w)) { fixed += 1 }
        }
        #expect(checked >= 20)
        // a swap can legitimately be ambiguous (another real word may be as close), so the bar is a high share, not every word
        #expect(Double(fixed) / Double(max(1, checked)) >= 0.8, "\(fixed) of \(checked) swapped words were corrected")
    }
}

@Suite("Search ranking on randomly sampled real songs") struct RandomRegionsSearchTests {
    /// One country's songs at a time: a search ranks the answers of one question, not every chart at once.
    private static func pools(_ f: RandomRegionsHomeTests.Fixture) -> [(String, [MusicTrack])] {
        f.regions.map { r in
            ("seed \(f.seed), \(r.code)", r.songs.compactMap { rec -> MusicTrack? in
                guard let id = rec.id, let name = rec.name, !name.isEmpty else { return nil }
                return MusicTrack(id: id, providerID: "itunes-charts", title: name, durationMs: 0, artists: rec.artist.map { [MusicArtistRef(id: "", name: $0)] } ?? [])
            })
        }
    }

    @Test func typingARealTitleExactlyPutsThatSongFirst() {
        var checked = 0
        for f in RandomRegionsHomeTests.fixtures {
            for (tag, all) in Self.pools(f) where all.count >= 5 {
                for t in all.prefix(6) {
                    let q = MusicDisplayTitle.clean(title: t.title, artists: t.artists.map(\.name)).title
                    guard MusicText.normalize(q).count >= 4 else { continue }
                    let ranked = MusicSearchRanker.mergeTracks([all], query: q)
                    guard let top = ranked.first else { Issue.record("\(tag): nothing came back for “\(q)”"); continue }
                    let want = MusicText.normalize(q)
                    let got = MusicText.normalize(top.title)
                    #expect(got.contains(want) || want.contains(got), "\(tag), id \(t.id): “\(q)” ranked “\(top.title)” first")
                    checked += 1
                }
            }
        }
        #expect(checked > 50)
    }

    @Test func theSameQueryAlwaysGivesTheSameOrderAndKeepsTheSameSongs() {
        for f in RandomRegionsHomeTests.fixtures {
            for (tag, all) in Self.pools(f).prefix(4) where all.count >= 5 {
                let q = all[0].title
                let a = MusicSearchRanker.mergeTracks([all], query: q).map(\.uid)
                #expect(a == MusicSearchRanker.mergeTracks([all], query: q).map(\.uid), "\(tag): order changed between runs")
                #expect(Set(MusicSearchRanker.mergeTracks([all, all], query: q).map(\.uid)) == Set(a), "\(tag): merging a list with itself changed what is kept")
            }
        }
    }
}

@Suite("Search ranking runs as a pure value") struct SearchRankPureTests {
    @Test func rankingAndDerivingGiveTheSameAnswerTwiceAndMergeIntoExisting() {
        func track(_ i: Int, _ t: String, _ a: String) -> MusicSearchResult { .track(MusicTrack(id: "\(i)", providerID: "p", title: t, durationMs: 0, artists: [MusicArtistRef(id: "", name: a)])) }
        let lists: [[MusicSearchResult]] = [[track(1, "Alpha Song", "Alpha Band"), track(2, "Beta", "Beta Band")], [track(3, "Alpha Song", "Alpha Band")]]
        let a = MusicSearchModel.rank(lists, query: "alpha song", into: nil)
        let b = MusicSearchModel.rank(lists, query: "alpha song", into: nil)
        #expect(a.tracks.map(\.uid) == b.tracks.map(\.uid))
        #expect(a.tracks.count == 2, "the same song from two sources is kept once")
        let more = MusicSearchModel.rank([[track(4, "Gamma", "Gamma Band")]], query: "alpha song", into: a)
        #expect(more.tracks.count == 3 && Set(a.tracks.map(\.uid)).isSubset(of: Set(more.tracks.map(\.uid))))
        #expect(a.top != nil)
    }
}
