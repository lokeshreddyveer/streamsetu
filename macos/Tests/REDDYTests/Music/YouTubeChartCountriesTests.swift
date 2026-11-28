import Foundation
import Testing
@testable import REDDY

@Suite("YouTube Music charts: only countries it really charts") struct YouTubeChartCountriesTests {
    private func option(_ code: String) -> [String: Any] {
        let raw = Data("\u{12}'explore_charts_country_menu_316766567\(code) \u{91}\u{1}(\u{1}".utf8)
        let b64 = raw.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return ["musicMultiSelectMenuItemRenderer": ["formItemEntityKey": b64]]
    }

    @Test func theCountryMenuOfThePageIsTheListOfCountriesItHasChartsFor() {
        let root: [String: Any] = ["options": ["ZZ", "US", "IN", "KR", "BR"].map(option)]
        #expect(YTMHomeParser.chartCountries(root) == ["US", "IN", "KR", "BR"])        // Global is not a country
        #expect(YTMHomeParser.chartCountries(["nothing": 1]).isEmpty)
        #expect(!YTMHomeParser.chartCountries(root).contains("AL"))                        // a country that is not in the menu gets no chart
    }
}
