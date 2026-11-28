import Testing
import Foundation
@testable import REDDY

/// "Go to album" and "Go to artist" on a song that catalogue enrichment added to an album page. The added song is the playable copy of a catalogue row,
/// so it must never carry the catalogue source's album or artist id (nor a title or name used as an id): the link would ask the wrong source. A link opens
/// the page of the song's own source with the song's own id, or is not offered.
@MainActor
@Suite("Flow: Go to album and artist from a song added by catalogue enrichment")
struct GoToFromEnrichedSongFlowTests {
    private let catalogue = "jio"
    private let own = "youtube-music"

    private func catalogueRow(_ title: String, albumID: String = "jio-album-77", artistID: String = "jio-artist-9") -> MusicTrack {
        var t = MusicTrack(id: "jio-\(title)", providerID: catalogue, title: title, durationMs: 200_000, artists: [MusicArtistRef(id: artistID, name: "Sivam")])
        t.album = MusicAlbumRef(id: albumID, title: "Pushpa")
        return t
    }

    private func canonical(_ row: MusicTrack, twinProvider: String, twinID: String) -> MusicCanonicalTrack {
        var c = MusicCanonicalTrack(key: "k-\(row.title)", title: row.title, artists: ["Sivam"], album: "Pushpa", durationMs: row.durationMs)
        c.twins = [MusicCanonicalTwin(providerID: twinProvider, sourceID: twinID, title: row.title, score: 0.95)]
        return c
    }

    /// What the album page ends with: the page's own song, plus the catalogue's second song added from its playable twin.
    private func enrichedAlbumSongs(twinProvider: String) -> (album: MusicAlbum, added: MusicTrack) {
        let album = MusicAlbum(id: "yt-album-1", providerID: own, title: "Pushpa")
        var mine = MusicTrack(id: "yt-1", providerID: own, title: "Song One", durationMs: 200_000, artists: [MusicArtistRef(id: "yt-artist-1", name: "Sivam")])
        mine.album = MusicAlbumRef(id: "yt-album-1", title: "Pushpa")
        let c1 = catalogueRow("Song One"), c2 = catalogueRow("Song Two")
        let twin = MusicCatalogMatcher.playableTrack(from: canonical(c2, twinProvider: twinProvider, twinID: "twin-2"), catalogueRow: c2)
        var catAlbum = MusicAlbum(id: "jio-album-77", providerID: catalogue, title: "Pushpa")
        catAlbum.totalTracks = 2
        let merged = MusicAlbumMerge.merge(album: album, tracks: [mine], catalogueAlbum: catAlbum, catalogueTracks: [c1, c2], twins: [c2.uid: twin])
        let added = merged.tracks.first { $0.title == "Song Two" }
        return (merged.album, added ?? twin)
    }

    private func make() throws -> FlowRig { try FlowRig() }

    @Test func aSongFromThePagesOwnSourceOpensThePagesAlbumOnThatSource() throws {
        let rig = try make(); defer { rig.cleanup() }
        let (_, added) = enrichedAlbumSongs(twinProvider: own)
        #expect(added.providerID == own)
        let ref = try #require(added.album)
        #expect(ref.id == "yt-album-1", "the album id of the page's own source, never the catalogue's \(catalogue) id")

        rig.hub.open(.album(MusicLinks.album(ref, providerID: added.providerID)))

        guard case .album(let landed)? = rig.hub.nav.top else { Issue.record("Go to album did not open an album page"); return }
        #expect(landed.providerID == own && landed.id == "yt-album-1")
    }

    @Test func aSongFromAnotherSourceHasNoAlbumLinkInsteadOfAWrongOne() throws {
        let rig = try make(); defer { rig.cleanup() }
        let (_, added) = enrichedAlbumSongs(twinProvider: "soundcloud")
        #expect(added.providerID == "soundcloud")
        let ref = try #require(added.album)
        #expect(ref.id.isEmpty, "an id from another source would send Go to album to the wrong service")
        #expect(ref.id != ref.title && ref.id != "jio-album-77")
        let before = rig.hub.nav.stack.count

        rig.hub.open(.album(MusicLinks.album(ref, providerID: added.providerID)))   // the menus hide the item for an empty id; the hub refuses it too

        #expect(rig.hub.nav.stack.count == before)
    }

    @Test func artistsAreNotGivenTheNameOrAForeignIdAsTheirId() throws {
        let (_, foreign) = enrichedAlbumSongs(twinProvider: "soundcloud")
        #expect(foreign.artists.allSatisfy { $0.id.isEmpty }, "the catalogue's artist id belongs to \(catalogue), the song is on soundcloud")
        #expect(foreign.artists.allSatisfy { $0.id != $0.name })
        let (_, same) = enrichedAlbumSongs(twinProvider: own)
        #expect(same.artists.allSatisfy { $0.id != "jio-artist-9" })
    }

    @Test func aCatalogueRowFromTheSameSourceKeepsItsOwnIdsAndOpensThatArtist() throws {
        let rig = try make(); defer { rig.cleanup() }
        let row = catalogueRow("Song Two")
        let shown = MusicCatalogMatcher.playableTrack(from: canonical(row, twinProvider: catalogue, twinID: "same-2"), catalogueRow: row)
        #expect(shown.providerID == catalogue)
        let artist = try #require(shown.artists.first)
        #expect(artist.id == "jio-artist-9")

        rig.hub.open(.artist(MusicLinks.artist(artist, providerID: shown.providerID)))

        guard case .artist(let landed)? = rig.hub.nav.top else { Issue.record("Go to artist did not open an artist page"); return }
        #expect(landed.providerID == catalogue && landed.id == "jio-artist-9")
    }
}
