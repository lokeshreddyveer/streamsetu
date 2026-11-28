import Foundation
import Testing
@testable import REDDY

/// Runs every loader against a fixture graph and gathers the sections the way the entity model would.
private func loaded(_ f: SongFixture, _ key: String, skip: Set<MusicSongSectionKey> = []) async throws -> MusicSongPageData {
    var data = MusicSongPageData(selfID: f[key])
    data.selfName = (try await f.graph.entity(f[key]))?.name ?? ""
    let env = MusicSongLoaderEnv()
    for l in env.loaders() {
        guard let k = MusicSongSectionKey.allCases.first(where: { $0.loaderKey == l.key }), !skip.contains(k) else { continue }
        let r = try await l.load(entity: f[key], store: f.graph, report: SongPartials().reporter)
        var s = MusicEntitySection(key: l.key)
        s.items = r.items
        s.phase = r.items.isEmpty ? .empty : .loaded
        data.sections[k] = s
    }
    data.hasMatchBase = true
    data.providerAvailable = true
    data.providerState = .loaded
    data.providerName = "YouTube Music"
    return data
}

@Suite struct SongPageDataTests {
    @Test func awaraHoonShowsEveryBlockItHasDataFor() async throws {
        let f = await SongFixture.awaara()
        var d = try await loaded(f, "awara")
        d.localPlaylists = [MusicSongPlaylistItem(id: "local:1", name: "Road trip", source: .local, entityID: nil, localID: UUID(), imageRef: nil)]
        // live, films, similar and in-playlists are not drawn (see MusicSongBlock.notDrawn)
        #expect(d.visibleBlocks == [.credits, .lyrics, .versions, .related, .moreBySinger, .moreByComposer, .sources])
        // every similar recording is already a related song here, so it is not listed twice
        #expect(d.similar.isEmpty)
        #expect(d.playlists.map(\.name) == ["Road trip", "Golden Hits"])
        #expect(d.context?.film?.film.name == "Awaara")
        #expect(d.liveItems.map(\.id) == [f["live"]])
    }

    @Test func nothingIsShownTwice() async throws {
        let f = await SongFixture.awaara()
        let d = try await loaded(f, "awara")
        let versionIDs = Set(d.versionItems.map(\.id))
        #expect(d.related.allSatisfy { !versionIDs.contains($0.id) })
        let relatedIDs = Set(d.related.map(\.id))
        #expect(d.similar.allSatisfy { !relatedIDs.contains($0.id) && !versionIDs.contains($0.id) })
        #expect(d.moreBySinger.allSatisfy { !versionIDs.contains($0.id) })
        #expect(![d.related, d.moreBySinger, d.moreByComposer, d.films, d.similar].flatMap { $0 }.contains { $0.id == f["awara"] })
    }

    @Test func aSongWithNoCreditsShowsOneQuietLineAndNoEmptyHeadings() async throws {
        let f = SongFixture()
        await f.entity("bare", .recording, "Untitled Demo", uid: "jiosaavn:s-bare", provisional: true)
        let d = try await loaded(f, "bare")
        #expect(d.state(.credits) == .quietEmpty)
        #expect(d.visibleBlocks == [.credits, .lyrics, .sources])
        #expect(d.isBare == false)  // the quiet credits line counts: there is still something to read
    }

    @Test func providerSuggestionsAloneFillTheRelatedBlock() async throws {
        let f = SongFixture()
        await f.entity("solo", .recording, "Solo", uid: "audius:solo")
        var d = try await loaded(f, "solo")
        #expect(d.state(.related) == .hidden)
        d.providerRelated = [MusicTrack(id: "9", providerID: "audius", title: "Other Song", durationMs: 1, artists: [MusicArtistRef(id: "", name: "Someone")])]
        #expect(d.state(.related) == .content && d.related.first?.reason.kind == .providerSuggestion)
    }

    @Test func relatedStaysASkeletonUntilBothSourcesAnswer() async throws {
        let f = SongFixture()
        await f.entity("solo", .recording, "Solo", uid: "audius:solo")
        var d = try await loaded(f, "solo")
        d.providerState = .loading
        #expect(d.state(.related) == .skeleton)
        d.sections[.related] = MusicEntitySection(key: MusicSongSectionKey.related.loaderKey)
        d.providerState = .loaded
        #expect(d.state(.related) == .skeleton)   // the graph has not answered yet
    }

    @Test func partialCreditsShowAsTheyArrive() {
        var d = MusicSongPageData(selfID: MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA"))
        var s = MusicEntitySection(key: MusicSongSectionKey.credits.loaderKey)
        s.phase = .loading
        d.sections[.credits] = s
        #expect(d.state(.credits) == .skeleton)
        let singer = MusicSongCreditPerson(id: MusicEntityID(kind: .person, token: "PPPPPPPPPPPPP"), name: "Mukesh", role: .singer, status: .verified, confidence: 1, level: .song)
        s.items = [MusicSongCreditGroup(kind: .singers, people: [singer])]
        s.phase = .partial
        d.sections[.credits] = s
        #expect(d.state(.credits) == .content)
    }

    @Test func aMetadataOutageKeepsWhatIsCachedAndHidesWhatIsNot() {
        var d = MusicSongPageData(selfID: MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA"))
        var failedEmpty = MusicEntitySection(key: MusicSongSectionKey.versions.loaderKey); failedEmpty.phase = .failed
        d.sections[.versions] = failedEmpty
        #expect(d.state(.versions) == .hidden)
        var failedWithItems = MusicEntitySection(key: MusicSongSectionKey.credits.loaderKey); failedWithItems.phase = .failed
        failedWithItems.items = [MusicSongCreditGroup(kind: .singers, people: [MusicSongCreditPerson(id: MusicEntityID(kind: .person, token: "PPPPPPPPPPPPP"), name: "Mukesh", role: .singer, status: .verified, confidence: 1, level: .song)])]
        d.sections[.credits] = failedWithItems
        #expect(d.state(.credits) == .content)
    }

    @Test func sourcesBlockNeedsARowToLookUp() {
        var d = MusicSongPageData(selfID: MusicEntityID(kind: .recording, token: "AAAAAAAAAAAAA"))
        #expect(d.state(.sources) == .hidden)
        d.hasMatchBase = true
        #expect(d.state(.sources) == .content)
    }
}
