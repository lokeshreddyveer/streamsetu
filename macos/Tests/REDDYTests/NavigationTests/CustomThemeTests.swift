import Testing
import Foundation
@testable import REDDY

@Suite struct CustomThemeTests {
    @Test func roundTripsThroughItsStoredForm() {
        var t = CustomTheme(); t.background = 0x102030; t.accent = 0xFF8800; t.text = 0xEEEEEE; t.gloss = 0.6
        #expect(CustomTheme(encoded: t.encoded) == t)
    }

    @Test func rejectsMalformedStoredValues() {
        for bad in ["", "nope", "112233,445566,778899", "GGGGGG,000000,FFFFFF,0.2", "0B0D12,2BB8F0,F5F6F8,x", "123,456,789,0.1"] { #expect(CustomTheme(encoded: bad) == nil) }
        #expect(CustomTheme(encoded: "000000,FFFFFF,FFFFFF,7")?.gloss == 1)    // out of range is clamped, not refused
    }

    @Test func contrastFollowsTheStandardFormula() {
        #expect(abs(CustomTheme.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(CustomTheme.contrast(0x777777, 0x777777) - 1) < 0.001)
    }

    @Test func readabilityWarningTriggersOnLowContrast() {
        var t = CustomTheme()
        #expect(t.isReadable)
        t.text = 0x202830
        #expect(!t.isReadable)
    }

    @Test func derivedPaletteKeepsKeyColoursAndStaysInRange() {
        var t = CustomTheme(); t.gloss = 1
        let p = t.palette
        #expect(p.background == t.background && p.accent == t.accent && p.text == t.text)
        #expect(p.sheen <= 0.31 && p.highlight <= 0.5)
        #expect(CustomTheme.mix(0xFFFFFF, 0x000000, 0.5) == 0x808080)
    }

    @MainActor @Test func theCustomThemeIsUsedWhenSelected() {
        let saved = ThemeStore.custom
        defer { ThemeStore.custom = saved }
        var t = CustomTheme(); t.background = 0x123456
        ThemeStore.custom = t
        #expect(AppTheme.custom.palette.background == 0x123456)
        #expect(AppTheme.allCases.contains { $0.group == .yours })
    }
}
