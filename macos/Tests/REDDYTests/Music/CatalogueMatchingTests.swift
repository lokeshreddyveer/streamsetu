import Testing
import Foundation
@testable import REDDY

// Fakes -----------------------------------------------------------------------------------------------------------------------------

private final class Calls: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func hit() { l.withLock { n += 1 } }
    var count: Int { l.withLock { n } }
}

private struct FakeAudio: MusicAudioProvider {
    var info: MusicProviderInfo
    var capabilities: MusicCapabilities { [.audio] }
    var calls = Calls()
    var answer: @Sendable (MusicTrack) async throws -> [MusicAudioSource]
    init(id: String = "youtube-music", calls: Calls = Calls(), answer: @escaping @Sendable (MusicTrack) async throws -> [MusicAudioSource]) {
        info = MusicProviderInfo(id: id, name: id, summary: ""); self.answer = answer; self.calls = calls
    }
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] { calls.hit(); return try await answer(track) }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] { [] }
}

private struct FakeCatalogue: MusicMetadataProvider {
    var info = MusicProviderInfo(id: "jiosaavn", name: "JioSaavn", summary: "")
    var capabilities: MusicCapabilities { [.search, .tracks, .catalogue] }
    var hits: [MusicTrack]
    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { MusicPage(items: hits) }
}

private func catalogueTrack(_ title: String, _ artist: String, ms: Int64 = 214_000, album: String? = nil, id: String = "c1", isrc: String? = nil, cover: String? = nil) -> MusicTrack {
    MusicTrack(id: id, providerID: "jiosaavn", title: title, durationMs: ms, artists: [MusicArtistRef(id: artist, name: artist)],
               album: album.map { MusicAlbumRef(id: $0, title: $0, releaseDate: "2021-12-17") },
               thumbnails: cover.map { [MusicThumbnail(url: $0, width: 500, height: 500)] } ?? [], isrc: isrc)
}

private func source(_ id: String, _ title: String, channel: String?, ms: Int64?, album: String? = nil, provider: String = "youtube-music") -> MusicAudioSource {
    MusicAudioSource(id: id, providerID: provider, title: title, artist: channel, album: album, durationMs: ms, externalURL: nil, confidence: 0.8)
}

private func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-\(UUID().uuidString)/store.json") }

private func matcher(_ providers: [FakeAudio], store: MusicCanonicalStore, cat: [FakeCatalogue] = []) -> MusicCatalogMatcher {
    let audio: [any MusicAudioProvider] = providers
    let metas: [any MusicMetadataProvider] = cat
    return MusicCatalogMatcher(store: store, environment: .init(audio: { audio }, catalogue: { metas }))
}

// Transliteration -------------------------------------------------------------------------------------------------------------------

struct TransliterationKeyTests {
    @Test func spellingsMeetInOneKey() {
        #expect(MusicTransliterationKey.sameKey("Dakko Dakko Meka", "Daakko Daakko Meka"))
        #expect(MusicTransliterationKey.sameKey("Zinda", "Jinda"))
        #expect(MusicTransliterationKey.sameKey("Guzarish", "Gujarish"))
        #expect(MusicTransliterationKey.sameKey("Tum Hi Ho", "Tum Hee Ho"))
        #expect(MusicTransliterationKey.sameKey("Kaavaalaa", "Kavala"))
        #expect(MusicTransliterationKey.sameKey("Chaleya", "Chaleyaa"))
    }

    @Test func differentWordsStayApart() {
        #expect(!MusicTransliterationKey.sameKey("Kala", "Gala"))
        #expect(!MusicTransliterationKey.sameKey("Tum Hi Ho", "Tum Se Hi"))
        #expect(MusicTransliterationKey.key("") == "")
    }

    @Test func exactOutranksPhonetic() {
        let exact = MusicTransliterationKey.similarity("Dakko Dakko Meka", "dakko dakko meka")
        let phon = MusicTransliterationKey.similarity("Dakko Dakko Meka", "Daakko Daakko Meka")
        let far = MusicTransliterationKey.similarity("Dakko Dakko Meka", "Bohemian Rhapsody")
        #expect(exact == 1 && phon < exact && phon >= 0.9 && far < 0.5)
    }

    @Test func alternatesAreFewAndDifferent() {
        let a = MusicTransliterationKey.alternates(of: "Dakko Dakko Meka", limit: 2)
        #expect(a.first == "Daakko Daakko Meka" && a.count == 2 && !a.contains("Dakko Dakko Meka"))
        #expect(MusicTransliterationKey.alternates(of: "Zinda", limit: 3).contains("Jinda"))
        #expect(MusicTransliterationKey.alternates(of: "కావాలా").isEmpty)
        #expect(MusicTransliterationKey.alternates(of: "Zinda", limit: 0).isEmpty)
    }

