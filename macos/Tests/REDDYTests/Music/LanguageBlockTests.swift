import Testing
import Foundation
@testable import REDDY

private func track(_ title: String, artist: String = "Artist", album: String? = nil, id: String? = nil) -> MusicTrack {
    MusicTrack(id: id ?? title, providerID: "ytmusic", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: artist, name: artist)],
               album: album.map { MusicAlbumRef(id: $0, title: $0) })
}
private func album(_ title: String, artist: String = "Artist", year: String? = nil) -> MusicAlbum {
    MusicAlbum(id: title, providerID: "ytmusic", title: title, artists: [MusicArtistRef(id: artist, name: artist)], releaseDate: year)
}
private func playlist(_ name: String) -> MusicPlaylist { MusicPlaylist(id: name, providerID: "ytmusic", name: name) }

@Suite("Language block under a Home chip") @MainActor struct LanguageBlockTests {





    @Test func cacheKeyIsPerRegionAndLanguage() {
        func key(_ r: String, _ l: MusicLanguage?) -> MusicHomeKey { MusicHomeKey(region: r, language: l, source: "ytmusic", discovery: [], wanted: []) }
        #expect(key("in", .telugu).name != key("in", .hindi).name)
        #expect(key("in", .telugu).name != key("us", .telugu).name)
        #expect(key("IN", .telugu) == key("in", .telugu))
        #expect(key("in", .telugu).fileName != key("in", nil).fileName)
    }

    @Test func oldCacheFilesWithoutTheLanguageBlockStillLoad() throws {
        var snap = MusicHomeSnapshot(key: "k", savedAt: Date())
        snap.languageBlock = nil
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(MusicHomeSnapshot.self, from: data).languageBlock == nil)
    }


    @Test func addLanguageListsNativeNames() {
        #expect(MusicLanguage.telugu.nativeName == "తెలుగు" && MusicLanguage.hindi.nativeName == "हिन्दी" && MusicLanguage.tamil.nativeName == "தமிழ்")
        #expect(MusicLanguage.pickable.contains(.marathi) && MusicLanguage.pickable.contains(.gujarati) && MusicLanguage.pickable.contains(.spanish))
        #expect(MusicLanguage.telugu.menuName.hasPrefix("తెలుగు"))
        #expect(!MusicLanguage.pickable.contains(.latin))
        #expect(MusicLanguageDetector.language(of: "ગુજરાતી ગીત") == .gujarati)
    }
}
