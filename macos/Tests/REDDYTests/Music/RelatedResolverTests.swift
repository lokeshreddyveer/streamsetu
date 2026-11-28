import Testing
import Foundation
@testable import REDDY

// The Related tab's resolution: the song's own source first, then names searched on the other sources with a strict spelling match, a never-empty
// song list, a per-song memory cache, and the gates (lock, catalogue switch, blacklist, catalogue-only sources).

private final class RelatedTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

private struct FakeMeta: MusicMetadataProvider {
    var info: MusicProviderInfo
    var capabilities: MusicCapabilities = [.search, .browse, .tracks, .albums, .artists]
    /// Artist search answers by exact query; `anyArtistHits` answers every other query.
    var artistHitsByQuery: [String: [MusicArtist]] = [:]
    var anyArtistHits: [MusicArtist] = []
    var albumHits: [MusicAlbum] = []
    var songHits: [MusicTrack] = []
    var albumTracksByID: [String: [MusicTrack]] = [:]
    var artistByID: [String: MusicArtist] = [:]
    var overviewByID: [String: MusicArtistOverview] = [:]
    var recs: [MusicTrack]?
    /// Seconds an artist search with this query takes.
    var delays: [String: Double] = [:]
    var tally = RelatedTally()

    init(id: String, name: String? = nil) { info = MusicProviderInfo(id: id, name: name ?? id, summary: "") }

    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        tally.hit(id + ".searchArtists")
        if let d = delays[query] { try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
        return MusicPage(items: artistHitsByQuery[query] ?? anyArtistHits)
    }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { tally.hit(id + ".searchAlbums"); return MusicPage(items: albumHits) }
    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { tally.hit(id + ".searchTracks"); return MusicPage(items: songHits) }
    func artist(id: String) async throws -> MusicArtist { tally.hit(self.id + ".artist"); guard let a = artistByID[id] else { throw MusicError.unsupported("artist") }; return a }
    func artistOverview(id: String) async throws -> MusicArtistOverview {
        tally.hit(self.id + ".overview")
        guard let o = overviewByID[id] else { throw MusicError.unsupported("overview") }
        return o
    }
    func album(id: String) async throws -> MusicAlbum {
        guard let a = albumHits.first(where: { $0.id == id }) else { throw MusicError.unsupported("album") }
        return a
    }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        tally.hit(self.id + ".albumTracks")
        guard let l = albumTracksByID[id] else { throw MusicError.unsupported("album tracks") }
        return MusicPage(items: l)
    }
    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] {
        tally.hit(id + ".recommendations")
        guard let recs else { throw MusicError.unsupported("recommendations") }
        return recs
    }
}

private func artistRef(_ name: String, id: String = "") -> MusicArtistRef { MusicArtistRef(id: id, name: name) }
private func song(_ id: String, _ title: String, by artists: [MusicArtistRef], provider: String = "audius", album: MusicAlbumRef? = nil) -> MusicTrack {
    MusicTrack(id: id, providerID: provider, title: title, durationMs: 200_000, artists: artists, album: album)
}
private func person(_ id: String, _ name: String, provider: String = "main", followers: Int? = nil) -> MusicArtist {
    MusicArtist(id: id, providerID: provider, name: name, followers: followers)
}
private func record(_ id: String, _ title: String, by artist: String = "", provider: String = "main") -> MusicAlbum {
    MusicAlbum(id: id, providerID: provider, title: title, artists: artist.isEmpty ? [] : [MusicArtistRef(id: "", name: artist)])
}

private func environment(_ providers: [FakeMeta], active: String? = nil, gated: Bool = false, catalogue: Bool = true, canon: MusicRelatedCanon? = nil,
                         blockedTracks: Set<String> = [], blockedArtists: Set<String> = [], catalogueOnly: Set<String> = [],
                         twins: @escaping @Sendable ([MusicTrack]) async -> [MusicTrack] = { $0 }) -> MusicRelatedResolver.Environment {
    var e = MusicRelatedResolver.Environment()
    e.deadline = 3
    e.isGated = { gated }
    e.catalogueEnabled = { catalogue }
    e.provider = { id in providers.first { $0.id == id }.map { $0 as any MusicMetadataProvider } }
    e.searchSources = {
        let all = providers.filter { !catalogueOnly.contains($0.id) }
        return all.filter { $0.id == active } + all.filter { $0.id != active }
    }
    e.isCatalogueOnly = { catalogueOnly.contains($0) }
    e.playableTwins = twins
    e.canonical = { _ in canon }
    e.isBlocked = { blockedTracks.contains($0.uid) }
    e.isArtistBlocked = { blockedArtists.contains($0.name) }
    return e
}

