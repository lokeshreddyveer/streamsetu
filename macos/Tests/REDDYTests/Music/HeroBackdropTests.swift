import Testing
import Foundation
@testable import REDDY

@Suite("Hero: backdrop and words") struct HeroBackdropTests {
    @Test func theDarkeningIsSizedToTheCoverNotToPureWhite() {
        #expect(MusicHeroBackdrop.opacity(brightest: 0.2) == 1)                                   // a dark cover shows all its colour
        #expect(MusicHeroBackdrop.opacity(brightest: 0.9) < 0.6)                                  // a bright one is held down
        for b in stride(from: 0.05, through: 1.0, by: 0.05) {
            #expect(b * MusicHeroBackdrop.opacity(brightest: b) <= MusicHeroBackdrop.maxBrightness + 1e-9, "brightest \(b)")
        }
        #expect(MusicHeroBackdrop.opacity(brightest: 0) == 1)
    }

    @Test func theWashBecomesAPictureOnlyWhenTheBytesFitTheSide() {
        let ok = [UInt8](repeating: 128, count: 4 * 4 * 4)
        #expect(MusicHeroBackdrop.cgImage(rgba: ok, side: 4) != nil)
        #expect(MusicHeroBackdrop.cgImage(rgba: ok, side: 5) == nil && MusicHeroBackdrop.cgImage(rgba: [], side: 0) == nil)
    }

    @Test func placeholderArtistsNeverReachTheHero() {
        func a(_ n: String) -> MusicArtistRef { MusicArtistRef(id: "", name: n) }
        #expect(MusicHeroText.credit([a("Unknown artist")]) == "")
        #expect(MusicHeroText.credit([a("Various Artists"), a("Someone"), a(" unknown ")]) == "Someone")
        #expect(MusicHeroText.credit([a("A"), a("B")]) == "A, B")
    }

    @Test func theMetaLineSaysOnlyWhatTheSourceKnows() {
        var al = MusicAlbum(id: "1", providerID: "x", title: "T")
        #expect(MusicHeroText.meta(for: al) == "Album")
        al.releaseDate = "2026-03-01"; al.totalTracks = 9
        #expect(MusicHeroText.meta(for: al) == "Album · 2026 · 9 songs")
        al.albumType = "Single"; al.totalTracks = 1
        #expect(MusicHeroText.meta(for: al) == "Single · 2026 · 1 song")
        al.releaseDate = "soon"; al.totalTracks = nil
        #expect(MusicHeroText.meta(for: al) == "Single")
    }

    @Test func everyRealChartAlbumGetsAHeroLineWithoutPlaceholders() {
        var n = 0
        for f in RandomRegionsHomeTests.fixtures {
            for r in f.regions {
                for rec in r.albums {
                    guard let id = rec.id, let name = rec.name else { continue }
                    let al = MusicAlbum(id: id, providerID: "itunes-charts", title: name, artists: rec.artist.map { [MusicArtistRef(id: "", name: $0)] } ?? [])
                    let credit = MusicHeroText.credit(al.artists)
                    #expect(!MusicHeroText.isPlaceholder(credit) || credit.isEmpty, "seed \(f.seed), \(r.code): \(id)")
                    #expect(!credit.lowercased().contains("unknown artist"), "seed \(f.seed), \(r.code): \(id)")
                    n += 1
                }
            }
        }
        #expect(n > 50)
    }
}
