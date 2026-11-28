import Foundation
import Testing
@testable import REDDY

/// Round 7, album lane: albums with no provider id, switched-off sources, the page skeleton and the cover gallery.
@Suite("Album round 7") struct AlbumRound7Tests {
    // MARK: B1 / B2 albums with an empty id

    @Test func anAlbumWithNoIDGetsNoSharedProviderID() {
        let ref = MusicAlbumRef(id: "", title: "Untitled")
        let draft = MusicGraphAdapters.albumDraft(ref, providerID: "jiosaavn")
        #expect(draft.externalIDs.isEmpty)
        let real = MusicGraphAdapters.albumDraft(MusicAlbumRef(id: "42", title: "Real"), providerID: "jiosaavn")
        #expect(real.externalIDs == [ExternalID(.provider, "jiosaavn:42")])
        let whole = MusicAlbum(id: "", providerID: "jiosaavn", title: "Untitled")
        #expect(MusicGraphAdapters.albumDraft(whole).externalIDs.isEmpty)
    }

    @Test func aTrackOnAnIDlessAlbumIsNotLinkedToASharedRelease() {
        var t = MusicTrack(id: "t1", providerID: "jiosaavn", title: "Song", durationMs: 1000, artists: [])
        t.album = MusicAlbumRef(id: "", title: "Untitled")
        let hasAlbumLink = MusicGraphAdapters.plan(for: t).links.contains { $0.predicate == .trackOn }
        #expect(!hasAlbumLink)
        t.album = MusicAlbumRef(id: "9", title: "Real")
        let linked = MusicGraphAdapters.plan(for: t).links.contains { $0.predicate == .trackOn }
        #expect(linked)
    }

    @MainActor @Test func openingAnAlbumWithNoIDPushesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("album-r7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "album.r7.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = MusicHub(directory: root, defaults: defaults)
        let before = hub.nav.top
        hub.open(.album(MusicAlbum(id: "", providerID: "p", title: "Untitled")))
        #expect(hub.nav.top == before)
        let ref = MusicAlbumRef(id: "", title: "Untitled")
        var t = MusicTrack(id: "t", providerID: "p", title: "S", durationMs: 1, artists: [])
        t.album = ref
        #expect(MusicEntityActions.albumRoute(.track(t), hub: hub) == nil)
    }

    /// The repair: a graph written by an old build holds `provider-name:` ids shared by every id-less album; migrating removes them and keeps real ids.
    @Test func theRepairRemovesSharedEmptyProviderIDs() async throws {
        let (s, dir) = GraphTestSupport.makeStore(); defer { GraphTestSupport.cleanup(dir) }
        _ = try await s.upsert(MusicEntityDraft(kind: .release, name: "Merged", externalIDs: [ExternalID(.provider, "jiosaavn:")]))
        _ = try await s.upsert(MusicEntityDraft(kind: .release, name: "Real", externalIDs: [ExternalID(.provider, "jiosaavn:77")]))
        try await s.withWriter { try $0.exec("UPDATE meta SET v = '1' WHERE k = 'schema'") }
        let s2 = MusicGraphStore(directory: dir)
        let shared = try await s2.withWriter { try $0.scalarInt("SELECT count(*) FROM external_id WHERE scheme = 'provider' AND substr(value, -1) = ':'") }
        let kept = try await s2.withWriter { try $0.scalarInt("SELECT count(*) FROM external_id WHERE scheme = 'provider' AND value = 'jiosaavn:77'") }
        #expect(shared == 0)
        #expect(kept == 1)
    }

    // MARK: B3 a switched-off source is not asked

    @MainActor @Test func aSwitchedOffMetadataSourceIsNotReturned() {
        let suite = "album.r7.reg.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let reg = MusicRegistry(defaults: defaults)
        MusicBuiltIns.register(into: reg)
        let id = JioSaavnDiscoveryProvider.id
        reg.setEnabled(true, id: id)
        #expect(reg.metadataProvider(id: id) != nil)
        reg.setEnabled(false, id: id)
        #expect(reg.metadataProvider(id: id) == nil)
    }

    @Test func theProviderAlbumTakesTheFirstEnabledSourceOfTheFamily() async throws {
        let (s, dir) = GraphTestSupport.makeStore(); defer { GraphTestSupport.cleanup(dir) }
        let id = try await s.upsert(MusicEntityDraft(kind: .release, name: "Album", externalIDs: [ExternalID(.provider, "itunes:1"), ExternalID(.provider, "jiosaavn:2")])).id
        let reader = MusicSoundtrackReader(s)
        let family = await reader.family(of: id)
        let onlyJio = await MusicSoundtrackSongs.providerAlbum(reader, family: family, enabled: ["jiosaavn"])
        #expect(onlyJio?.provider == "jiosaavn" && onlyJio?.id == "2")
        let none = await MusicSoundtrackSongs.providerAlbum(reader, family: family, enabled: ["spotify"])
        #expect(none == nil)
        let any = await MusicSoundtrackSongs.providerAlbum(reader, family: family)
        #expect(any != nil)
    }