    @Test func nonLatinScriptsFold() {
        #expect(!MusicTransliterationKey.key("కావాలా").isEmpty)
        #expect(!MusicTransliterationKey.key("तुम ही हो").isEmpty)
    }

    @Test func lyricsBuilderUsesTheAlternates() {
        let r = MusicLyricsRequest(videoID: nil, title: "Dakko Dakko Meka song (from pushpa telugu)", artists: "LOOP Studio", album: nil, durationSeconds: 214)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v.contains { $0.kind == .spelling && $0.title == "Daakko Daakko Meka" })
    }
}

// Canonicalisation ------------------------------------------------------------------------------------------------------------------

struct CanonicalisationTests {
    @Test func filmNameAndYearAreKept() {
        let c = MusicCatalogCanon.make(from: catalogueTrack("Daakko Daakko Meka (From \"Pushpa - The Rise\")", "Sivam", album: "Pushpa - The Rise"))
        #expect(c.title == "Daakko Daakko Meka")
        #expect(c.film == "Pushpa - The Rise" && c.year == 2021 && c.versionTags.isEmpty)
    }

    @Test func versionsKeepTheirTagAndOwnKey() {
        let studio = MusicCatalogCanon.make(from: catalogueTrack("Tum Hi Ho", "Arijit Singh"))
        let remix = MusicCatalogCanon.make(from: catalogueTrack("Tum Hi Ho (Remix)", "Arijit Singh"))
        #expect(remix.versionTags == ["remix"] && studio.key != remix.key)
    }

    @Test func spellingVariantsShareAKey() {
        let a = MusicCatalogCanon.make(from: catalogueTrack("Dakko Dakko Meka", "Sivam"))
        let b = MusicCatalogCanon.make(from: catalogueTrack("Daakko Daakko Meka", "Sivam", id: "c2"))
        #expect(a.key == b.key)
    }

    @Test func featuredAndIndicTitlesDoNotBreak() {
        let f = MusicCatalogCanon.make(from: catalogueTrack("Blinding Lights (feat. Rosalia)", "The Weeknd"))
        #expect(f.title == "Blinding Lights")
        let t = MusicCatalogCanon.make(from: catalogueTrack("కావాలా", "శిల్పా రావు"))
        #expect(!t.key.isEmpty && t.title == "కావాలా")
    }

    @Test func isrcIsNormalised() {
        #expect(MusicCatalogCanon.make(from: catalogueTrack("X Song", "Y", isrc: "us-abc-12-34567")).isrc == "USABC1234567")
        #expect(MusicCatalogCanon.make(from: catalogueTrack("X Song", "Y", isrc: "bad")).isrc == nil)
    }
}

// Twin selection --------------------------------------------------------------------------------------------------------------------

struct TwinSelectionTests {
    private var canon: MusicCanonicalTrack { MusicCatalogCanon.make(from: catalogueTrack("Daakko Daakko Meka", "Sivam", ms: 214_000, album: "Pushpa")) }

    @Test func topicRowOutranksUserUpload() {
        let topic = source("a", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 214_500, album: "Pushpa")
        let upload = source("b", "Daakko Daakko Meka Video Song | Pushpa", channel: "Sivam", ms: 214_000)
        let user = source("c", "Daakko Daakko Meka (Lyrical) Sivam", channel: "Random Fan", ms: 214_000)
        let ranked = MusicTwinSelection.rank(canonical: canon, candidates: [user, upload, topic])
        #expect(ranked.first?.source.id == "a")
        let v = MusicTwinSelection.evaluate(canonical: canon, candidate: topic)
        #expect(v.accepted && (v.deltaMs ?? 99) < 1000)
    }

    @Test func versionAndRuntimeVetoes() {
        let live = source("l", "Daakko Daakko Meka (Live)", channel: "Sivam - Topic", ms: 214_000)
        #expect(MusicTwinSelection.evaluate(canonical: canon, candidate: live).reason == "version")
        let long = source("m", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 250_000)
        #expect(MusicTwinSelection.evaluate(canonical: canon, candidate: long).reason == "runtime")
        let other = source("o", "Daakko Daakko Meka", channel: "Somebody Else", ms: 260_000)
        #expect(!MusicTwinSelection.evaluate(canonical: canon, candidate: other).accepted)
    }

    @Test func differentLanguageIsDifferentRecording() {
        let hindi = MusicCatalogCanon.make(from: catalogueTrack("Tum Hi Ho (Hindi)", "Arijit Singh"))
        #expect(hindi.language == "hindi")
        let tamil = source("t", "Tum Hi Ho (Tamil)", channel: "Arijit Singh - Topic", ms: 214_000)
        #expect(MusicTwinSelection.evaluate(canonical: hindi, candidate: tamil).accepted == false)
    }

