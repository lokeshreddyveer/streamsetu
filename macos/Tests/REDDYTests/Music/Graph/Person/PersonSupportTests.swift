import Foundation
import Testing
@testable import REDDY

@Suite struct PersonSupportTests {
    private func build(_ w: PersonWorld, _ id: MusicEntityID, _ v: MusicPersonView) async throws -> MusicPersonViewData {
        try await MusicPersonReader(store: w.store, person: id).build(v)
    }

    @MainActor @Test func aFreshLinkWithARoleForgetsTheRoleRememberedFromAnEarlierVisit() {
        let id = MusicEntityID.derive(kind: .person, aliasKey: "person-support-fresh-link")
        let key = MusicRoute.person(id, role: .director).scrollKey
        MusicPageMemoryCenter.shared.update(key) { $0.filters["role"] = "actor" }
        MusicHub.forgetRememberedRole(id, role: nil)
        #expect(MusicPageMemoryCenter.shared.memory(for: key).filters["role"] == "actor", "a link with no role leaves the memory alone")
        MusicHub.forgetRememberedRole(id, role: .director)
        #expect(MusicPageMemoryCenter.shared.memory(for: key).filters["role"] == nil)
    }

    @Test func aPersonWithTwoProviderIdsKeepsTheFollowedOne() {
        let uids = ["itunes:11", "jiosaavn:22"]
        let followed = MusicProviderUID.followedArtist(in: uids, followed: ["jiosaavn:22"])
        #expect(followed?.providerID == "jiosaavn" && followed?.id == "22")
        #expect(MusicProviderUID.followedArtist(in: uids, followed: []) == nil)
    }

    @Test func playSourceFollowsTheActiveRole() async throws {
        let w = try await PersonWorld.make()
        let singer = MusicPersonPlaySource.choose(try await build(w, w.mukesh, .singer))
        guard case .songs(let ids) = singer else { Issue.record("singer should play songs"); return }
        #expect(ids.first == w.awaaraHoon && ids.count == 5)
        let actor = MusicPersonPlaySource.choose(try await build(w, w.raj, .actor))
        guard case .songs(let film) = actor else { Issue.record("actor should play songs of his films"); return }
        #expect(Set(film) == [w.awaaraHoon, w.gharAaya, w.joota, w.pyar])
        // a director has no song list: the soundtracks play from their provider tracklists
        guard case .albums(let albums) = MusicPersonPlaySource.choose(try await build(w, w.raj, .director)) else { Issue.record("director should play albums"); return }
        #expect(Set(albums).isSubset(of: [w.awaaraAlbum, w.shreeAlbum]) && !albums.isEmpty)
        // nothing loaded, or an actor with no soundtracks: the provider's own top tracks keep Play working
        #expect(MusicPersonPlaySource.choose(nil) == .providerArtist)
        #expect(MusicPersonPlaySource.choose(try await build(w, w.pran, .actor)) == .providerArtist)
    }

    @Test func providerUIDSplitsAtTheFirstColon() {
        #expect(MusicProviderUID.split("jiosaavn:abc123")?.providerID == "jiosaavn")
        #expect(MusicProviderUID.split("ytmusic:a:b")?.id == "a:b")
        #expect(MusicProviderUID.split("nocolon") == nil && MusicProviderUID.split(":x") == nil && MusicProviderUID.split("p:") == nil)
        #expect(MusicProviderUID.uids(in: [ExternalID(.wikidata, "Q1"), ExternalID(.provider, "jiosaavn:1")]) == ["jiosaavn:1"])
    }

    @Test func imageAddressesAreHttpsOrNothing() {
        #expect(MusicPersonImage.address("commons:Mukesh.jpg")?.hasPrefix("https://commons.wikimedia.org/") == true)
        #expect(MusicPersonImage.address("https://image.tmdb.org/t/p/w185/a.jpg") == "https://image.tmdb.org/t/p/w185/a.jpg")
        #expect(MusicPersonImage.address("ftp://x/a.jpg") == nil && MusicPersonImage.address(nil) == nil && MusicPersonImage.address("") == nil)
    }

    @Test func filmographyFiltersByDecadeAndLanguageAndRoundTripsThroughMemory() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.raj, .actor)
        let all = d.section(.filmography)!.entries
        #expect(MusicFilmographyFilter.decades(in: all) == [1950, 1940] && MusicFilmographyFilter.languages(in: all).isEmpty)
        let f = MusicFilmographyFilter(decade: 1950)
        #expect(f.apply(to: all).map(\.name) == ["Shree 420", "Awaara"])
        #expect(MusicFilmographyFilter(decade: 1940, language: "hi").apply(to: all).map(\.name) == ["Barsaat", "Aag"])
        #expect(MusicFilmographyFilter(language: "te").apply(to: all).isEmpty)
        var mem: [String: String] = ["other": "keep"]
        f.write(to: &mem)
        #expect(MusicFilmographyFilter(memory: mem) == f && mem["other"] == "keep")
        MusicFilmographyFilter.none.write(to: &mem)
        #expect(MusicFilmographyFilter(memory: mem) == .none && mem["decade"] == nil)
    }
}
