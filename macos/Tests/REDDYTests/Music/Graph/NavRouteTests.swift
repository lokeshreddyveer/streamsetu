import Foundation
import Testing
@testable import REDDY

@Suite("Music graph navigation: routes, paths, links, legacy adapters") struct NavRouteTests {
    private let album = MusicAlbum(id: "a1", providerID: "p", title: "Album")
    private let artist = MusicArtist(id: "r1", providerID: "p", name: "Artist")
    private func id(_ kind: MusicEntityKind, _ uid: String) -> MusicEntityID { .provisional(kind: kind, providerUID: uid) }

    @Test func entityRoutesCompareOnIdAndRoleOnly() {
        let a = id(.person, "p:1")
        #expect(MusicRoute.person(a) == .person(a))
        #expect(MusicRoute.person(a, role: .singer) != .person(a))
        #expect(MusicRoute.person(a, role: .singer) != .person(a, role: .composer))
        #expect(MusicRoute.film(id(.film, "x")) != .film(id(.film, "y")))
    }

    @Test func everyKindRoundTripsThroughItsPath() throws {
        for kind in MusicEntityKind.allCases {
            let route = MusicRoute.entity(id(kind, "p:" + kind.slug))
            let path = try #require(route.path)
            #expect(MusicRoute(path: path) == route)
        }
        let withRole = MusicRoute.person(id(.person, "p:9"), role: .musicDirector)
        #expect(MusicRoute(path: try #require(withRole.path)) == withRole)
        for c in MusicCollectionKey.allCases { #expect(MusicRoute(path: MusicRoute.collection(c).path ?? "") == .collection(c)) }
    }

    @Test func badPathsAreRefused() {
        for bad in ["", "album", "album/short", "nope/ABCDEFGHJKMNP", "collection/unknown", "person/ABCDEFGHJKMNP?role=nonsense", "person/ABCDEFGHJKMNP?x=1"] {
            #expect(MusicRoute(path: bad) == nil, "\(bad)")
        }
    }

    @Test func legacyRoutesCarryNoPathAndKeepTheirScrollKeys() {
        #expect(MusicRoute.album(album).path == nil)
        #expect(MusicRoute.album(album).persisted == nil)
        #expect(MusicRoute.album(album).scrollKey == "album:p:a1")
        #expect(MusicRoute.artist(artist).scrollKey == "artist:p:r1")
        #expect(MusicRoute.blacklist.scrollKey == "blacklist")
        #expect(MusicRoute.person(id(.person, "p:1"), role: .singer).scrollKey.hasPrefix("entity:person:"))
        #expect(MusicRoute.person(id(.person, "p:1"), role: .singer).scrollKey != MusicRoute.person(id(.person, "p:1")).scrollKey)
    }

    // MARK: stack rules

    @Test func cycleTruncatesToTheFirstOccurrence() {
        let a = MusicRoute.albumPage(id(.album, "a")), b = MusicRoute.person(id(.person, "b")), c = MusicRoute.film(id(.film, "c"))
        var nav = MusicNav()
        nav.push(a); nav.push(b); nav.push(a)
        #expect(nav.stack == [a])
        nav.push(b); nav.push(c); nav.push(b)
        #expect(nav.stack == [a, b])
    }

    @Test func consecutiveDuplicatesCollapse() {
        let a = MusicRoute.albumPage(id(.album, "a"))
        var nav = MusicNav()
        nav.push(a); nav.push(a); nav.push(a)
        #expect(nav.stack.count == 1)
    }

    @Test func aPersonWithAnotherRoleIsAnotherDestination() {
        let p = id(.person, "p")
        var nav = MusicNav()
        nav.push(.person(p, role: .singer)); nav.push(.person(p, role: .composer))
        #expect(nav.stack.count == 2)
    }

    @Test func aLegacyAlbumAndItsEntityRouteAreOneDestination() {
        var nav = MusicNav()
        nav.push(.album(album)); nav.push(.artist(artist))
        nav.push(MusicRouteResolver.provisionalRoute(for: .album(album)) ?? .blacklist)
        #expect(nav.stack.count == 1)
        #expect(nav.top?.entityID == id(.release, album.uid))
    }

    @Test func theStackIsCapped() {
        var nav = MusicNav()
        for i in 0..<(MusicNav.depthCap + 25) { nav.push(.entity(id(.recording, "p:\(i)"))) }
        #expect(nav.stack.count == MusicNav.depthCap)
        #expect(nav.top == .entity(id(.recording, "p:\(MusicNav.depthCap + 24)")))
    }

    @Test func choosingASectionClearsEntityRoutes() {
        var nav = MusicNav()
        nav.push(.film(id(.film, "x"))); nav.select(.search)
        #expect(nav.stack.isEmpty && nav.section == .search)
    }

    // MARK: legacy adapters

    @Test func legacyRoutesConvertWithoutADatabaseRead() {
        #expect(MusicRouteResolver.provisionalRoute(for: .album(album)) == .entity(id(.release, album.uid)))
        #expect(MusicRouteResolver.provisionalRoute(for: .artist(artist)) == .entity(id(.person, artist.uid)))
        #expect(MusicRouteResolver.provisionalRoute(for: .blacklist) == nil)
        #expect(MusicRouteResolver.provisionalRoute(for: .localPlaylist(UUID())) == nil)
        let node = MusicRoute.film(id(.film, "f"))
        #expect(MusicRouteResolver.provisionalRoute(for: node) == node)
    }

    @Test func knownRouteUsesTheGraphOnlyWhenItKnowsTheItem() async throws {
        let graph = MusicInMemoryGraph()
        let index = MusicEntityIndex(store: graph)
        #expect(await MusicRouteResolver.knownRoute(for: .album(album), index: index) == nil)
        let minted = try await graph.upsert(MusicEntityDraft(kind: .release, name: "Album", externalIDs: [ExternalID(.provider, album.uid)], provisional: true)).id
        #expect(await MusicRouteResolver.knownRoute(for: .album(album), index: index) == .entity(minted))
        #expect(await MusicRouteResolver.knownRoute(for: .blacklist, index: index) == nil)
    }

    // MARK: links

    private let token = "7K2QXM4V9ZT3B"

    @Test func storedIdLinksParseAndBuild() throws {
        let l = try #require(MusicEntityLink.parse(parts: ["film", token]))
        #expect(l == .entity(MusicEntityID(kind: .film, token: token), role: nil))
        #expect(l.pathComponents == ["film", token])
        #expect(l.route == .film(MusicEntityID(kind: .film, token: token)))
        let p = try #require(MusicEntityLink.parse(parts: ["artist", token], role: "singer"))
        #expect(p == .entity(MusicEntityID(kind: .person, token: token), role: .singer))
        #expect(MusicEntityLink(entityTarget: p.targetID) == p)
    }

    @Test func externalIdLinksResolveToTheGraphOrAProvisionalId() throws {
        let l = try #require(MusicEntityLink.parse(parts: ["film", "ext", "tmdbMovie:39039"]))
        #expect(l == .external(.film, ExternalID(.tmdbMovie, "39039")))
        #expect(l.provisionalID == .provisional(kind: .film, externalID: ExternalID(.tmdbMovie, "39039")))
        #expect(l.route == nil)
        #expect(MusicEntityLink.parse(parts: ["person", "ext", "wikidata:Q2367593"]) == .external(.person, ExternalID(.wikidata, "Q2367593")))
        #expect(MusicEntityLink(externalTarget: l.pathComponents[0], id: "tmdbMovie:39039") == l)
    }

    @Test func linksThatDoNotFitFailClosed() {
        #expect(MusicEntityLink.parse(parts: ["film", "short"]) == nil)
        #expect(MusicEntityLink.parse(parts: ["nonsense", token]) == nil)
        #expect(MusicEntityLink.parse(parts: ["film", token], role: "nonsense") == nil)
        #expect(MusicEntityLink.parse(parts: ["film", "ext", "provider:jiosaavn:1"]) == nil)
        #expect(MusicEntityLink.parse(parts: ["film", "ext", "tmdbMovie:a/b"]) == nil)
        #expect(MusicEntityLink.parse(parts: ["film", "ext", "tmdbMovie:" + String(repeating: "1", count: 80)]) == nil)
        #expect(MusicEntityLink.parse(parts: ["film", "x", "y", "z"]) == nil)
    }

    #if !G4_THROWAWAY
    @Test func appLinksKeepTheOldFormsAndAddTheEntityForms() throws {
        func parse(_ s: String) -> MusicLinkTarget? { URL(string: s).flatMap(MusicDeepLinks.parse) }
        #expect(parse("streamsetu://music/album/jiosaavn/abc123") == MusicLinkTarget(kind: .album, providerID: "jiosaavn", id: "abc123"))
        #expect(parse("streamsetu://music/open/explore")?.kind == .section)
        let t = try #require(parse("streamsetu://music/film/\(token)"))
        #expect(t.kind == .entity)
        #expect(MusicDeepLinks.link(t)?.absoluteString == "streamsetu://music/film/\(token)")
        let x = try #require(parse("streamsetu://music/film/ext/tmdbMovie:39039"))
        #expect(x.kind == .external)
        #expect(MusicDeepLinks.link(x)?.absoluteString == "streamsetu://music/film/ext/tmdbMovie:39039")
        let r = try #require(parse("streamsetu://music/person/\(token)?role=composer"))
        #expect(MusicDeepLinks.link(route: .person(MusicEntityID(kind: .person, token: token), role: .composer))?.absoluteString == "streamsetu://music/person/\(token)?role=composer")
        #expect(MusicEntityLink(entityTarget: r.id)?.role == .composer)
        #expect(parse("streamsetu://music/entity/a/b") == nil)
        #expect(parse("streamsetu://music/film/short") == nil)
    }
    #endif
}
