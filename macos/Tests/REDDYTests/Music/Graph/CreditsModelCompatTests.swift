import Foundation
import Testing
@testable import REDDY

@Suite("Credits: saved libraries still load") struct CreditsModelCompatTests {
    /// A track as an older build saved it: none of the credit fields exist.
    private let oldTrack = """
    [{"id":"s1","providerID":"jiosaavn","title":"Awara Hoon","durationMs":168000,"artists":[{"id":"456076","name":"Shankar-Jaikishan","thumbnails":[]}],
      "album":{"id":"1064999","title":"Awaara","artists":[],"thumbnails":[]},"thumbnails":[],"explicit":false,"videoID":"v1","isVideo":false}]
    """
    private let oldAlbum = """
    {"id":"1064999","providerID":"jiosaavn","title":"Awaara","artists":[],"thumbnails":[],"releaseDate":"1951","albumType":"Album"}
    """

    @Test func anOldLibrarySnapshotDecodesUnchanged() throws {
        let tracks = try JSONDecoder().decode([MusicTrack].self, from: Data(oldTrack.utf8))
        #expect(tracks.count == 1 && tracks[0].title == "Awara Hoon" && tracks[0].videoID == "v1")
        #expect(tracks[0].credits == nil && tracks[0].hints == nil && tracks[0].creditBundle == nil)
        let album = try JSONDecoder().decode(MusicAlbum.self, from: Data(oldAlbum.utf8))
        #expect(album.credits == nil && album.title == "Awaara")
        // Saved again, an item with no credits writes no credit key at all.
        let again = String(decoding: try JSONEncoder().encode(tracks[0]), as: UTF8.self)
        #expect(!again.contains("creditBundle"))
    }

    @Test func creditsRoundTrip() throws {
        var t = try JSONDecoder().decode([MusicTrack].self, from: Data(oldTrack.utf8))[0]
        t.credits = [MusicCredit(name: "Mukesh", role: .singer, providerArtistID: "9", level: .track, instrument: nil, character: nil),
                     MusicCredit(name: "Nargis", role: .starring, level: .film, character: "Rita")]
        t.hints = MusicProviderHints(film: "Awaara", year: 1951, language: "hindi")
        let back = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(t))
        #expect(back.credits == t.credits && back.hints == t.hints)
        #expect(back.credits?.last?.character == "Rita")
    }

    @Test func aRoleANewerBuildAddedDecodesAsOther() throws {
        let c = try JSONDecoder().decode(MusicCredit.self, from: Data(#"{"name":"X","role":"dj-mixer","level":"track"}"#.utf8))
        #expect(c.role == .other && c.name == "X")
    }

    @Test func twoCopiesCarryingCreditsAreTheSameItemWhateverTheCreditsSay() throws {
        var a = try JSONDecoder().decode([MusicTrack].self, from: Data(oldTrack.utf8))[0]
        var b = a
        a.credits = [MusicCredit(name: "Mukesh", role: .singer)]
        b.credits = [MusicCredit(name: "Someone Else", role: .lyricist)]
        #expect(a == b && Set([a, b]).count == 1, "the credit text never decides whether two copies of an item are the same")
        b.credits = nil
        #expect(b.creditBundle == nil)
    }

    @Test func anOldLocalIndexStillDecodes() throws {
        let json = #"[{"id":"l1","folderID":"f","path":"/m/a.mp3","title":"T","artist":"A","album":"B","durationMs":1000,"modified":0,"ext":"mp3"}]"#
        let entries = try JSONDecoder().decode([LocalEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1 && entries[0].composer == nil && entries[0].work == nil)
    }
}