    @Test func phoneticTitleNeedsArtistAndRuntime() {
        let c = MusicCatalogCanon.make(from: catalogueTrack("Zinda", "Sivam", ms: 200_000))
        let ok = source("a", "Jinda", channel: "Sivam - Topic", ms: 201_000)
        let noArtist = source("b", "Jinda", channel: "Random", ms: 201_000)
        let noRuntime = source("c", "Jinda", channel: "Sivam - Topic", ms: nil)
        let farRuntime = source("d", "Jinda", channel: "Sivam - Topic", ms: 207_000)
        #expect(MusicTwinSelection.evaluate(canonical: c, candidate: ok).accepted)
        #expect(!MusicTwinSelection.evaluate(canonical: c, candidate: noArtist).accepted)
        #expect(!MusicTwinSelection.evaluate(canonical: c, candidate: noRuntime).accepted)
        #expect(!MusicTwinSelection.evaluate(canonical: c, candidate: farRuntime).accepted)
    }

    @Test func unknownRuntimeIsAllowedForExactTitleButScoredLower() {
        let known = MusicTwinSelection.evaluate(canonical: canon, candidate: source("a", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 214_000))
        let unknown = MusicTwinSelection.evaluate(canonical: canon, candidate: source("b", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: nil))
        #expect(known.score > unknown.score)
    }

    @Test func queriesUseCatalogueWords() {
        let q = MusicTwinSelection.queries(for: canon)
        #expect(q.count <= 3 && q.first == "Daakko Daakko Meka Sivam" && q.contains("Daakko Daakko Meka Pushpa"))
        let v = MusicTwinSelection.variants(for: canon)
        #expect(v.count >= 2 && v.count <= 3 && v[0].title == "Daakko Daakko Meka")
    }

    @Test func recreationsAreRefused() {
        let c = MusicCatalogCanon.make(from: catalogueTrack("Kaavaalaa", "Shilpa Rao, Anirudh Ravichander", ms: 190_000, album: "Jailer"))
        let emu = source("e", "Kaavaalaa (From \"Jailer\") (8-Bit Anirudh Ravichander, Shilpa Rao Emulation)", channel: "8-Bit Arcade", ms: 195_000)
        #expect(MusicTwinSelection.evaluate(canonical: c, candidate: emu).accepted == false)
        let tribute = source("t", "Kaavaalaa Piano Version", channel: "Shilpa Rao - Topic", ms: 190_000)
        #expect(MusicTwinSelection.evaluate(canonical: c, candidate: tribute).accepted == false)
        let real = source("r", "Kaavaalaa (From \"Jailer\")", channel: "Shilpa Rao, Anirudh Ravichander", ms: 191_000, album: "Jailer")
        #expect(MusicTwinSelection.evaluate(canonical: c, candidate: real).accepted)
    }

    @Test func artistNamedOnlyInTheTitleIsWeakerThanTheChannel() {
        let byChannel = MusicTwinSelection.evaluate(canonical: canon, candidate: source("a", "Daakko Daakko Meka", channel: "Sivam", ms: 214_000))
        let byTitle = MusicTwinSelection.evaluate(canonical: canon, candidate: source("b", "Sivam - Daakko Daakko Meka", channel: "Random Uploader", ms: 214_000))
        #expect(byChannel.artistSimilarity == 1 && byTitle.artistSimilarity < 1 && byChannel.score > byTitle.score)
    }

    @Test func creditLineIsSplitIntoSingers() {
        let c = MusicCatalogCanon.make(from: catalogueTrack("Kaavaalaa", "Shilpa Rao, Anirudh Ravichander & Arunraja Kamaraj"))
        #expect(c.artists == ["Shilpa Rao", "Anirudh Ravichander", "Arunraja Kamaraj"])
        #expect(MusicTwinSelection.queries(for: c).first == "Kaavaalaa Shilpa Rao")
    }

    @Test func rulesAreData() {
        var strict = MusicTwinRules.standard
        strict.runtimeWindowMs = 1_000
        let c = source("a", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 216_000)
        #expect(MusicTwinSelection.evaluate(canonical: canon, candidate: c).accepted)
        #expect(!MusicTwinSelection.evaluate(canonical: canon, candidate: c, rules: strict).accepted)
    }
}

// Matcher ---------------------------------------------------------------------------------------------------------------------------

struct CatalogMatcherTests {
    @Test func findsAndCachesTheTwin() async {
        let calls = Calls()
        let yt = FakeAudio(calls: calls) { _ in [source("vid1", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 214_200, album: "Pushpa")] }
        let store = MusicCanonicalStore(file: tempFile())
        let m = matcher([yt], store: store)
        let row = catalogueTrack("Daakko Daakko Meka (From \"Pushpa\")", "Sivam", album: "Pushpa", cover: "https://img.example/big.jpg")
        let first = await m.twin(for: row)
        #expect(first?.twins.first?.sourceID == "vid1")
        let used = calls.count
        let second = await m.twin(for: row)
        #expect(second?.twins.first?.sourceID == "vid1" && calls.count == used)
        let shown = MusicCatalogMatcher.playableTrack(from: first!, catalogueRow: row)
        #expect(shown.providerID == "youtube-music" && shown.id == "vid1" && shown.videoID == "vid1" && shown.thumbnails.first?.url == "https://img.example/big.jpg")
    }