// MARK: matching

struct RelatedMatchTests {
    @Test(arguments: ["Sid Sri Ram", "Sid Sree Ram", "sid sriram", "Sid Sriram"])
    func spellingVariantsOfOnePerson(_ other: String) {
        #expect(MusicRelatedMatch.nameScore("Sid Sriram", other) >= MusicRelatedMatch.accept)
    }

    @Test func initialsInEitherPlace() {
        #expect(MusicRelatedMatch.nameScore("Thaman S", "S. Thaman") >= MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("S Thaman", "Thaman S") >= MusicRelatedMatch.accept)
    }

    @Test func otherPeopleStayApart() {
        #expect(MusicRelatedMatch.nameScore("Sid Sriram", "Sriram") < MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("Sid Sriram", "Sriram Parthasarathy") < MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("Sid Sriram", "Sid Sriram Fan Club") < MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("Anirudh Ravichander", "Anirudh") < MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("Thaman S", "Thaman") < MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.nameScore("", "Sid Sriram") == 0)
    }

    @Test func titlesIgnoreBracketsAndFilmNotes() {
        #expect(MusicRelatedMatch.titleScore("Srivalli (From \"Pushpa\")", "Srivalli") >= MusicRelatedMatch.accept)
        #expect(MusicRelatedMatch.titleScore("Srivalli", "Saami Saami") < MusicRelatedMatch.accept)
    }

    @Test func albumListWindowKeepsThePlayingRowInView() {
        #expect(MusicRelatedMatch.window(count: 8, playing: 7, limit: 10) == 0..<8)
        #expect(MusicRelatedMatch.window(count: 30, playing: 2, limit: 10) == 0..<10)
        let w = MusicRelatedMatch.window(count: 30, playing: 22, limit: 10)
        #expect(w.contains(22) && w.count == 10 && w.upperBound <= 30)
        #expect(MusicRelatedMatch.window(count: 30, playing: nil, limit: 10) == 0..<10)
    }

    @Test func songListNeverEmptyWhileAnythingExists() {
        let playing = song("p", "Srivalli", by: [artistRef("Sid Sriram")])
        let t1 = song("1", "Saami Saami", by: [artistRef("Sid Sriram")], provider: "main")
        let t2 = song("2", "Oo Antava", by: [artistRef("Indravathi Chauhan")], provider: "main")
        let t3 = song("3", "Eyy Bidda", by: [artistRef("Mika Singh")], provider: "main")
        // Nothing suggested: the artist's top songs come first, then the album's, once each, never the playing song.
        let out = MusicRelatedMatch.songs(suggested: [], topSongs: [t1, t2, playing], albumTracks: [t2, t3, playing], playing: playing)
        #expect(out.map(\.id) == ["1", "2", "3"])
        // Enough suggestions: no fallback is added.
        let words = ["Kohinoor", "Lahari", "Meghalu", "Nijam", "Oohalu", "Prema", "Rangula", "Swapna", "Tarang"]
        let many = words.enumerated().map { song("s\($0.offset)", $0.element, by: [artistRef($0.element + " Singer")], provider: "main") }
        let full = MusicRelatedMatch.songs(suggested: many, topSongs: [t1], albumTracks: [t2], playing: playing)
        #expect(full.count == 9 && !full.contains { $0.id == "1" })
        // Blocked songs are left out of every part.
        let none = MusicRelatedMatch.songs(suggested: [], topSongs: [t1], albumTracks: [t2], playing: playing, isBlocked: { _ in true })
        #expect(none.isEmpty)
    }
}

