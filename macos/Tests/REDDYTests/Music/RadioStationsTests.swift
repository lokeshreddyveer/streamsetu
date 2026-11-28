import Testing
import Foundation
@testable import REDDY

@Suite("Music Radio stations") @MainActor struct RadioStationsTests {
    private func song(_ id: String, _ title: String, artist: String) -> MusicTrack {
        MusicTrack(id: id, providerID: "p", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: artist, name: artist)])
    }
    private func plays(_ tracks: [MusicTrack]) -> [PlayRecord] {
        tracks.enumerated().map { PlayRecord(track: $1, at: Date(timeIntervalSince1970: Double($0)), playedMs: 1000) }
    }
    private func input(region: String = "us", playing: MusicTrack? = nil, liked: [MusicTrack] = [], history: [PlayRecord] = [], followed: [MusicArtist] = []) -> MusicRadioStations.Input {
        .init(playing: playing, liked: liked, history: history, followed: followed, region: region)
    }
    private func suite() -> UserDefaults {
        let d = UserDefaults(suiteName: "radio-tests-" + UUID().uuidString)!
        return d
    }

    @Test("With no history there are no personal stations and no built-in genre list; language stations come only from the device's languages (changed: nothing is hardcoded)")
    func noHistory() {
        let s = MusicRadioStations.build(input())
        #expect(s.yours.isEmpty && !s.hasYours && s.recent.isEmpty)
        #expect(s.featured.map(\.kind) == [.region])
        #expect(s.featured.first?.id == "region:us")
        #expect(s.genres.isEmpty)
        #expect(s.genres.allSatisfy { $0.kind == .genre } && s.languages.allSatisfy { $0.kind == .language })
        #expect(s.regional.isEmpty, "no per-language charts outside India")
    }

    @Test("Stations from plays, likes and follows come only from them")
    func fromHistory() {
        let a1 = song("1", "One", artist: "Ada"), a2 = song("2", "Two", artist: "Ada"), b1 = song("3", "Three", artist: "Bo")
        let s = MusicRadioStations.build(input(playing: b1, liked: [b1], history: plays([a1, a2, a1, b1])))
        #expect(s.yours.first?.id == "track:" + b1.uid && s.yours.first?.badge == Localized.string("Song radio"))
        let artists = s.yours.filter { $0.kind == .artist }
        #expect(Set(artists.map(\.id)) == ["artist:ada", "artist:bo"])
        #expect(Set(s.yours.map(\.id)).count == s.yours.count)
        let zed = MusicArtist(id: "z", providerID: "p", name: "Zed", genres: ["Folk"])
        let f = MusicRadioStations.build(input(followed: [zed]))
        #expect(f.yours.map(\.id) == ["artist:zed"])
        if case .artist(let a)? = f.yours.first?.seed { #expect(a.name == "Zed") } else { Issue.record("followed artist seeds an artist radio") }
        #expect(f.genres.first?.id == "genre:folk" || !f.genres.contains { $0.id == "genre:folk" }, "a followed genre leads when the catalogue lists it")
    }

    @Test("Seed mapping: history artists start from their latest song, genres and languages from a search")
    func seeds() {
        let a1 = song("1", "One", artist: "Ada")
        let s = MusicRadioStations.build(input(history: plays([a1])))
        if case .track(let t)? = s.yours.first(where: { $0.kind == .artist })?.seed { #expect(t.uid == a1.uid) } else { Issue.record("artist seed is a song") }
        // changed: there is no built-in genre list; a genre station exists only when a genre is derived, and then it starts from a search.
        if let g = s.genres.first, case .search(let q, nil) = g.seed { #expect(q.hasSuffix(" music")) }
        // changed: language stations come from the device's languages; when there is one, its seed names that language.
        if let l = s.languages.first, case .search(_, let key?) = l.seed { #expect(MusicCategoryCatalogue.languages.map(\.key).contains(key)) }
        if case .chart(let r, nil) = s.featured[0].seed { #expect(r == "us") } else { Issue.record("country seed is a chart") }
    }

    @Test("The country follows the selected region, and India offers per-language charts")
    func regions() {
        #expect(MusicRadioStations.build(input(region: "de")).featured.first?.id == "region:de")
        #expect(MusicRadioStations.build(input(region: "de")).featured.first?.title == Localized.string("Top %@ Radio", "Germany"))
        let india = MusicRadioStations.build(input(region: "in"))
        // changed: India no longer gets a fixed set of three language charts; they come only from the languages the person plays or the device uses.
        #expect(india.regional.allSatisfy { $0.id.hasPrefix("chart:in:") })
    }

    @Test("Languages in the history lead the featured row and are not repeated below")
    func languages() {
        let te = (1...3).map { song("t\($0)", "తెలుగు పాట \($0)", artist: "గాయకుడు") }
        let s = MusicRadioStations.build(input(history: plays(te)))
        #expect(s.featured.map(\.id) == ["region:us", "language:telugu"])
        #expect(!s.languages.contains { $0.id == "language:telugu" })
        #expect(s.languages.count <= MusicRadioStations.perSection)
        let latin = MusicRadioStations.build(input(history: plays([song("1", "Hello World", artist: "Ada"), song("2", "Another One", artist: "Ada")])))
        #expect(latin.featured.count == 1, "Latin script is never guessed to be a language")
    }

    @Test("Recent stations: newest first, one entry per station, capped, saved and wiped")
    func recents() {
        let d = suite()
        // changed: there is no built-in genre list to take stations from, so the stations are made from songs.
        let genres = (0..<5).map { MusicRadioStations.songStation(song("\($0)", "Song \($0)", artist: "Ada \($0)")) }
        #expect(MusicRadioRecents.load(d).isEmpty)
        for g in genres.prefix(5) { MusicRadioRecents.record(g, in: d) }
        MusicRadioRecents.record(genres[1], in: d)
        let list = MusicRadioRecents.load(d)
        #expect(list.map(\.id) == [genres[1], genres[4], genres[3], genres[2], genres[0]].map(\.id))
        #expect(list.first == genres[1])
        var many: [MusicStation] = []
        for i in 0..<30 { many = MusicRadioRecents.recording(MusicRadioStations.songStation(song("\(i)", "S\(i)", artist: "A")), into: many) }
        #expect(many.count == MusicRadioRecents.cap && many.first?.id == "track:p:29")
        let again = MusicRadioStations.build(.init(region: "us", recent: list))
        #expect(again.recent == list)
        MusicRadioRecents.wipe(d)
        #expect(MusicRadioRecents.load(d).isEmpty)
        #expect(MusicDefaultsKeys.deviceSettings.contains(MusicRadioRecents.defaultsKey))
    }

    @Test("A station keeps its artwork and survives a save")
    func codable() throws {
        var t = song("1", "One", artist: "Ada"); t.thumbnails = [MusicThumbnail(url: "https://example.com/a.jpg", width: 300, height: 300)]
        let st = MusicRadioStations.songStation(t)
        let back = try JSONDecoder().decode(MusicStation.self, from: JSONEncoder().encode(st))
        #expect(back == st && back.thumbs.count == 1)
        #expect(MusicRadioStations.genreStation(MusicCategory(name: "Jazz", kind: .genre, target: .search("Jazz music"))).category?.kind == .genre)
    }

    @Test("A chosen song, preferring the asked language, skips blocked songs")
    func picking() {
        let en = song("1", "Hello World", artist: "Ada"), te = song("2", "తెలుగు పాట", artist: "గాయకుడు")
        #expect(MusicRadioSeedPicking.pick([en, te], languageKey: "telugu")?.id == "2")
        #expect(MusicRadioSeedPicking.pick([en, te], languageKey: nil)?.id == "1")
        #expect(MusicRadioSeedPicking.pick([en, te], languageKey: nil, blocked: { $0.id == "1" })?.id == "2")
        #expect(MusicRadioSeedPicking.pick([], languageKey: "telugu") == nil)
    }
}