    @Test func aPlayableCopyFromAnotherSourceNeverCarriesTheCatalogueRowsAlbumOrArtistIds() async {
        let calls = Calls()
        let yt = FakeAudio(calls: calls) { _ in [source("vid1", "Daakko Daakko Meka", channel: "Sivam - Topic", ms: 214_200, album: "Pushpa")] }
        let m = matcher([yt], store: MusicCanonicalStore(file: tempFile()))
        var row = catalogueTrack("Daakko Daakko Meka (From \"Pushpa\")", "Sivam", album: "Pushpa")
        row.album = MusicAlbumRef(id: "jio-album-77", title: "Pushpa")
        row.artists = [MusicArtistRef(id: "jio-artist-9", name: "Sivam")]
        let c = await m.twin(for: row)
        let shown = MusicCatalogMatcher.playableTrack(from: c!, catalogueRow: row)
        #expect(shown.providerID == "youtube-music")
        #expect(shown.album?.id == "" && shown.album?.title == "Pushpa")
        #expect(shown.artists.allSatisfy { $0.id.isEmpty })
        var same = row; same.providerID = "youtube-music"
        let kept = MusicCatalogMatcher.playableTrack(from: c!, catalogueRow: same)
        #expect(kept.album?.id == "jio-album-77")
    }

    @Test func missIsRememberedButOutageIsNot() async {
        let calls = Calls()
        let empty = FakeAudio(calls: calls) { _ in [] }
        let store = MusicCanonicalStore(file: tempFile())
        let m = matcher([empty], store: store)
        let row = catalogueTrack("Nothing Like It", "Nobody")
        #expect(await m.twin(for: row) == nil)
        let after = calls.count
        #expect(await m.twin(for: row) == nil)
        #expect(calls.count == after)

        struct Down: Error {}
        let dcalls = Calls()
        let down = FakeAudio(calls: dcalls) { _ in throw Down() }
        let m2 = matcher([down], store: MusicCanonicalStore(file: tempFile()))
        let row2 = catalogueTrack("Another One", "Someone")
        #expect(await m2.twin(for: row2) == nil)
        let c1 = dcalls.count
        #expect(await m2.twin(for: row2) == nil)
        #expect(dcalls.count > c1)

        let none = matcher([], store: MusicCanonicalStore(file: tempFile()))
        #expect(await none.twin(for: row2) == nil)
    }

    @Test func listShowsOnlyVerifiedAndNeverShrinks() async {
        let yt = FakeAudio { t in
            t.title.contains("Good") ? [source("g", "Good Song", channel: "Singer - Topic", ms: 200_000, album: "A")] : []
        }
        let m = matcher([yt], store: MusicCanonicalStore(file: tempFile()))
        let rows = [catalogueTrack("Good Song", "Singer", ms: 200_000, id: "1"), catalogueTrack("Bad Song", "Singer", ms: 200_000, id: "2")]
        let a = await m.playable(rows)
        #expect(a.count == 2 && a[0] != nil && a[1] == nil)
        let b = await m.playable(rows + [catalogueTrack("Good Song Two", "Singer", ms: 200_000, id: "3")])
        // The first answer's songs are all still there, in the same place: the list only grows.
        #expect(b[0]?.uid == a[0]?.uid && b[1] == nil)
    }

    @Test func playableTrackKeepsDirectStreamRows() async {
        let m = matcher([], store: MusicCanonicalStore(file: tempFile()))
        var t = catalogueTrack("Direct", "Someone")
        t.directStreams = [MusicStream(url: "https://x/y.mp3", codec: "mp3", container: "mp3")]
        let r = await m.playable([t])
        #expect(r[0]?.uid == t.uid)
    }

    @Test func theTimeBudgetCutsAHungSourceShort() async {
        // The source answers only after seconds; the budget is a fifth of one. The list must come back at the budget, not when the source finally answers.
        let slow = FakeAudio { _ in try? await Task.sleep(nanoseconds: 3_000_000_000); return [] }
        let m = matcher([slow], store: MusicCanonicalStore(file: tempFile()))
        let started = Date()
        let r = await m.playable([catalogueTrack("Slow One", "Someone")], budget: 0.2)
        #expect(Date().timeIntervalSince(started) < 1.5, "the budget is enforced")
        #expect(r.count == 1 && r[0] == nil)
    }