// MARK: artists

struct RelatedArtistResolutionTests {
    @Test func ownSourceWinsWhenItNamesTheArtistById() async {
        var yt = FakeMeta(id: "yt")
        yt.artistByID["UC1"] = person("UC1", "Sid Sriram", provider: "yt", followers: 1_200_000)
        let main = FakeMeta(id: "main")
        let r = MusicRelatedResolver(environment: environment([yt, main], active: "main"))
        let t = song("v1", "Srivalli", by: [artistRef("Sid Sriram", id: "UC1")], provider: "yt")
        let list = await r.artists(for: t)
        #expect(list.count == 1 && list[0].origin == .ownSource && list[0].artist?.providerID == "yt")
        #expect(main.tally.count("main.searchArtists") == 0)
    }

    @Test(arguments: ["Sid Sri Ram", "Sid Sree Ram", "Sid Sriram"])
    func nameResolutionAcceptsSpellingVariants(_ spelling: String) async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("x", "Sriram Parthasarathy"), person("a1", spelling)]
        let r = MusicRelatedResolver(environment: environment([main], active: "main"))
        // Audius gives a bare name and no artist page of its own.
        let t = song("a", "Mass Raja", by: [artistRef("Sid Sriram")], provider: "audius")
        let list = await r.artists(for: t)
        #expect(list.first?.origin == .byName)
        #expect(list.first?.artist?.id == "a1")
    }

    @Test func thamanInitialsResolve() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("t1", "S. Thaman")]
        let r = MusicRelatedResolver(environment: environment([main]))
        let list = await r.artists(for: song("a", "Title", by: [artistRef("Thaman S")]))
        #expect(list.first?.artist?.id == "t1")
    }

    @Test func wrongPersonIsRejectedAndTheCreditStays() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("w1", "Sriram Parthasarathy"), person("w2", "Sid Sriram Fan Club")]
        let r = MusicRelatedResolver(environment: environment([main]))
        let list = await r.artists(for: song("a", "Title", by: [artistRef("Sid Sriram")]))
        #expect(list.count == 1 && list[0].origin == .unresolved && list[0].artist == nil && list[0].credited.name == "Sid Sriram")
    }

    @Test func noProviderNameIsKeptForAnArtistThatSeveralSourcesAnswered() async {
        var a = FakeMeta(id: "main", name: "Main")
        a.anyArtistHits = [person("a1", "Sid Sriram", provider: "main")]
        var b = FakeMeta(id: "other", name: "Other")
        b.anyArtistHits = [person("b1", "Sid Sri Ram", provider: "other")]
        let both = MusicRelatedResolver(environment: environment([a, b], active: "main"))
        let two = await both.artists(for: song("a", "T", by: [artistRef("Sid Sriram")]))
        #expect(two.first?.artist?.providerID == "main")
        let alone = MusicRelatedResolver(environment: environment([a], active: "main"))
        let one = await alone.artists(for: song("a", "T", by: [artistRef("Sid Sriram")]))
        #expect(one.first?.artist?.providerID == "main")
    }

    @Test func catalogueSpellingIsAskedWithOnlyWhenTheSwitchIsOn() async {
        var main = FakeMeta(id: "main")
        main.artistHitsByQuery["Sid Sriram"] = [person("a1", "Sid Sriram")]
        let canon = MusicRelatedCanon(title: "Srivalli", artists: ["Sid Sriram"], film: nil, album: nil)
        let t = song("a", "Srivalli", by: [artistRef("Sid Sree Ram")])
        let on = await MusicRelatedResolver(environment: environment([main], canon: canon)).artists(for: t)
        #expect(on.first?.artist?.id == "a1")
        // With the switch off the first spelling is the only one asked, and it finds nothing.
        var strict = FakeMeta(id: "main")
        strict.artistHitsByQuery["Sid Sriram"] = [person("a1", "Sid Sriram")]
        let off = await MusicRelatedResolver(environment: environment([strict], catalogue: false, canon: canon)).artists(for: t)
        #expect(off.first?.origin == .unresolved)
    }

    @Test func blockedArtistsAndLabelChannelsAreLeftOut() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("a1", "Sid Sriram")]
        let r = MusicRelatedResolver(environment: environment([main], blockedArtists: ["Sid Sriram"]))
        let list = await r.artists(for: song("a", "T", by: [artistRef("Sid Sriram"), artistRef("Aditya Music")]))
        #expect(list.isEmpty)
    }

    @Test func memoryCachePerSong() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("a1", "Sid Sriram")]
        let r = MusicRelatedResolver(environment: environment([main]))
        let t = song("a", "T", by: [artistRef("Sid Sriram")])
        _ = await r.artists(for: t)
        _ = await r.artists(for: t)
        #expect(main.tally.count("main.searchArtists") == 1)
        _ = await r.artists(for: song("b", "Other", by: [artistRef("Sid Sriram")]))
        #expect(main.tally.count("main.searchArtists") == 2)
    }

    @Test func lockedMeansNoQuestionsAsked() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("a1", "Sid Sriram")]
        let r = MusicRelatedResolver(environment: environment([main], gated: true))
        let t = song("a", "T", by: [artistRef("Sid Sriram")], album: MusicAlbumRef(id: "", title: "Album"))
        #expect(await r.artists(for: t).isEmpty)
        #expect(await r.album(for: t) == nil)
        #expect(await r.suggestions(for: t).isEmpty)
        #expect(main.tally.total == 0)
    }
}

