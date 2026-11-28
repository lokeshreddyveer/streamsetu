import Foundation
import Testing
@testable import REDDY

// The first journey: a person who starts on Home and follows the connected pages, step by step, over the in-memory Awaara (1951) fixture graph and a
// fake audio source. At every step the test checks the route stack, that Back and Forward return the page memory, that the page's sections hold data
// with reasons, and that the music player has not moved. Only the last step plays.

@MainActor
final class JourneyRig {
    let g: SoundtrackFixtureGraph
    let hub: MusicHub
    private let root: URL
    private let suite: String
    var history = MusicNavHistory()

    /// The player state that navigation must never change.
    struct PlayerState: Equatable { var ids: [String]; var index: Int; var current: String?; var playing: Bool }
    var player: PlayerState { PlayerState(ids: hub.player.queue.map(\.uid), index: hub.player.index ?? -1, current: hub.player.current?.uid, playing: hub.player.isPlaying) }

    static func make() async throws -> JourneyRig {
        let g = try await SoundtrackFixtureGraph.build()
        return try JourneyRig(g)
    }

    init(_ g: SoundtrackFixtureGraph) throws {
        self.g = g
        root = FileManager.default.temporaryDirectory.appendingPathComponent("journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "journey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        hub = MusicHub(directory: root, defaults: defaults)
        for p in hub.registry.all { hub.registry.setEnabled(false, id: p.id, reason: .setup) }
        hub.registry.register(JourneyAudio())
        hub.registry.setEnabled(true, id: JourneyAudio.id, reason: .setup)
        hub.library.settings.consentDone = true
        MusicPageMemoryCenter.shared.clear()
        MusicEntityRuntime.shared.use(graph: g.graph)
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        MusicPageMemoryCenter.shared.clear()
    }

    // MARK: navigation the way MusicMainView does it

    private func rememberHere() {
        let key = history.current.scrollKey
        history.remember(MusicPageMemoryCenter.shared.memory(for: key))
    }
    private func arrive() {
        let change = history.observe(MusicNavEntry(hub.nav))
        if change == .steppedBack || change == .steppedForward {
            MusicPageMemoryCenter.shared.set(history.current.memory, for: history.current.scrollKey)
        }
    }
    func go(_ id: MusicEntityID, role: MusicRole? = nil) { rememberHere(); hub.open(id, role: role); arrive() }
    func back() { rememberHere(); hub.back(); arrive() }
    func forward() {
        rememberHere()
        guard let e = history.forward() else { return }
        MusicPageMemoryCenter.shared.set(e.memory, for: e.scrollKey)
        hub.nav.restore(e)
    }
    var top: MusicEntityID? { hub.nav.top?.entityID }
    var stackIDs: [MusicEntityID] { hub.nav.stack.compactMap(\.entityID) }
    /// What the page keeps for itself (scroll position, chosen role).
    func remember(_ key: String, scroll: Double, role: String? = nil) {
        MusicPageMemoryCenter.shared.update(key) { $0.scrollOffset = scroll; if let role { $0.filters["role"] = role } }
    }

    // MARK: sections

    /// Loads the loaders for one entity through the shared model center and returns every section once it has settled.
    func sections(_ id: MusicEntityID, _ loaders: [any MusicEntitySectionLoader]) async -> [String: MusicEntitySection] {
        let lease = MusicEntityRuntime.shared.center.acquire(id)
        defer { lease.release() }
        for l in loaders { lease.model.load(l) }
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            if loaders.allSatisfy({ [.loaded, .empty, .failed].contains(lease.model.section($0.key).phase) }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return Dictionary(uniqueKeysWithValues: loaders.map { ($0.key, lease.model.section($0.key)) })
    }

    func album(_ id: MusicEntityID) async -> [String: MusicEntitySection] { await sections(id, MusicSoundtrackLoaders.all(hooks: .none)) }
    func song(_ id: MusicEntityID) async -> [String: MusicEntitySection] { await sections(id, MusicSongLoaderEnv().loaders()) }
    func film(_ id: MusicEntityID) async -> [String: MusicEntitySection] { await sections(id, MusicFilmLoaders.core + ["film.related", "film.directorFilms", "film.composerMusic", "film.castMusic"].compactMap { MusicFilmLoaders.lazy($0) }) }
    func person(_ id: MusicEntityID, _ view: MusicPersonView) async -> [String: MusicEntitySection] {
        await sections(id, [MusicPersonProfileLoader(), MusicPersonViewLoader(view: view)])
    }
}

/// A source that knows no song: playing through it records the queue and never reaches a network.
struct JourneyAudio: MusicAudioProvider {
    static let id = "journey-audio"
    var info = MusicProviderInfo(id: JourneyAudio.id, name: "Journey source", summary: "Fixture")
    var capabilities: MusicCapabilities { .audio }
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] { [] }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] { [] }
}