    @Test func expansionUsesCanonicalSpelling() async {
        let cat = FakeCatalogue(hits: [catalogueTrack("Daakko Daakko Meka", "Sivam", album: "Pushpa")])
        let m = matcher([], store: MusicCanonicalStore(file: tempFile()), cat: [cat])
        let e = await m.expand("dakko dakko meka")
        #expect(e.canonical?.title == "Daakko Daakko Meka" && e.queries.count >= 1 && e.queries.count <= 3)
        #expect(e.queries.contains("Daakko Daakko Meka Sivam"))
        let miss = await m.expand("completely unrelated words")
        #expect(miss.canonical == nil && miss.queries.isEmpty)
        let down = matcher([], store: MusicCanonicalStore(file: tempFile()))
        #expect(await down.expand("tum hi ho") == .none)
    }

    @Test func isrcMergesOnlyCloseRunningTimes() {
        let store = MusicCanonicalStore(file: tempFile())
        let a = MusicCatalogCanon.make(from: catalogueTrack("Song One", "A", ms: 200_000, id: "1", isrc: "USABC1234567"))
        var b = MusicCatalogCanon.make(from: catalogueTrack("Song One (Spelled Differently)", "A", ms: 203_000, id: "2", isrc: "USABC1234567"))
        b.versionTags = a.versionTags
        _ = store.put(a); let merged = store.put(b)
        #expect(merged.key == a.key && Set(merged.seenOn) == ["jiosaavn:1", "jiosaavn:2"] && store.count == 1)
        let c = MusicCatalogCanon.make(from: catalogueTrack("Song One Long Cut", "A", ms: 400_000, id: "3", isrc: "USABC1234567"))
        _ = store.put(c)
        #expect(store.count == 2)
    }
}

// Store -----------------------------------------------------------------------------------------------------------------------------

struct CanonicalStoreTests {
    private func entry(_ n: Int) -> MusicCanonicalTrack {
        MusicCatalogCanon.make(from: catalogueTrack("Song \(n)", "Artist \(n)", id: "\(n)"))
    }

    @Test func persistsAndClears() {
        let file = tempFile()
        let s = MusicCanonicalStore(file: file)
        var e = entry(1)
        e.twins = [MusicCanonicalTwin(providerID: "youtube-music", sourceID: "v", title: "Song 1", score: 0.9)]
        _ = s.put(e); s.flush()
        let reloaded = MusicCanonicalStore(file: file)
        #expect(reloaded.count == 1 && reloaded.canonical(for: catalogueTrack("Song 1", "Artist 1", id: "1"))?.twins.count == 1)
        reloaded.clear()
        #expect(reloaded.count == 0 && !FileManager.default.fileExists(atPath: file.path))
        #expect(MusicCanonicalStore(file: file).count == 0)
    }

    @Test func entriesExpireAfterThirtyDaysAndMissesAfterOne() {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let s = MusicCanonicalStore(file: tempFile(), now: { clock.t })
        var matched = entry(1)
        matched.twins = [MusicCanonicalTwin(providerID: "p", sourceID: "v", title: "t", score: 0.9)]
        _ = s.put(matched); _ = s.put(entry(2))
        clock.t = clock.t.addingTimeInterval(2 * 24 * 3600)
        #expect(s.canonical(for: catalogueTrack("Song 1", "Artist 1", id: "1")) != nil)
        #expect(s.canonical(for: catalogueTrack("Song 2", "Artist 2", id: "2")) == nil)
        clock.t = clock.t.addingTimeInterval(29 * 24 * 3600)
        #expect(s.canonical(for: catalogueTrack("Song 1", "Artist 1", id: "1")) == nil)
    }

    @Test func sizeIsCapped() {
        let s = MusicCanonicalStore(file: tempFile())
        for n in 0..<(MusicCanonicalStore.maxEntries + 25) { _ = s.put(entry(n)) }
        #expect(s.count == MusicCanonicalStore.maxEntries)
    }

    @Test func corruptFileIsSetAside() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let s = MusicCanonicalStore(file: file)
        #expect(s.count == 0 && FileManager.default.fileExists(atPath: file.appendingPathExtension("bad").path))
    }

    @Test func wipeClearsTheSharedRuntimeStore() {
        let s = MusicCanonicalStore(file: tempFile())
        _ = s.put(entry(1))
        let d = UserDefaults(suiteName: "catalogue-test-\(UUID().uuidString)")!
        MusicCatalogRuntime.shared.installForTesting(matcher: nil, store: s, defaults: d)
        MusicCatalogRuntime.shared.wipe()
        #expect(s.count == 0)
    }
}

// Hooks (runtime singleton: run one after another) ------------------------------------------------------------------------------------

@Suite(.serialized) struct CatalogueHookTests {
    private func install(_ store: MusicCanonicalStore, on: Bool = true) -> UserDefaults {
        let d = UserDefaults(suiteName: "catalogue-test-\(UUID().uuidString)")!
        d.set(on, forKey: MusicCatalogRuntime.settingKey)
        MusicCatalogRuntime.shared.installForTesting(matcher: matcher([], store: store), store: store, defaults: d)
        return d
    }
    private func uninstall() { MusicCatalogRuntime.shared.installForTesting(matcher: nil, store: MusicCanonicalStore(file: tempFile()), defaults: .standard) }