// MARK: albums

struct RelatedAlbumResolutionTests {
    @Test func ownSourceAlbumWithItsSongs() async {
        var yt = FakeMeta(id: "yt")
        let list = [song("1", "Srivalli", by: [artistRef("Sid Sriram")], provider: "yt"), song("2", "Saami Saami", by: [artistRef("Mounika Yadav")], provider: "yt")]
        yt.albumHits = [record("MPRE1", "Pushpa", provider: "yt")]
        yt.albumTracksByID["MPRE1"] = list
        let r = MusicRelatedResolver(environment: environment([yt]))
        let t = song("1", "Srivalli", by: [artistRef("Sid Sriram")], provider: "yt", album: MusicAlbumRef(id: "MPRE1", title: "Pushpa"))
        let a = await r.album(for: t)
        #expect(a?.origin == .ownSource && a?.tracks.count == 2 && a?.album?.id == "MPRE1")
    }

    @Test func albumByFilmTitleWhenTheSongListsIt() async {
        var main = FakeMeta(id: "main")
        main.albumHits = [record("wrong", "Pushpa", by: "Someone Else"), record("al1", "Pushpa", by: "Devi Sri Prasad")]
        main.albumTracksByID["wrong"] = [song("9", "Another Song", by: [artistRef("X")], provider: "main")]
        main.albumTracksByID["al1"] = [song("1", "Srivalli", by: [artistRef("Sid Sriram")], provider: "main"), song("2", "Oo Antava", by: [artistRef("Indravathi")], provider: "main")]
        let r = MusicRelatedResolver(environment: environment([main]))
        // The song has no album of its own; the catalogue says it is from the film.
        let canon = MusicRelatedCanon(title: "Srivalli", artists: ["Sid Sriram"], film: "Pushpa", album: nil)
        let t = song("a", "Srivalli", by: [artistRef("Sid Sriram")])
        let a = await MusicRelatedResolver(environment: environment([main], canon: canon)).album(for: t)
        #expect(a?.origin == .byName && a?.album?.id == "al1" && a?.tracks.count == 2)
        // Without the catalogue and without an album name nothing is guessed.
        let none = await r.album(for: song("b", "Srivalli", by: [artistRef("Sid Sriram")]))
        #expect(none == nil)
    }

    @Test func aNamedAlbumThatDoesNotListTheSongIsNotTaken() async {
        var main = FakeMeta(id: "main")
        main.albumHits = [record("al9", "Greatest Hits", by: "Sid Sriram")]
        main.albumTracksByID["al9"] = [song("5", "Different Song", by: [artistRef("Sid Sriram")], provider: "main")]
        let r = MusicRelatedResolver(environment: environment([main]))
        let t = song("a", "Srivalli", by: [artistRef("Sid Sriram")], album: MusicAlbumRef(id: "", title: "Greatest Hits"))
        let a = await r.album(for: t)
        // What the song says about itself is all that shows: a title, no page, no list.
        #expect(a?.origin == .unresolved && a?.album == nil && a?.tracks.isEmpty == true && a?.knownTitle == "Greatest Hits")
    }

