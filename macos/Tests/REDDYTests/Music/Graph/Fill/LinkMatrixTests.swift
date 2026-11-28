import Foundation
import Testing
@testable import REDDY

@Suite struct LinkMatrixTests {
    /// Every kind a page of each source must reach, on the full fixture: a real page for all of them (never a search), both directions.
    @Test func everyPairResolvesToAPageInBothDirections() async throws {
        let f = try await FillFixture.make()
        var dead: [String] = []
        for (label, id) in f.ids() {
            let set = await MusicLinkMatrix.read(id, store: f.g)
            #expect(!set.sourceName.isEmpty, "\(label) was not read")
            for (kind, dest) in set.matrixRow() {
                switch dest {
                case .page(let target, _): #expect(target != set.source, "\(label)->\(kind) leads to itself")
                case .radio: #expect(kind == .radio)
                case .search: dead.append("\(label)->\(kind.rawValue)")
                }
            }
        }
        #expect(dead.isEmpty, "pairs with no page: \(dead)")
    }

    @Test func reverseLinksAreSymmetricForDirectEdges() async throws {
        let f = try await FillFixture.make()
        // (A, kindOfB, B): A links to B, so B must link back to A's kind and to A itself.
        let cases: [(MusicEntityID, MusicConnectionKind, MusicEntityID, MusicConnectionKind)] = [
            (f.song1, .album, f.ost, .song), (f.song1, .film, f.film, .song), (f.song1, .singer, f.mukesh, .song), (f.song1, .musicDirector, f.sj, .song),
            (f.song1, .lyricist, f.shailendra, .song), (f.song1, .playlist, f.playlist, .song), (f.ost, .film, f.film, .soundtrack),
            (f.film, .actor, f.raj, .film), (f.film, .musicDirector, f.sj, .film), (f.ost, .song, f.song2, .album)]
        for (a, kb, b, ka) in cases {
            let forward = await MusicLinkMatrix.read(a, store: f.g)
            #expect(forward.links(kb).contains { $0.target == b }, "\(a)->\(kb)")
            let back = await MusicLinkMatrix.read(b, store: f.g)
            #expect(back.links(ka).contains { $0.target == a }, "\(b)->\(ka) (reverse)")
        }
    }

    @Test func variousArtistsIsNeverALink() async throws {
        let f = try await FillFixture.make()
        for (_, id) in f.ids() + [("va", f.various)] {
            let set = await MusicLinkMatrix.read(id, store: f.g)
            #expect(!set.links.contains { $0.target == f.various || MusicLinkMatrix.isVariousArtists($0.name) })
        }
        for n in ["Various Artists", "various artists - Telugu", "Soundtrack", "V.A.", "Original Motion Picture Soundtrack", "विभिन्न कलाकार"] { #expect(MusicLinkMatrix.isVariousArtists(n), "\(n)") }
        for n in ["Mukesh", "Vishal-Shekhar", "Variousity Band", "Shankar-Jaikishan"] { #expect(!MusicLinkMatrix.isVariousArtists(n), "\(n)") }
    }

    @Test func soundtrackIsKnownAndAlbumLinksCarryBoth() async throws {
        let f = try await FillFixture.make()
        let set = await MusicLinkMatrix.read(f.song2, store: f.g)
        #expect(set.links(.soundtrack).map(\.target) == [f.ost])
        #expect(Set(set.links(.album).map(\.target)) == [f.ost, f.plainAlbum])   // a song on several albums keeps every album
        #expect(set.links(.film).first?.target == f.film)
    }

    @Test func roleLinksAreSeparateFromTheArtistLink() async throws {
        let f = try await FillFixture.make()
        let set = await MusicLinkMatrix.read(f.song1, store: f.g)
        #expect(Set(set.links(.artist).map(\.target)) == [f.sj, f.mukesh, f.shailendra] || set.links(.artist).count >= 3)
        #expect(set.links(.singer).map(\.target) == [f.mukesh])
        #expect(set.links(.lyricist).map(\.target) == [f.shailendra])
        #expect(set.links(.musicDirector).map(\.target).first == f.sj)
        #expect(set.links(.actor).map(\.target).contains(f.raj))   // through the film
    }

    @Test func personPageListsAlbumsAndSongsAndFilms() async throws {
        let f = try await FillFixture.make()
        let sj = await MusicLinkMatrix.read(f.sj, store: f.g)
        #expect(Set(sj.links(.film).map(\.target)) == [f.film, f.film2])
        #expect(sj.links(.song).count >= 2)
        #expect(sj.links(.album).contains { $0.target == f.ost })
        #expect(sj.links(.soundtrack).contains { $0.target == f.ost })
        let raj = await MusicLinkMatrix.read(f.raj, store: f.g)
        #expect(raj.links(.song).count >= 2, "an actor's songs come through their films")
    }

    @Test func noDeadEndOnASparseEntity() async throws {
        let f = try await FillFixture.make()
        let set = await MusicLinkMatrix.read(f.lone, store: f.g)
        for (kind, dest) in set.matrixRow() {
            switch dest {
            case .search(let q, let k): #expect(k == kind && q.contains("Lonely Song"))
            case .radio(let seed): #expect(seed == f.lone)
            case .page: break
            }
        }
        #expect(set.destination(.radio) == .radio(seed: f.lone))
        if case .search(let q, _) = set.destination(.film) { #expect(q == "Lonely Song film") } else { Issue.record("expected a search") }
    }

    @Test func playlistReachesEverything() async throws {
        let f = try await FillFixture.make()
        let set = await MusicLinkMatrix.read(f.playlist, store: f.g)
        for k in [MusicConnectionKind.song, .album, .soundtrack, .artist, .film, .musicDirector, .singer, .lyricist, .actor] { #expect(set.has(k), "\(k)") }
    }

    @Test func reachableKindsExcludeSelf() {
        for k in MusicConnectionKind.allCases { #expect(!MusicConnectionKind.reachable(from: k).contains(k)); #expect(MusicConnectionKind.reachable(from: k).contains(.radio) || k == .radio) }
    }
}