    @Test func lyricsAskWithCanonicalWordsFirst() {
        let store = MusicCanonicalStore(file: tempFile())
        var c = MusicCatalogCanon.make(from: catalogueTrack("Daakko Daakko Meka", "Sivam", album: "Pushpa"))
        c.twins = [MusicCanonicalTwin(providerID: "youtube-music", sourceID: "dQw4w9WgXcQ", title: "x", score: 0.9)]
        _ = store.put(c)
        _ = install(store)
        defer { uninstall() }
        let r = MusicLyricsRequest(videoID: "dQw4w9WgXcQ", title: "Dakko Dakko Meka song (from pushpa telugu)", artists: "LOOP Studio", album: nil, durationSeconds: 214)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v.first?.title == "Daakko Daakko Meka" && v.first?.artists == "Sivam" && v.count <= MusicLyricsQueryBuilder.maxVariants)
        #expect(Set(v.map { MusicText.normalize($0.title + " " + $0.artists) }).count == v.count)
    }

    @Test func lyricsAreUntouchedWhenOffOrUnknown() {
        let store = MusicCanonicalStore(file: tempFile())
        _ = store.put(MusicCatalogCanon.make(from: catalogueTrack("Daakko Daakko Meka", "Sivam")))
        let d = install(store, on: false)
        defer { uninstall() }
        let r = MusicLyricsRequest(videoID: nil, title: "Tum Hi Ho", artists: "Arijit Singh", album: nil, durationSeconds: 240)
        let plain = MusicLyricsQueryBuilder.variants(for: r)
        d.set(true, forKey: MusicCatalogRuntime.settingKey)
        #expect(MusicLyricsQueryBuilder.variants(for: r) == plain)
    }

    @Test func artworkUpgradesVideoFramesOnly() {
        let store = MusicCanonicalStore(file: tempFile())
        var c = MusicCatalogCanon.make(from: catalogueTrack("Song", "Artist", cover: "https://cdn.example/1200.jpg"))
        c.coverURL = "https://cdn.example/1200.jpg"
        c.twins = [MusicCanonicalTwin(providerID: "youtube-music", sourceID: "v", title: "Song", thumbnails: [MusicThumbnail(url: "https://i.ytimg.com/vi/v/hqdefault.jpg", width: 480, height: 360)], score: 0.9)]
        _ = store.put(c)
        _ = install(store)
        defer { uninstall() }
        let frame = [MusicThumbnail(url: "https://i.ytimg.com/vi/v/hqdefault.jpg", width: 480, height: 360)]
        #expect(MusicArtworkService.pickThumbnail(frame, neededPixels: 400) == "https://cdn.example/1200.jpg")
        let square = [MusicThumbnail(url: "https://lh3.example/art", width: 544, height: 544)]
        #expect(MusicArtworkService.pickThumbnail(square, neededPixels: 400) == "https://lh3.example/art")
    }

    @Test func artworkUntouchedWhenSettingOff() {
        let store = MusicCanonicalStore(file: tempFile())
        var c = MusicCatalogCanon.make(from: catalogueTrack("Song", "Artist"))
        c.coverURL = "https://cdn.example/1200.jpg"
        c.twins = [MusicCanonicalTwin(providerID: "p", sourceID: "v", title: "Song", thumbnails: [MusicThumbnail(url: "https://i.ytimg.com/vi/v/hq.jpg", width: 120, height: 90)], score: 0.9)]
        _ = store.put(c)
        _ = install(store, on: false)
        defer { uninstall() }
        #expect(MusicArtworkService.pickThumbnail([MusicThumbnail(url: "https://i.ytimg.com/vi/v/hq.jpg", width: 120, height: 90)], neededPixels: 400) == "https://i.ytimg.com/vi/v/hq.jpg")
    }

    @Test func catalogueOnlySourcesAreFlaggedAndFooterIsQuiet() {
        #expect(MusicSearchEnrichment.isCatalogueOnly(JioSaavnProvider().capabilities))
        #expect(MusicSearchEnrichment.isCatalogueOnly(ITunesProvider().capabilities))
        #expect(!MusicSearchEnrichment.isCatalogueOnly(AudiusProvider().capabilities))
    }

    @Test func noCatalogueEntityEverReachesSearch() async {
        let yt = FakeAudio { t in t.title == "Good Song" ? [source("g", "Good Song", channel: "Singer - Topic", ms: 200_000, album: "A")] : [] }
        let m = matcher([yt], store: MusicCanonicalStore(file: tempFile()))
        let artist = MusicArtist(id: "a", providerID: "jiosaavn", name: "Singer")
        let album = MusicAlbum(id: "al", providerID: "jiosaavn", title: "A")
        let playlist = MusicPlaylist(id: "p", providerID: "jiosaavn", name: "P")
        let results: [MusicSearchResult] = [.track(catalogueTrack("Good Song", "Singer", ms: 200_000, id: "1")), .artist(artist), .album(album), .playlist(playlist),
                                            .track(catalogueTrack("Dead Song", "Singer", id: "2"))]
        let out = await MusicSearchEnrichment.onlyPlayable(results, matcher: m)
        #expect(out.count == 1)
        if case .track(let t) = out[0] { #expect(t.providerID == "youtube-music") } else { Issue.record("only the playable twin may remain") }
        #expect(await MusicSearchEnrichment.onlyPlayable([.artist(artist)], matcher: m).isEmpty)
    }
}

