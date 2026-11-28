import Testing
import Foundation
@testable import REDDY

@Suite("Radio follows the shared country") struct RadioCountryTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func radioReadsAndSetsTheOneCountryTheOtherScreensUse() throws {
        let radio = try Self.source("Features/Music/MusicRadioView.swift")
        #expect(radio.contains("MusicRegionChoice.shared") && radio.contains("choice.set(code)"), "a country chosen on Radio must show on Listen Now and Explore, and the other way round")
        #expect(radio.contains("MusicCountryPicker(region: region)"), "the same searchable picker as the other screens")
        #expect(!radio.contains("@State private var region"), "no private copy of the country that can disagree with the shared one")
    }

    @Test func aCountryChartStationGetsASecondTryBeforeSayingThereIsNothing() throws {
        let start = try Self.source("Features/Music/MusicRadioStart.swift")
        #expect(start.contains("await twice {"), "the first request for a new country is the slow one")
        #expect(start.contains("MusicHomeLoaders.secondChance"))
    }

    @Test @MainActor func choosingTheSameCountryTwiceChangesNothing() {
        let defaults = UserDefaults(suiteName: "radio-country-test-\(UUID().uuidString)")!
        let c = MusicRegionChoice(defaults: defaults, locale: Locale(identifier: "en_US"))
        #expect(c.set("jp") == true)
        #expect(c.set("jp") == false)
        #expect(c.region == "jp")
        #expect(c.set("zz") == false, "an unsupported country is ignored")
    }
}
