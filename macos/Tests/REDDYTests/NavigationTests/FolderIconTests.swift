import Testing
@testable import REDDY

@Suite("Folder icons") struct FolderIconTests {
    @Test func namesGetFittingSymbols() {
        // each name and the symbols its first matching rule may give (the first one this Mac has is used)
        let cases: [(String, Set<String>)] = [
            ("News", ["newspaper", "newspaper.fill"]), ("UK | Entertainment", ["theatermasks", "tv"]), ("Sports HD", ["sportscourt", "trophy"]), ("Cricket Live", ["figure.cricket", "sportscourt"]),
            ("Kids", ["teddybear.fill", "figure.and.child.holdinghands", "face.smiling"]), ("Documentary", ["globe.europe.africa", "binoculars"]), ("Music", ["music.note", "music.quarternote.3"]),
            ("Radio | Pop", ["dot.radiowaves.left.and.right", "radio"]), ("NETFLIX MOVIES", ["film", "film.stack"]), ("Marvel Movies Collection", ["film", "film.stack"]),
            ("Romantic Movies", ["heart", "heart.fill"]), ("US | Premium", ["crown", "star.fill"]), ("INDIAN (4K)", ["4k.tv", "tv"]), ("Weather", ["cloud.sun", "cloud.sun.fill"]),
            ("Shopping", ["bag", "cart"]), ("Arabic News", ["newspaper", "newspaper.fill"]),
        ]
        for (name, allowed) in cases { #expect(allowed.contains(FolderIcons.symbol(for: name)), "“\(name)” → \(FolderIcons.symbol(for: name))") }
        #expect(FolderIcons.symbol(for: "News") == "newspaper")
        #expect(FolderIcons.symbol(for: "Sports") == "sportscourt")
        #expect(FolderIcons.symbol(for: "Kids") == "teddybear.fill")
    }

    @Test func unknownNamesAndNearMissesGetAPlainFolder() {
        #expect(FolderIcons.symbol(for: "Zxqv 12") == "folder")
        #expect(FolderIcons.symbol(for: "") == "folder")
        #expect(FolderIcons.symbol(for: "Newsroom Plus") == "newspaper", "a word start counts for words longer than three letters")
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
