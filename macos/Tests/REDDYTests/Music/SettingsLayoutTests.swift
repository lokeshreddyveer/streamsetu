import Testing
import Foundation
import SwiftUI
@testable import REDDY

/// The Music settings overlay keeps one row height scale, one alignment rule, one control width, a rail that collapses to icons, and a bottom inset.
@Suite("Music settings layout") struct SettingsLayoutTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/REDDY/Features/Music").appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func rowHeightsAreOneScaleOnTheGrid() {
        let h = MusicSettingsLayout.rowHeights
        #expect(h == h.sorted())
        #expect(h.allSatisfy { $0.truncatingRemainder(dividingBy: MusicSpace.xxs) == 0 })
        #expect(MusicSettingsLayout.compactRowHeight >= MusicHitTarget.macMinimum)
        #expect(MusicSettingsLayout.rowHeight == MusicTokens.settingsRowMinHeight)
        #expect(MusicSettingsLayout.railRowHeight == MusicSettingsLayout.rowHeight)
    }

    @Test func rowsGrowWithTheTextStepAndStayOnTheGrid() {
        #expect(MusicSettingsLayout.rowHeight(forTextScale: 1) == MusicSettingsLayout.rowHeight)
        #expect(MusicSettingsLayout.rowHeight(forTextScale: 0.92) == MusicSettingsLayout.rowHeight)
        for step in MusicTextStep.allCases {
            let h = MusicSettingsLayout.rowHeight(forTextScale: step.scale)
            #expect(h >= MusicSettingsLayout.rowHeight)
            #expect(h.truncatingRemainder(dividingBy: MusicSpace.xxs) == 0)
        }
        #expect(MusicSettingsLayout.rowHeight(forTextScale: MusicTextStep.largest.scale) > MusicSettingsLayout.rowHeight)
    }

    @Test func oneControlWidthServesPickersSlidersAndFields() {
        #expect(MusicSettingsLayout.controlWidth == MusicTokens.settingsRowControlWidth)
        #expect(MusicSettingsLayout.valueWidth < MusicSettingsLayout.controlWidth / 2)
        // A slider keeps a useful track: the control minus its value text and the gap.
        #expect(MusicSettingsLayout.controlWidth - MusicSettingsLayout.valueWidth - MusicSpace.xs >= 100)
        #expect(MusicSettingsLayout.toggleGap >= MusicSpace.xs)
        #expect(MusicSettingsLayout.labelGap >= MusicSettingsLayout.toggleGap)
    }

    @Test func theRailCollapsesToIconsBelowSixHundredPoints() {
        #expect(MusicSettingsLayout.rail(forWidth: 520) == .icons)
        #expect(MusicSettingsLayout.rail(forWidth: 599) == .icons)
        #expect(MusicSettingsLayout.rail(forWidth: 600) == .full)
        #expect(MusicSettingsLayout.rail(forWidth: 780) == .full)
        #expect(MusicSettingsLayout.railWidth(.icons) == MusicLayoutGrid.navCompactWidth)
        #expect(MusicSettingsLayout.railWidth(.full) == MusicTokens.settingsRailWidth)
        #expect(MusicSettingsLayout.railWidth(.icons) < MusicSettingsLayout.railWidth(.full))
    }

    @Test func theColumnFitsEveryOverlayWidthFrom520To900() {
        for total in [520, 640, 760, 900] as [CGFloat] {
            let region = MusicSettingsLayout.regionWidth(total: total)
            let column = MusicSettingsLayout.columnWidth(region: region)
            let margin = MusicSettingsLayout.margin(forRegion: region)
            #expect(column + margin * 2 <= region + 0.5)
            #expect(column <= MusicSettingsLayout.maxWidth)
            #expect(MusicSettingsLayout.fitsOnOneLine(rowWidth: column), "a picker row needs one line at \(Int(total)) pt")
        }
        #expect(MusicSettingsLayout.margin(forRegion: 451) == MusicLayoutGrid.pageMargin(for: .compact))
    }

    @Test func aRowWithALongLabelOrLargeTextStacksItsControl() {
        #expect(!MusicSettingsLayout.fitsOnOneLine(rowWidth: 300))
        #expect(MusicSettingsLayout.fitsOnOneLine(rowWidth: 340))
        #expect(!MusicSettingsLayout.fitsOnOneLine(rowWidth: 340, labelNeed: 200))
    }

    @Test func theLastRowAlwaysClearsTheWindowEdge() {
        #expect(MusicSettingsLayout.bottomInset > MusicSettingsLayout.topInset)
        #expect(MusicSettingsLayout.footerInset() == MusicSettingsLayout.bottomInset)
        #expect(MusicSettingsLayout.footerInset(safeBottom: 60) == 60 + MusicSettingsLayout.topInset)
        // Scrolled to the very end: viewport bottom meets content bottom plus the inset, so nothing sits under the edge.
        let content: CGFloat = 1_000, viewport: CGFloat = 500
        let end = content + MusicSettingsLayout.topInset + MusicSettingsLayout.footerInset() - viewport
        #expect(MusicSettingsLayout.clearanceBelowLastRow(contentHeight: content, viewport: viewport, scrolledTo: end) == 0)
        #expect(MusicSettingsLayout.clearanceBelowLastRow(contentHeight: content, viewport: viewport, scrolledTo: 0) > 0)
    }

    @Test func theOverlayCanBeResizedBetweenItsLimits() {
        #expect(MusicSettingsLayout.minWidth <= MusicSettingsLayout.idealWidth && MusicSettingsLayout.idealWidth <= MusicSettingsLayout.maxWidth)
        #expect(MusicSettingsLayout.minHeight <= MusicSettingsLayout.idealHeight && MusicSettingsLayout.idealHeight <= MusicSettingsLayout.maxHeight)
        #expect(MusicSettingsLayout.minWidth == 520 && MusicSettingsLayout.minHeight == 480)
    }

    @Test func valuesAndUnitsReadTheSameEverywhere() {
        #expect(MusicSettingsFormat.seconds(3.4) == "3 s")
        #expect(MusicSettingsFormat.percent(49.6) == "50%")
    }

    @Test func settingsActionsUseTheMusicButtonSystem() throws {
        for name in ["MusicSettingsPage.swift", "Settings/MusicInstalledSettingsSection.swift", "Settings/MusicSubsonicSettingsSection.swift",
                     "Settings/MusicRolesSettingsSection.swift", "Settings/MusicDataAndPrivacySettings.swift", "MusicExtrasSettingsSection.swift",
                     "MusicAutomixSettingsSection.swift", "Karaoke/MusicKaraokeSection.swift", "Accounts/MusicAccountSettingsSection.swift"] {
            let text = try source(name)
            #expect(!text.contains(".buttonStyle(.bordered") && !text.contains(".buttonStyle(.borderedProminent"), "\(name) still uses a system button style")
        }
        // The plugin Add sheet keeps its default action prominent.
        #expect(try source("Settings/MusicInstalledSettingsSection.swift").contains(".musicButton(.primary).keyboardShortcut(.defaultAction)"))
    }

    @Test func appearanceHasTheTextSizeStepAndTheReduceMotionNote() throws {
        let theme = try source("MusicThemeSettingsSection.swift")
        #expect(theme.contains("MusicTextStep") && theme.contains("\"Text size\"") && theme.contains("\"Reduce motion\""))
        #expect(MusicSettingsSearch.search("text size", in: MusicSettingsSearch.index).contains { $0.tab == .general })
    }

    @Test func theRailShowsSelectionWithABarAndKeyboardFocusOnly() throws {
        let page = try source("MusicSettingsPage.swift")
        #expect(page.contains("MusicRailRowStyle(selected: on)"))
        let layout = try source("Settings/MusicSettingsLayout.swift")
        #expect(layout.contains("showsFocusRing(focused: focused, keyboard: keyboard)") && layout.contains("accentBarWidth"))
    }
}
