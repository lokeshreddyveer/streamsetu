import Testing
import Foundation
@testable import REDDY

@Suite("The country picker's list") struct MusicCountryListTests {
    @Test func theKeyboardRowStopsAtBothEnds() {
        #expect(MusicCountryList.moved(0, by: -1, count: 5) == 0)
        #expect(MusicCountryList.moved(4, by: 1, count: 5) == 4)
        #expect(MusicCountryList.moved(2, by: 1, count: 5) == 3 && MusicCountryList.moved(2, by: -1, count: 5) == 1)
        #expect(MusicCountryList.moved(3, by: 1, count: 0) == 0, "an empty list has no row to move to")
    }
    @Test func thePickerDrawsNoFlags() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicCountryPicker.swift"), encoding: .utf8)
        #expect(!src.contains("flag(") && !src.contains("1F1E6"), "a country is shown by its name, with no flag")
    }
    @Test func theChosenCountryComesFirstWhenNothingIsTyped() {
        for c in MusicDiscoveryRegion.supported {
            let list = MusicCountryList.filtered(MusicDiscoveryRegion.supported, query: "", chosen: c.code)
            #expect(list.first?.code == c.code && list.count == MusicDiscoveryRegion.supported.count, "\(c.code)")
        }
    }
    @Test func typingTheStartOfAnyNameOrWordFindsIt() {
        for c in MusicDiscoveryRegion.supported {
            let words = MusicText.normalize(c.name).split(separator: " ").map(String.init)
            for w in words where w.count >= 3 {
                let found = MusicCountryList.filtered(MusicDiscoveryRegion.supported, query: String(w.prefix(3)), chosen: "").contains { $0.code == c.code }
                #expect(found, "“\(w.prefix(3))” should find \(c.name)")
            }
            #expect(MusicCountryList.filtered(MusicDiscoveryRegion.supported, query: c.code, chosen: "").contains { $0.code == c.code })
        }
        #expect(MusicCountryList.filtered(MusicDiscoveryRegion.supported, query: "zzzz", chosen: "").isEmpty)
    }
}

@Suite("Country dropdown groups") struct MusicCountryGroupsTests {
    private let all: [MusicCountryList.Country] = [("us", "United States"), ("jp", "Japan"), ("in", "India"), ("fr", "France"), ("ng", "Nigeria"), ("au", "Australia")]
    private let world: MusicCountryList.Country = ("", "Worldwide")

    @Test func withNothingTypedItIsWorldwideThenYourRegionThenRecentThenLetters() {
        let g = MusicCountryList.groups(all: all, query: "", chosen: "", recents: ["jp", "ng", "in"], system: "in", worldwide: world)
        #expect(g.map(\.title) == ["", "Your region", "Recent", "A", "F", "I", "J", "N", "U"])
        #expect(g[0].items.map(\.code) == [""] && g[1].items.map(\.code) == ["in"])
        #expect(g[2].items.map(\.code) == ["jp", "ng"], "your region is not repeated under Recent")
        #expect(MusicCountryList.flat(g).count == 1 + 1 + 2 + all.count, "every country is listed once under its letter, shortcuts are extra rows")
    }
    @Test func aSearchIsOneFlatListAndWorldwideMatchesItsName() {
        let g = MusicCountryList.groups(all: all, query: "ja", chosen: "", recents: [], system: "in", worldwide: world)
        #expect(g.count == 1 && g[0].items.map(\.code) == ["jp"])
        #expect(MusicCountryList.groups(all: all, query: "world", chosen: "", recents: [], system: "in", worldwide: world)[0].items.first?.code == "")
        #expect(MusicCountryList.groups(all: all, query: "zzzz", chosen: "", recents: [], system: "in", worldwide: world).isEmpty)
    }
}

@Suite("Country dropdown keeps the keyboard") struct CountryPickerFocusTests {
    @Test func theSearchBoxTakesFocusAndChoosingGivesItUpWithoutPassingItOn() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicCountryPicker.swift"), encoding: .utf8)
        #expect(src.contains(".defaultFocus($searching, true)"), "the search box must hold the keyboard as soon as the popover opens, or typing reaches the app")
        let guardSrc = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicFocusGuard.swift"), encoding: .utf8)
        #expect(src.contains("MusicFocusGuard.releaseToPage()") && guardSrc.contains("makeFirstResponder(nil)"), "after a choice the focus must not move on to the app's Search box")
    }
}