/// True when a hashable item carries a non-empty reason (a `reason` or `reasons` property, however it is typed).
private func hasReason(_ item: Any) -> Bool {
    let m = Mirror(reflecting: item)
    for c in m.children {
        if let label = c.label, label == "reason" || label == "reasons" {
            if let a = c.value as? [Any] { return !a.isEmpty }
            return true
        }
    }
    // An enum of shelf entries wraps the card that carries the reason.
    if m.displayStyle == .enum { return m.children.contains { hasReason($0.value) } }
    return false
}
private func hasReason(_ item: AnyHashable) -> Bool { hasReason(item.base) }
private func items(_ s: [String: MusicEntitySection], _ key: String) -> [AnyHashable] { s[key]?.items ?? [] }

/// Every journey shares the app's one entity runtime, so they run one after the other.
@Suite("Music journeys", .serialized) enum MusicJourneys {}

extension MusicJourneys {
@MainActor
@Suite("Journey: Home to Awaara to song, singer, film, actor and back to a play") struct JourneyTests {
    @Test func theFirstJourneyWalksEveryPageAndOnlyTheLastStepPlays() async throws {
        let rig = try await JourneyRig.make()
        defer { rig.cleanup() }
        let g = rig.g
        let startPlayer = rig.player
        let hoon = try #require(g.recordings["Awaara Hoon"]), mukesh = try #require(g.people["Mukesh"]), raj = try #require(g.people["Raj Kapoor"])
        let shree420 = try #require(g.films["Shree 420"]), shreeAlbum = try #require(g.albums["Shree 420"])

        // Home
        #expect(rig.hub.nav.stack.isEmpty && rig.hub.nav.section == .home)

        // 1. Awaara (album route)
        rig.go(g.album)
        rig.remember(MusicRoute.entity(g.album).scrollKey, scroll: 420)
        var s = await rig.album(g.album)
        #expect(rig.stackIDs == [g.album] && rig.top == g.album)
        #expect(!items(s, MusicSoundtrackKey.header).isEmpty && !items(s, MusicSoundtrackKey.credits).isEmpty && !items(s, MusicSoundtrackKey.cast).isEmpty)
        #expect(!items(s, MusicSoundtrackKey.moreFilms).isEmpty)
        for key in [MusicSoundtrackKey.moreFilms, MusicSoundtrackKey.related, MusicSoundtrackKey.moreByComposers] {
            let list = items(s, key)
            #expect(list.allSatisfy(hasReason), "every card of \(key) says why it is there")
        }
        #expect(rig.player == startPlayer)

        // 2. Song (Awaara Hoon)
        rig.go(hoon)
        rig.remember(MusicRoute.entity(hoon).scrollKey, scroll: 90)
        s = await rig.song(hoon)
        #expect(rig.stackIDs == [g.album, hoon])
        #expect(!items(s, "song.credits").isEmpty && !items(s, "song.context").isEmpty)
        #expect(rig.player == startPlayer)

        // 3. Singer (Mukesh, role singer)
        rig.go(mukesh, role: .singer)
        rig.remember(MusicRoute.entity(mukesh, role: .singer).scrollKey, scroll: 30, role: "singer")
        s = await rig.person(mukesh, .singer)
        #expect(rig.hub.nav.top?.entityRoute?.role == .singer && rig.top == mukesh)
        #expect(!items(s, "person.profile").isEmpty && !items(s, MusicPersonViewLoader.key(.singer)).isEmpty)
        #expect(rig.player == startPlayer)

        // 4. Other album (a Mukesh album that is not Awaara)
        let other = try #require(g.albums["Mukesh Golden Hits"])
        rig.go(other)
        s = await rig.album(other)
        #expect(!items(s, MusicSoundtrackKey.header).isEmpty && rig.stackIDs.count == 4)
        #expect(rig.player == startPlayer)

        // 5. Film (Awaara 1951)
        rig.go(g.film)
        s = await rig.film(g.film)
        #expect(!items(s, MusicFilmSectionKey.cast).isEmpty && !items(s, MusicFilmSectionKey.crew).isEmpty && !items(s, MusicFilmSectionKey.soundtracks).isEmpty)
        #expect(items(s, MusicFilmSectionKey.related).allSatisfy(hasReason) && !items(s, MusicFilmSectionKey.related).isEmpty)
        #expect(rig.player == startPlayer)

        // 6. Actor (Raj Kapoor, role actor)
        rig.go(raj, role: .actor)
        s = await rig.person(raj, .actor)
        #expect(rig.hub.nav.top?.entityRoute?.role == .actor)
        #expect(!items(s, MusicPersonViewLoader.key(.actor)).isEmpty)

        // 7. Other film, then its soundtrack
        rig.go(shree420)
        s = await rig.film(shree420)
        #expect(!items(s, MusicFilmSectionKey.soundtracks).isEmpty)
        rig.go(shreeAlbum)
        s = await rig.album(shreeAlbum)
        let songs = MusicSoundtrackSongs.rows(provider: [], recordings: await MusicSoundtrackReader(g.graph).recordings(await MusicSoundtrackReader(g.graph).family(of: shreeAlbum)), singers: [:])
        #expect(!items(s, MusicSoundtrackKey.header).isEmpty)
        #expect(rig.stackIDs.count == 8 && rig.top == shreeAlbum)
        #expect(rig.player == startPlayer, "ten pages of navigation did not touch the player")

        // Back and Forward return the page memory of the pages they pass
        for _ in 0..<(rig.stackIDs.count - 3) { rig.back() }
        #expect(rig.top == mukesh && rig.hub.nav.top?.entityRoute?.role == .singer)
        #expect(MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(mukesh, role: .singer).scrollKey).scrollOffset == 30)
        #expect(MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(mukesh, role: .singer).scrollKey).filters["role"] == "singer")
        rig.back()
        #expect(rig.top == hoon && MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(hoon).scrollKey).scrollOffset == 90)
        rig.back()
        #expect(rig.top == g.album && MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(g.album).scrollKey).scrollOffset == 420)
        rig.forward()
        #expect(rig.top == hoon)
        #expect(rig.player == startPlayer, "Back and Forward did not touch the player")

        // 8. Play song: the only step that moves the player
        let track = MusicTrack(id: "journey-1", providerID: JourneyAudio.id, title: songs.first?.title ?? "Ek Do Teen", durationMs: 200_000,
                               artists: [MusicArtistRef(id: "", name: "Mukesh")])
        rig.hub.play([track], at: 0)
        #expect(rig.player != startPlayer)
        #expect(rig.hub.player.queue.map(\.id) == ["journey-1"] && rig.hub.player.current?.id == "journey-1")
        #expect(rig.top == hoon, "playing does not navigate")
    }