    @Test func albumFoundThroughTheSameSongOnAnotherSource() async {
        var main = FakeMeta(id: "main")
        let hit = song("m1", "Mass Raja", by: [artistRef("Thaman S", id: "ar7")], provider: "main", album: MusicAlbumRef(id: "alM", title: "Mass Raja"))
        main.songHits = [hit]
        main.albumHits = [record("alM", "Mass Raja", provider: "main")]
        main.albumTracksByID["alM"] = [hit]
        let r = MusicRelatedResolver(environment: environment([main]))
        let a = await r.album(for: song("a", "Mass Raja", by: [artistRef("S. Thaman")]))
        #expect(a?.album?.id == "alM" && a?.tracks.count == 1)
    }
}

// MARK: songs, more from the artist, the model

struct RelatedSongsAndModelTests {
    @Test func suggestionsDropTheSongBlockedAndCatalogueOnlyRows() async {
        var yt = FakeMeta(id: "yt")
        let playing = song("1", "Srivalli", by: [artistRef("Sid Sriram")], provider: "yt")
        yt.recs = [playing, song("2", "Ok", by: [artistRef("A")], provider: "yt"), song("3", "Blocked", by: [artistRef("B")], provider: "yt")]
        let r = MusicRelatedResolver(environment: environment([yt], blockedTracks: ["yt:3"]))
        #expect(await r.suggestions(for: playing).map(\.id) == ["2"])
    }

    @Test func catalogueOnlySongsAppearOnlyAsPlayableTwins() async {
        var jio = FakeMeta(id: "jio")
        jio.capabilities = [.search, .tracks, .catalogue]
        let row = song("c1", "Catalogue Row", by: [artistRef("A")], provider: "jio")
        jio.recs = [row]
        let twin = song("yt9", "Catalogue Row", by: [artistRef("A")], provider: "yt")
        let playing = song("1", "Playing", by: [artistRef("A")], provider: "jio")
        let withTwin = MusicRelatedResolver(environment: environment([jio], catalogueOnly: ["jio"], twins: { _ in [twin] }))
        #expect(await withTwin.suggestions(for: playing).map(\.uid) == ["yt:yt9"])
        let without = MusicRelatedResolver(environment: environment([jio], catalogueOnly: ["jio"], twins: { _ in [] }))
        #expect(await without.suggestions(for: playing).isEmpty)
    }

    @Test func moreFromTheArtistIsTrimmedAndDeduped() async {
        var main = FakeMeta(id: "main")
        let a = person("a1", "Sid Sriram")
        let titles = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"]
        let albums = titles.enumerated().map { record("al\($0.offset)", $0.element) } + [record("dup", "Bravo")]
        let names = ["Armaan Malik", "Anirudh Ravichander", "Shreya Ghoshal", "Karthik Raja", "Haricharan Seshadri", "Chinmayi Sripada",
                     "Ranjith Govind", "Mohana Bhogaraju", "Sunitha Sarathy", "Hemachandra Vedala", "Geetha Madhuri", "Rahul Sipligunj"]
        let related = [person("a1", "Sid Sriram")] + names.enumerated().map { person("r\($0.offset)", $0.element) } + [person("v", "Sid Sri Ram")]
        main.overviewByID["a1"] = MusicArtistOverview(artist: a, topTracks: [], albums: albums, related: related)
        let r = MusicRelatedResolver(environment: environment([main]))
        let more = await r.more(for: a)
        #expect(more?.albums.count == MusicRelatedResolver.albumCount)
        #expect(more?.similar.count == MusicRelatedResolver.similarCount)
        #expect(more?.similar.contains { $0.name.hasPrefix("Sid") } == false)
        _ = await r.more(for: a)
        #expect(main.tally.count("main.overview") == 1)
    }