    // MARK: B5 / B7 page skeleton and preferred edition

    @Test func theSkeletonEndsInAnUnavailableStateWhenTheLookupAnsweredNothing() {
        #expect(MusicProviderEntityPage.showsUnavailable(resolved: nil, lookupFinished: true))
        #expect(!MusicProviderEntityPage.showsUnavailable(resolved: nil, lookupFinished: false))
        let id = MusicEntityID.provisional(kind: .release, providerUID: "p:1")
        #expect(!MusicProviderEntityPage.showsUnavailable(resolved: id, lookupFinished: true))
    }

    @Test func aProviderOpenLandsOnThePreferredEdition() {
        let a = MusicEntityID.provisional(kind: .release, providerUID: "p:a")
        let b = MusicEntityID.provisional(kind: .release, providerUID: "p:b")
        let concept = MusicEntityID.provisional(kind: .album, providerUID: "p:concept")
        var prefs = MusicAlbumPrefs()
        #expect(prefs.preferredRedirect(from: a, concept: concept) == nil)
        prefs.preferred[concept.rawValue] = b.rawValue
        #expect(prefs.preferredRedirect(from: a, concept: concept) == b)
        #expect(prefs.preferredRedirect(from: b, concept: concept) == nil, "already on it")
        prefs.setHidden(b, true)
        #expect(prefs.preferredRedirect(from: a, concept: concept) == nil, "a hidden edition is not a landing page")
    }

    @Test func aTrackRepeatedInOnePageIsListedOnce() {
        let t = MusicTrack(id: "1", providerID: "p", title: "A", durationMs: 1, artists: [])
        let u = MusicTrack(id: "2", providerID: "p", title: "B", durationMs: 1, artists: [])
        var seen = Set<String>()
        let first = MusicSoundtrackSongs.unseen([t, u, t], seen: &seen)
        #expect(first.map(\.id) == ["1", "2"])
        let second = MusicSoundtrackSongs.unseen([u], seen: &seen)
        #expect(second.isEmpty)
    }

    // MARK: B8 gallery reopen

    @Test func aReopenDuringACancelledLoadStartsANewRead() {
        let e = MusicEntityID.provisional(kind: .release, providerUID: "p:1")
        let other = MusicEntityID.provisional(kind: .release, providerUID: "p:2")
        #expect(MusicAlbumArtworkModel.shouldStart(phase: .idle, requested: nil, entity: e))
        #expect(MusicAlbumArtworkModel.shouldStart(phase: .loading, requested: e, entity: e), "the earlier read may be a cancelled one")
        #expect(!MusicAlbumArtworkModel.shouldStart(phase: .loaded, requested: e, entity: e))
        #expect(MusicAlbumArtworkModel.shouldStart(phase: .loaded, requested: e, entity: other))
    }

    // MARK: conformance additions

    private func tracks(_ n: Int) -> [MusicTrack] {
        (0..<n).map { MusicTrack(id: "t\($0)", providerID: "p", title: "S\($0)", durationMs: 1000, artists: []) }
    }

    @Test func theAlbumRadioIsSeededFromTheWholeAlbum() {
        let list = tracks(12)
        let seeds = MusicAlbumPageLogic.radioSeeds(list, cap: 5)
        #expect(seeds.count == 5)
        #expect(seeds.first?.id == "t0" && seeds.last?.id == "t11")
        #expect(MusicAlbumPageLogic.radioSeeds(tracks(3), cap: 5).count == 3)
        #expect(MusicAlbumPageLogic.radioSeeds([], cap: 5).isEmpty)
    }

    @Test func likingTheSelectionSkipsLikedSongsAndNeverUnlikes() {
        let list = tracks(4)
        let already: Set<String> = [list[1].uid]
        let fresh = MusicAlbumPageLogic.toLike(list + [list[0]], isLiked: { already.contains($0.uid) })
        #expect(fresh.map(\.id) == ["t0", "t2", "t3"])
    }

    @Test func theListeningStatsAddUpTheTimeActuallyListened() {
        let list = tracks(2)
        let history = [PlayRecord(track: list[0], playedMs: 200_000), PlayRecord(track: list[0], playedMs: 150_000), PlayRecord(track: tracks(5)[4], playedMs: 99_000)]
        let stats = MusicAlbumListening.stats(trackUIDs: list.map(\.uid), history: history, liked: [])
        let counted = history.filter { HomeTaste.counts($0) && list.map(\.uid).contains($0.track.uid) }.map(\.playedMs).reduce(0, +)
        #expect(stats.listenedMs == counted)
        #expect(stats.listenedMs <= 350_000)
    }

    @Test func onlyAWholeDayIsShownAsTheReleaseDate() {
        #expect(MusicAlbumPageLogic.fullDate("2023-03-24") != nil)
        #expect(MusicAlbumPageLogic.fullDate("2023-03-24T00:00:00Z") != nil)
        #expect(MusicAlbumPageLogic.fullDate("2023-03") == nil)
        #expect(MusicAlbumPageLogic.fullDate("2023") == nil)
    }
}