    @Test func aNonFilmAlbumHasNoFilmSectionsAndStillOpens() async throws {
        let rig = try await JourneyRig.make()
        defer { rig.cleanup() }
        let indie = try #require(rig.g.albums["Quiet Hours"])
        rig.go(indie)
        let s = await rig.album(indie)
        #expect(!items(s, MusicSoundtrackKey.header).isEmpty)
        #expect(items(s, MusicSoundtrackKey.cast).isEmpty && items(s, MusicSoundtrackKey.moreFilms).isEmpty)
        let h = items(s, MusicSoundtrackKey.header).compactMap { $0.base as? MusicSoundtrackHeaderFacts }.first
        #expect(h?.film == nil)
        #expect(rig.top == indie)
    }

    @Test func twoPeopleWithOneNameStayTwoPagesAndBackReturnsTheRightOne() async throws {
        let rig = try await JourneyRig.make()
        defer { rig.cleanup() }
        let a = try #require(rig.g.people["Raj Kapoor"]), b = rig.g.secondRajKapoor
        #expect(a != b)
        rig.go(a, role: .actor); rig.remember(MusicRoute.entity(a, role: .actor).scrollKey, scroll: 11)
        rig.go(b, role: .singer)
        #expect(rig.top == b)
        let sb = await rig.person(b, .singer), sa = await rig.person(a, .actor)
        #expect(items(sb, "person.profile") != items(sa, "person.profile"))
        rig.back()
        #expect(rig.top == a && MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(a, role: .actor).scrollKey).scrollOffset == 11)
    }

    @Test func aFilmWithoutASoundtrackShowsCastAndNoMusicSections() async throws {
        let rig = try await JourneyRig.make()
        defer { rig.cleanup() }
        let jagte = try #require(rig.g.films["Jagte Raho"])
        let before = rig.player
        rig.go(jagte)
        let s = await rig.film(jagte)
        #expect(items(s, MusicFilmSectionKey.soundtracks).compactMap { $0.base as? MusicFilmAlbumItem }.isEmpty)
        #expect(items(s, MusicFilmSectionKey.songs).compactMap { $0.base as? MusicFilmSongItem }.isEmpty)
        #expect(!(items(s, MusicFilmSectionKey.overview)).isEmpty)
        #expect(rig.player == before)
    }

    @Test func aMetadataOutageMidJourneyKeepsTheStackAndMemoryAndRecovers() async throws {
        let rig = try await JourneyRig.make()
        defer { rig.cleanup() }
        let g = rig.g
        let mukesh = try #require(g.people["Mukesh"])
        rig.go(g.album); rig.remember(MusicRoute.entity(g.album).scrollKey, scroll: 55)
        rig.go(mukesh, role: .singer)
        // The store starts failing: every edge read throws
        MusicEntityRuntime.shared.use(graph: FlakyGraph(base: g.graph, failIncoming: Set(MusicPredicate.allCases), failEntities: [mukesh]))
        let s = await rig.person(mukesh, .singer)
        #expect(rig.top == mukesh, "the page stays where it is")
        #expect(s.values.allSatisfy { [.empty, .failed, .partial, .loaded].contains($0.phase) }, "every section settled, none hangs")
        rig.back()
        #expect(rig.top == g.album && MusicPageMemoryCenter.shared.memory(for: MusicRoute.entity(g.album).scrollKey).scrollOffset == 55)
        // The store comes back
        MusicEntityRuntime.shared.use(graph: g.graph)
        let again = await rig.person(mukesh, .singer)
        #expect(!items(again, MusicPersonViewLoader.key(.singer)).isEmpty)
    }
}
}