    @MainActor @Test func modelFillsEachSectionAndFallsBackToArtistAndAlbumSongs() async {
        var main = FakeMeta(id: "main")
        let sid = person("a1", "Sid Sriram")
        let top = [song("t1", "Saami Saami", by: [artistRef("Sid Sriram")], provider: "main"), song("t2", "Inkem Inkem", by: [artistRef("Sid Sriram")], provider: "main")]
        main.anyArtistHits = [sid]
        main.overviewByID["a1"] = MusicArtistOverview(artist: sid, topTracks: top, albums: [record("al1", "Pushpa")], related: [person("r1", "Armaan Malik")])
        main.albumHits = [record("al1", "Pushpa")]
        main.albumTracksByID["al1"] = [song("t3", "Eyy Bidda", by: [artistRef("Mika")], provider: "main"), top[0],
                                       song("t4", "Srivalli", by: [artistRef("Sid Sriram")], provider: "main")]
        let model = MusicRelatedModel(resolver: MusicRelatedResolver(environment: environment([main], active: "main")))
        let t = song("a", "Srivalli", by: [artistRef("Sid Sriram")], album: MusicAlbumRef(id: "", title: "Pushpa"))
        await model.load(t)
        #expect(model.artists.value?.first?.artist?.id == "a1")
        #expect(model.album.value?.album?.id == "al1")
        #expect(model.topSongs.value?.map(\.id) == ["t1", "t2"])
        #expect(model.albums.value == nil, "the artist's only album is the one playing: it has its own card above, so the shelf is hidden")
        #expect(model.similar.value?.map(\.id) == ["r1"])
        // The source suggests nothing, so the list is the artist's top songs, then the album's other songs.
        #expect(model.songs.value?.map(\.id) == ["t1", "t2", "t3"])
        #expect(!model.finishedEmpty)
    }

    @MainActor @Test func nothingResolvedShowsOnlyWhatTheSongSaysAndTheNote() async {
        let model = MusicRelatedModel(resolver: MusicRelatedResolver(environment: environment([])))
        await model.load(song("a", "Mass Raja (Telugu)", by: [artistRef("Someone")], album: MusicAlbumRef(id: "", title: "Singles")))
        #expect(model.artists.value?.first?.origin == .unresolved)
        #expect(model.album.value?.knownTitle == "Singles" && model.album.value?.album == nil)
        #expect(model.topSongs == .hidden && model.albums == .hidden && model.similar == .hidden && model.songs == .hidden)
        #expect(model.finishedEmpty)
    }

    @MainActor @Test func lockedModelHidesEverything() async {
        var main = FakeMeta(id: "main")
        main.anyArtistHits = [person("a1", "Sid Sriram")]
        let model = MusicRelatedModel(resolver: MusicRelatedResolver(environment: environment([main], gated: true)))
        await model.load(song("a", "T", by: [artistRef("Sid Sriram")]))
        #expect(model.gated && model.artists == .hidden && model.songs == .hidden && model.finishedEmpty)
        #expect(main.tally.total == 0)
    }

    @MainActor @Test func aSlowAnswerForTheEarlierSongNeverLandsOnTheNextOne() async throws {
        var main = FakeMeta(id: "main")
        main.artistHitsByQuery["Slow Singer"] = [person("s1", "Slow Singer")]
        main.artistHitsByQuery["Fast Singer"] = [person("f1", "Fast Singer")]
        main.delays["Slow Singer"] = 1.0
        let model = MusicRelatedModel(resolver: MusicRelatedResolver(environment: environment([main])))
        let first = Task { await model.load(song("a", "Slow Song", by: [artistRef("Slow Singer")])) }
        try await Task.sleep(nanoseconds: 80_000_000)
        first.cancel()
        await model.load(song("b", "Fast Song", by: [artistRef("Fast Singer")]))
        await first.value
        #expect(model.trackUID == "audius:b")
        #expect(model.artists.value?.map(\.credited.name) == ["Fast Singer"])
        #expect(model.artists.value?.first?.artist?.id == "f1")
    }
}