// Enrichment ------------------------------------------------------------------------------------------------------------------------

struct CatalogueEnrichmentTests {
    private func song(_ title: String, _ id: String, ms: Int64 = 200_000, provider: String = "youtube-music", n: Int? = nil) -> MusicTrack {
        var t = MusicTrack(id: id, providerID: provider, title: title, durationMs: ms, artists: [MusicArtistRef(id: "s", name: "Sivam")]); t.trackNumber = n; return t
    }

    @Test func artistAliasesMerge() {
        #expect(MusicArtistCanon.key("Sid Sriram") == MusicArtistCanon.key("Sid Sri Ram"))
        #expect(MusicArtistCanon.key("Sid Sriram") == MusicArtistCanon.key("Sid Sree Ram"))
        #expect(MusicArtistCanon.key("Sid Sriram") != MusicArtistCanon.key("Sid Shankar"))
        let a = MusicArtist(id: "1", providerID: "youtube-music", name: "Sid Sri Ram", thumbnails: [MusicThumbnail(url: "small", width: 100, height: 100)])
        var b = MusicArtist(id: "2", providerID: "audius", name: "Sid Sriram - Topic", thumbnails: [MusicThumbnail(url: "big", width: 1000, height: 1000)])
        b.bio = "Singer"
        let merged = MusicArtistCanon.merge([a, b, MusicArtist(id: "3", providerID: "x", name: "Other")], preferredNames: ["Sid Sriram"])
        #expect(merged.count == 2 && merged[0].name == "Sid Sriram" && merged[0].id == "1" && merged[0].bio == "Singer" && merged[0].thumbnails.first?.url == "big")
    }

    @Test func albumIsOrderedFilledAndDeduplicated() {
        let own = MusicAlbum(id: "al", providerID: "youtube-music", title: "Pushpa The Rise", thumbnails: [MusicThumbnail(url: "https://i.ytimg.com/vi/x/hq.jpg", width: 480, height: 360)])
        let cat = MusicAlbum(id: "c", providerID: "jiosaavn", title: "Pushpa: The Rise", thumbnails: [MusicThumbnail(url: "https://cdn/1500.jpg", width: 1500, height: 1500)], releaseDate: "2021-12-17", label: "Mythri")
        let ctracks = [song("Srivalli", "c1", provider: "jiosaavn"), song("Daakko Daakko Meka", "c2", provider: "jiosaavn"), song("Oo Antava", "c3", provider: "jiosaavn")]
        let mine = [song("Oo Antava", "y3"), song("Srivalli", "y1", ms: 230_000), song("Srivalli", "y1b", ms: 200_500), song("Bonus Track", "y9")]
        let twin = song("Daakko Daakko Meka", "y2")
        let r = MusicAlbumMerge.merge(album: own, tracks: mine, catalogueAlbum: cat, catalogueTracks: ctracks, twins: [ctracks[1].uid: twin])
        #expect(r.tracks.map(\.id) == ["y1b", "y2", "y3", "y9"])
        #expect(r.tracks.prefix(3).map { $0.trackNumber } == [1, 2, 3])
        #expect(r.added == 1 && r.removedDuplicates == 1 && r.album.releaseDate == "2021-12-17" && r.album.label == "Mythri" && r.album.totalTracks == 3)
        #expect(r.album.thumbnails.first?.url == "https://cdn/1500.jpg" && r.tracks.allSatisfy { $0.album?.title == r.album.title })
    }

    @Test func trackNumbersCountOnEachDiscAndAnotherSourcesSongGetsNoAlbumId() {
        let own = MusicAlbum(id: "al", providerID: "youtube-music", title: "Two Discs")
        func cat(_ t: String, disc: Int) -> MusicTrack { var x = song(t, "c-" + t, provider: "jiosaavn"); x.discNumber = disc; return x }
        let c = [cat("A", disc: 1), cat("B", disc: 1), cat("C", disc: 2), cat("D", disc: 2)]
        let mine = [song("A", "yA"), song("B", "yB"), song("C", "yC")]
        let twinD = song("D", "yD", provider: "audius")
        let r = MusicAlbumMerge.merge(album: own, tracks: mine, catalogueAlbum: own, catalogueTracks: c, twins: [c[3].uid: twinD])
        #expect(r.tracks.map(\.trackNumber) == [1, 2, 1, 2])
        #expect(r.tracks[0].album?.id == "al")
        #expect(r.tracks[3].album?.id == "", "the copy from another source does not get this source's album id")
    }

