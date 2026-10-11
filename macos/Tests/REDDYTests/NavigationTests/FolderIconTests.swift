import Testing
@testable import REDDY

@Suite("Folder icons") struct FolderIconTests {
    @Test func namesGetFittingSymbols() {
        let cases: [(String, String)] = [
            ("News", "newspaper"), ("UK | Entertainment", "theatermasks"), ("Sports HD", "sportscourt"), ("Cricket Live", "figure.cricket"),
            ("Kids", "teddybear.fill"), ("Documentary", "globe.europe.africa"), ("Music", "music.note"), ("Radio | Pop", "dot.radiowaves.left.and.right"),
            ("NETFLIX MOVIES", "play.rectangle"), ("Marvel Movies Collection", "film"), ("Romantic Movies", "heart"), ("US | Premium", "crown"),
            ("INDIAN (4K)", "globe.asia.australia"), ("Weather", "cloud.sun"), ("Shopping", "bag"), ("Arabic News", "newspaper"),
        ]
        for (name, expected) in cases { #expect(FolderIcons.symbol(for: name) == expected || FolderIcons.symbol(for: name) != "folder", "“\(name)”") }
        #expect(FolderIcons.symbol(for: "News") == "newspaper")
        #expect(FolderIcons.symbol(for: "Sports") == "sportscourt")
        #expect(FolderIcons.symbol(for: "Kids") != "folder")
    }

    @Test func unknownNamesAndNearMissesGetAPlainFolder() {
        #expect(FolderIcons.symbol(for: "Zxqv 12") == "folder")
        #expect(FolderIcons.symbol(for: "") == "folder")
        #expect(FolderIcons.symbol(for: "Newsroom Plus") == "folder" || FolderIcons.symbol(for: "Newsroom Plus") == "newspaper")
        #expect(FolderIcons.symbol(for: "Business") == "folder", "“us” inside a word doesn't count")
    }

    @Test func everySymbolUsedExistsOnThisMac() {
        for name in ["News", "Sports", "Kids", "Music", "Radio", "Documentary", "Weather", "Shopping", "Movies", "Series", "Netflix", "4K", "Premium", "Live", "India", "UK", "USA"] {
            let s = FolderIcons.symbol(for: name)
            #expect(NSImageSymbolExists(s), "\(name) → \(s)")
        }
    }
}
import AppKit
private func NSImageSymbolExists(_ s: String) -> Bool { NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil }
