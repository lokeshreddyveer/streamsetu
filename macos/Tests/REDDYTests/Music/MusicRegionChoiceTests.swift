import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("One country for the whole of Music") struct MusicRegionChoiceTests {
    private func fresh() -> (MusicRegionChoice, UserDefaults) {
        let d = UserDefaults(suiteName: "region-test-\(UUID().uuidString)")!
        return (MusicRegionChoice(defaults: d, locale: Locale(identifier: "en_US")), d)
    }

    @Test func everyOfferedCountryCanBeChosenAndIsSaved() {
        for c in MusicDiscoveryRegion.supported {
            let (r, d) = fresh()
            _ = r.set(c.code == "us" ? "gb" : "us")          // start away from the target
            _ = r.set(c.code)
            #expect(r.region == c.code && d.string(forKey: MusicDiscoveryRegion.defaultsKey) == c.code, "\(c.code)")
            #expect(MusicRegionChoice(defaults: d, locale: Locale(identifier: "en_US")).region == c.code)
        }
    }
    @Test func aCountryTheChartsDoNotCoverIsIgnored() {
        let (r, d) = fresh()
        let before = r.region
        #expect(!r.set("zz") && !r.set("") && r.region == before && d.string(forKey: MusicDiscoveryRegion.defaultsKey) == nil)
    }
    @Test func choosingTheSameCountryAgainChangesNothing() {
        let (r, _) = fresh()
        #expect(!r.set(r.region))
    }
    @Test func twoScreensReadingTheSameStoreAgree() {
        let (r, _) = fresh()
        let home = r, explore = r
        _ = explore.set("jp")
        #expect(home.region == "jp")
    }
}