    @Test func songsWithoutPlayableCopyAreNotInvented() {
        let own = MusicAlbum(id: "al", providerID: "youtube-music", title: "Jailer")
        let c = [song("Kaavaalaa", "c1", provider: "jiosaavn"), song("Hukum", "c2", provider: "jiosaavn")]
        let r = MusicAlbumMerge.merge(album: own, tracks: [song("Kaavaalaa", "y1")], catalogueAlbum: own, catalogueTracks: c, twins: [:])
        #expect(r.tracks.map(\.id) == ["y1"] && r.added == 0)
    }

    @Test func filmsGroupSongsInOrder() {
        let films = ["a": "Pushpa", "b": "Jailer", "c": "Pushpa", "d": nil] as [String: String?]
        let tracks = ["a", "b", "c", "d"].map { song($0, $0) }
        let g = MusicFilmGrouping.group(tracks) { films[$0.id] ?? nil }
        #expect(g.map { $0.film } == ["Pushpa", "Jailer", nil] && g[0].tracks.map(\.id) == ["a", "c"])
        #expect(MusicFilmGrouping.fromLine("Pushpa") == "From Pushpa")
    }

    @Test func discographyGroupsAndTopSongsUsePopularity() {
        let al = [MusicAlbum(id: "1", providerID: "p", title: "Old Album", releaseDate: "2015", totalTracks: 9),
                  MusicAlbum(id: "2", providerID: "p", title: "New Single", releaseDate: "2023", totalTracks: 1),
                  MusicAlbum(id: "3", providerID: "p", title: "Daakko Daakko Meka", releaseDate: nil, totalTracks: 6),
                  MusicAlbum(id: "4", providerID: "p", title: "Dakko Dakko Meka", releaseDate: "2021", totalTracks: 6)]
        let s = MusicDiscography.group(al)
        #expect(s.map(\.title) == ["Albums", "Singles and EPs"] && s[0].albums.count == 2 && s[0].albums.first?.title == "Daakko Daakko Meka")
        let a = song("A", "1"), b = song("B", "2")
        #expect(MusicDiscography.topSongs([a, b], popularity: [MusicAlbumMerge.key(b): 90, MusicAlbumMerge.key(a): 10]).map(\.id) == ["2", "1"])
    }

    @Test func playlistShelfShowsOnlyVerifiedTracksUnderItsOwnName() async {
        let yt = FakeAudio { t in t.title.hasPrefix("Good") ? [source(t.title, t.title, channel: "Singer - Topic", ms: 200_000, album: "A")] : [] }
        let m = matcher([yt], store: MusicCanonicalStore(file: tempFile()))
        let section = MusicBrowseSection(id: "top", title: "Top Telugu hits", items: [.track(catalogueTrack("Good One", "Singer", ms: 200_000, id: "1")),
            .track(catalogueTrack("Dead One", "Singer", id: "2")), .album(MusicAlbum(id: "x", providerID: "jiosaavn", title: "Cat Album"))])
        let r = await m.resolveShelf(section)
        #expect(r?.title == "Top Telugu hits" && r?.items.count == 1)
        if case .track(let t)? = r?.items.first { #expect(t.providerID == "youtube-music") }
        let empty = await m.resolveShelf(MusicBrowseSection(id: "e", title: "E", items: [.track(catalogueTrack("Dead One", "Singer", id: "2"))]))
        #expect(empty == nil)
    }

    @Test func artworkChoice() {
        let cover = "https://cdn/1200.jpg"
        let frame = [MusicThumbnail(url: "https://i.ytimg.com/vi/v/maxres.jpg", width: 1280, height: 720)]
        let small = [MusicThumbnail(url: "https://x/s.jpg", width: 120, height: 120)]
        let big = [MusicThumbnail(url: "https://x/b.jpg", width: 1000, height: 1000)]
        let unknown = [MusicThumbnail(url: "https://x/u.jpg")]
        #expect(MusicCatalogArtwork.choose(own: frame, catalogueCover: cover, neededPixels: 500) == cover)
        #expect(MusicCatalogArtwork.choose(own: small, catalogueCover: cover, neededPixels: 500) == cover)
        #expect(MusicCatalogArtwork.choose(own: unknown, catalogueCover: cover, neededPixels: 500) == cover)
        #expect(MusicCatalogArtwork.choose(own: [], catalogueCover: cover, neededPixels: 500) == cover)
        #expect(MusicCatalogArtwork.choose(own: big, catalogueCover: cover, neededPixels: 500) == nil)
        #expect(MusicCatalogArtwork.choose(own: small, catalogueCover: nil, neededPixels: 500) == nil)
    }
}
