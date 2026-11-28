import Foundation
import Testing
@testable import REDDY

/// A small connected universe: Awaara (1951) with its soundtrack, two songs, its music director, singer, lyricist, cast and a playlist; a second film by
/// the same music director; a "Various Artists" credit that must never become a link; and an isolated song with no links at all.
struct FillFixture {
    let g = MusicInMemoryGraph()
    var film = MusicEntityID(kind: .film, token: "0000000000000"), ost = MusicEntityID(kind: .album, token: "0000000000000")
    var song1 = MusicEntityID(kind: .recording, token: "0000000000000"), song2 = MusicEntityID(kind: .recording, token: "0000000000000")
    var sj = MusicEntityID(kind: .person, token: "0000000000000"), mukesh = MusicEntityID(kind: .person, token: "0000000000000")
    var shailendra = MusicEntityID(kind: .person, token: "0000000000000"), raj = MusicEntityID(kind: .person, token: "0000000000000")
    var nargis = MusicEntityID(kind: .person, token: "0000000000000"), various = MusicEntityID(kind: .person, token: "0000000000000")
    var playlist = MusicEntityID(kind: .playlist, token: "0000000000000"), film2 = MusicEntityID(kind: .film, token: "0000000000000")
    var lone = MusicEntityID(kind: .recording, token: "0000000000000"), plainAlbum = MusicEntityID(kind: .album, token: "0000000000000")

    static let src = MusicProvenance(source: .musicbrainz, license: .cc0, score: 0.95, evidence: [MusicProvenance.statedToken])

    static func make() async throws -> FillFixture {
        var f = FillFixture()
        func up(_ d: MusicEntityDraft) async throws -> MusicEntityID { try await f.g.upsert(d).id }
        f.film = try await up(MusicEntityDraft(kind: .film, name: "Awaara", lang: "hi", year: 1951, imageRef: "https://img/awaara.jpg", externalIDs: [ExternalID(.provider, "t:film1")]))
        f.film2 = try await up(MusicEntityDraft(kind: .film, name: "Shree 420", lang: "hi", year: 1955, externalIDs: [ExternalID(.provider, "t:film2")]))
        f.ost = try await up(MusicEntityDraft(kind: .album, name: "Awaara (Original Motion Picture Soundtrack)", subkind: "soundtrack", lang: "hi", year: 1951, externalIDs: [ExternalID(.provider, "t:ost")]))
        f.plainAlbum = try await up(MusicEntityDraft(kind: .album, name: "Golden Hits", subkind: "compilation", externalIDs: [ExternalID(.provider, "t:plain")]))
        f.song1 = try await up(MusicEntityDraft(kind: .recording, name: "Awaara Hoon", lang: "hi", year: 1951, externalIDs: [ExternalID(.provider, "t:s1")]))
        f.song2 = try await up(MusicEntityDraft(kind: .recording, name: "Ghar Aaya Mera Pardesi", lang: "hi", year: 1951, externalIDs: [ExternalID(.provider, "t:s2")]))
        f.lone = try await up(MusicEntityDraft(kind: .recording, name: "Lonely Song", externalIDs: [ExternalID(.provider, "t:lone")]))
        f.sj = try await up(MusicEntityDraft(kind: .person, name: "Shankar-Jaikishan", imageRef: "https://img/sj.jpg", externalIDs: [ExternalID(.provider, "t:sj")]))
        f.mukesh = try await up(MusicEntityDraft(kind: .person, name: "Mukesh", externalIDs: [ExternalID(.provider, "t:mukesh")]))
        f.shailendra = try await up(MusicEntityDraft(kind: .person, name: "Shailendra", externalIDs: [ExternalID(.provider, "t:shailendra")]))
        f.raj = try await up(MusicEntityDraft(kind: .person, name: "Raj Kapoor", externalIDs: [ExternalID(.provider, "t:raj")]))
        f.nargis = try await up(MusicEntityDraft(kind: .person, name: "Nargis", externalIDs: [ExternalID(.provider, "t:nargis")]))
        f.various = try await up(MusicEntityDraft(kind: .person, name: "Various Artists", externalIDs: [ExternalID(.provider, "t:va")]))
        f.playlist = try await up(MusicEntityDraft(kind: .playlist, name: "Golden Era", externalIDs: [ExternalID(.provider, "t:pl")]))
        func edge(_ s: MusicEntityID, _ p: MusicPredicate, _ o: MusicEntityID, _ role: MusicRole? = nil, order: Int? = nil) async throws {
            let e = role.map { MusicEdge(subject: s, predicate: p, object: o, role: $0, order: order) } ?? MusicEdge(subject: s, predicate: p, object: o, order: order)
            _ = try await f.g.addEdge(e, provenance: Self.src)
        }
        try await edge(f.song1, .trackOn, f.ost); try await edge(f.song2, .trackOn, f.ost)
        try await edge(f.ost, .soundtrackOf, f.film)
        try await edge(f.song1, .featuredIn, f.film); try await edge(f.song2, .featuredIn, f.film)
        for s in [f.song1, f.song2] {
            try await edge(s, .composedBy, f.sj, .musicDirector); try await edge(s, .performedBy, f.mukesh, .singer); try await edge(s, .writtenBy, f.shailendra, .lyricist)
        }
        try await edge(f.ost, .performedBy, f.various)
        try await edge(f.song1, .performedBy, f.various)
        try await edge(f.film, .musicDirectedBy, f.sj, .musicDirector)
        try await edge(f.film, .hasCast, f.raj, .actor, order: 0); try await edge(f.film, .hasCast, f.nargis, .actor, order: 1)
        try await edge(f.film2, .musicDirectedBy, f.sj, .musicDirector); try await edge(f.film2, .hasCast, f.raj, .actor, order: 0)
        try await edge(f.playlist, .playlistContains, f.song1); try await edge(f.playlist, .playlistContains, f.song2)
        try await edge(f.song2, .trackOn, f.plainAlbum)
        return f
    }

    func ids() -> [(String, MusicEntityID)] {
        [("song", song1), ("soundtrack", ost), ("film", film), ("musicDirector", sj), ("singer", mukesh), ("lyricist", shailendra), ("actor", raj), ("playlist", playlist)]
    }
}
