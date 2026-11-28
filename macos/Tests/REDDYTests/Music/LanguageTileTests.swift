import Testing
import Foundation
@testable import REDDY

@Suite("Language tiles open real language lists") struct LanguageTileTests {
    static func tiles(historyOrder: [String] = []) -> [MusicCategory] {
        let library = historyOrder.enumerated().map { MusicLibraryFacet(key: $0.element, name: $0.element, count: max(1, historyOrder.count - $0.offset)) }
        return MusicDerivedLanguages.tiles(MusicDerivedLanguages.derive(.init(library: library)), cap: .max)
    }
    @Test func everyTileTheAppModelsKnowsItsLanguage() {
        let tiles = Self.tiles()
        #expect(tiles.count == MusicCategoryCatalogue.languages.count)
        for (tile, entry) in zip(tiles, MusicCategoryCatalogue.languages) {
            let expected = MusicLanguage(stated: entry.key)
            #expect(tile.language == expected, "\(entry.key)")
        }
        #expect(tiles.contains { $0.language != nil })
    }
    @Test func aTileForALanguageTheAppDoesNotModelKeepsTheSearchFallback() {
        for t in Self.tiles() where t.language == nil {
            if case .search(let q) = t.target { #expect(!q.isEmpty) } else { Issue.record("\(t.name) has no way to open") }
        }
    }
}

@Suite("Cards never say Unknown artist") struct CardCreditTests {
    @Test func aSourcesFillerNameIsDroppedButARealCreditStays() {
        let a = [MusicArtistRef(id: "", name: "Unknown artist")]
        #expect(MusicHeroText.cardCredit(a) == "")
        #expect(MusicHeroText.cardCredit([MusicArtistRef(id: "1", name: "Various Artists")]) == "Various Artists")
        #expect(MusicHeroText.cardCredit([MusicArtistRef(id: "", name: "Unknown"), MusicArtistRef(id: "2", name: "Real Name")]) == "Real Name")
        #expect(MusicHeroText.isUnknown("  UNKNOWN Artist ") && !MusicHeroText.isUnknown("Various Artists"))
    }
}

@Suite("No card shows the filler artist") struct CardSubtitleTests {
    @Test func theCardSourcesNeverPrintTheFiller() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for f in ["Sources/REDDY/Features/Music/MusicCards.swift", "Sources/REDDY/Features/Music/MusicExploreView.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            #expect(!src.contains("a.artists.map(\\.name).joined"), "\(f) builds an album subtitle without the filler rule")
            #expect(src.contains("cardCredit"), "\(f) does not use the shared credit rule")
        }
    }
}

@Suite("Looser wording for a query that found nothing") struct QueryRelaxTests {
    @Test func editionNotesAreDroppedAndPlainTitlesAreLeftAlone() {
        #expect(MusicQueryRelax.relaxed("Carnaval De Luz (Deluxe Edition)") == "Carnaval De Luz")
        #expect(MusicQueryRelax.relaxed("PULSE - EP") == "PULSE")
        #expect(MusicQueryRelax.relaxed("Some Title [Remastered 2011]") == "Some Title")
        #expect(MusicQueryRelax.relaxed("Plain Title") == nil)
        #expect(MusicQueryRelax.relaxed("(Deluxe Edition)") == nil, "nothing is left to ask")
    }
    @Test func theRealChartTitlesThatFoundNothingGetALooserWording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/RandomRegions")
        var checked = 0
        for f in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where f.pathExtension == "json" {
            let d = try JSONDecoder().decode(RandomRegionsHomeTests.Fixture.self, from: Data(contentsOf: f))
            for r in d.regions { for rec in r.albums + r.songs {
                guard let n = rec.name, let relaxed = MusicQueryRelax.relaxed(n) else { continue }
                #expect(!relaxed.isEmpty && relaxed.count < n.count, "seed \(d.seed), \(r.code), id \(rec.id ?? "?")")
                checked += 1
            } }
        }
        #expect(checked > 0)
    }
}

@Suite("Downloads read the typed state") struct DownloadStatusTests {
    @Test func everyStateMapsAndAFailureKeepsItsReason() {
        typealias S = MusicDownloadItem.State
        #expect(MusicDownloadStatus.of(S.queued) == .waiting && MusicDownloadStatus.of(S.resolving) == .active && MusicDownloadStatus.of(S.downloading) == .active)
        #expect(MusicDownloadStatus.of(S.paused) == .paused && MusicDownloadStatus.of(S.done) == .done && MusicDownloadStatus.of(S.failed("x")) == .failed)
        #expect(MusicDownloadStatus.reason(S.failed("disk full")) == "disk full" && MusicDownloadStatus.reason(S.failed("")) == nil && MusicDownloadStatus.reason(S.done) == nil)
    }
}

@Suite("Language tile order") struct LanguageTileOrderTests {
    // changed: there is no fixed stock order any more; the languages are the device's own, each once.
    @Test func theStockLanguagesAreTheDevicesOwnAndNeverRepeat() {
        let keys = MusicCategoryCatalogue.languages.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func aPersonsOwnLanguagesStillComeBeforeTheStockOrder() {
        let tiles = LanguageTileTests.tiles(historyOrder: ["tamil"])
        #expect(tiles.first?.language?.rawValue == "tamil")
    }
}
