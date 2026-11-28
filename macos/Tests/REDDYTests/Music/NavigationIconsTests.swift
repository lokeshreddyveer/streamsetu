import Testing
import SwiftUI
@testable import REDDY

@Suite struct NavigationIconsTests {
    private let unit = CGRect(x: 0, y: 0, width: MusicIconGrid.units, height: MusicIconGrid.units)

    @Test func everySectionAndTabHasAGlyph() {
        for s in MusicSection.allCases { #expect(MusicNavGlyph.allCases.contains(s.navGlyph)) }
        for t in MusicContextPanelTab.allCases { #expect(MusicNavGlyph.allCases.contains(t.navGlyph)) }
        #expect(Set(MusicSection.allCases.map(\.navGlyph)).count == MusicSection.allCases.count)
        #expect(Set(MusicContextPanelTab.allCases.map(\.navGlyph)).count == MusicContextPanelTab.allCases.count)
    }

    @Test func outlineAndFilledVariantsExist() {
        for g in MusicNavGlyph.allCases {
            let full = MusicNavGlyphShape(glyph: g).path(in: unit)
            #expect(!full.isEmpty)
            if g != .close {
                #expect(!MusicNavGlyphShape(glyph: g, part: .body).path(in: unit).isEmpty, "\(g) has a body to fill")
            }
        }
    }

    @Test func allGlyphsShareTheSameBox() {
        for g in MusicNavGlyph.allCases {
            let b = MusicNavGlyphShape(glyph: g).path(in: unit).boundingRect
            #expect(b.minX >= 2 && b.maxX <= 22 && b.minY >= 2 && b.maxY <= 22, "\(g) stays in the live area")
            #expect(max(b.width, b.height) >= 13, "\(g) is not smaller than the rest")
            #expect(b.width <= 18.5, "\(g) is not wider than the rest")
            #expect(abs(b.midX - 12) <= 2 && abs(b.midY - 12) <= 2, "\(g) is centred")
        }
    }

    @Test func fixedBoxAndSelectedWeight() {
        #expect(MusicNavIcon.box == MusicIconSize.row)
        #expect(MusicNavIcon.selectedWeight > 1)
        #expect(MusicNavIcon.selectedFill > 0 && MusicNavIcon.selectedFill < 1)
    }
}
