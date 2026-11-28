import Testing
import Foundation
@testable import REDDY

private func ln(_ t: Int64, _ text: String = "line", end: Int64? = nil) -> MusicLyricLine { MusicLyricLine(timeMs: t, text: text, endMs: end) }

@Suite("Lyrics preview logic") struct LyricsPreviewTests {
    typealias L = MusicLyricsPreviewLogic

    @Test func lineCountIsOddAndBounded() {
        for h in stride(from: CGFloat(100), through: 600, by: 20) {
            let n = L.lineCount(forHeight: h, footer: 36)
            #expect(n >= 5 && n <= 9 && n % 2 == 1)
        }
        #expect(L.lineCount(forHeight: 160, footer: 36) == 5)
        #expect(L.lineCount(forHeight: 1000, footer: 36) == 9)
        #expect(L.lineCount(forHeight: .infinity, footer: 36) == 5)
    }

    @Test func windowAroundActive() {
        #expect(L.window(count: 50, active: 20, size: 7) == 17..<24)
        #expect(L.window(count: 50, active: 0, size: 7) == 0..<4)
        #expect(L.window(count: 50, active: nil, size: 7) == 0..<4)
        #expect(L.window(count: 50, active: 49, size: 7) == 46..<50)
        #expect(L.window(count: 3, active: 1, size: 9) == 0..<3)
        #expect(L.window(count: 0, active: 0, size: 5) == 0..<0)
        #expect(L.window(count: 10, active: 99, size: 5) == 7..<10)
    }

    @Test func cursorFollowsTime() {
        let lines = [ln(1000, end: 4000), ln(5000, end: 8000), ln(9000)]
        #expect(L.cursor(lines: lines, ms: 0) == .init(index: nil, gap: false))
        #expect(L.cursor(lines: lines, ms: 1200) == .init(index: 0, gap: false))
        #expect(L.cursor(lines: lines, ms: 5200) == .init(index: 1, gap: false))
        #expect(L.cursor(lines: lines, ms: 20000) == .init(index: 2, gap: false))
        #expect(L.cursor(lines: [], ms: 100) == .start)
    }

    @Test func gapsAreDetected() {
        let lines = [ln(10_000, end: 12_000), ln(30_000, end: 32_000), ln(60_000)]
        #expect(L.cursor(lines: lines, ms: 0).gap)                    // long intro
        #expect(!L.cursor(lines: lines, ms: 7_000).gap)              // intro about to end
        #expect(!L.cursor(lines: lines, ms: 13_000).gap)             // just after the line
        #expect(L.cursor(lines: lines, ms: 20_000) == .init(index: 0, gap: true))
        #expect(!L.cursor(lines: lines, ms: 29_000).gap)             // next line is close
        let blank = [ln(1000, "sung"), ln(5000, "  "), ln(9000, "next")]
        #expect(L.cursor(lines: blank, ms: 6000) == .init(index: 1, gap: true))
    }

    @Test func anchorAndLevels() {
        let c = L.Cursor(index: 3, gap: false)
        #expect(c.anchor(count: 10) == 3)
        #expect(L.level(row: 3, cursor: c, count: 10) == 0)
        #expect(L.level(row: 5, cursor: c, count: 10) == 2)
        let gap = L.Cursor(index: 3, gap: true)
        #expect(gap.anchor(count: 10) == 4)
        #expect(gap.anchor(count: 4) == 3)
        #expect(L.level(row: 4, cursor: gap, count: 10) == 1)
        #expect(L.Cursor.start.anchor(count: 5) == 0)
    }

    @Test func opacityFadesAndHidesOutside() {
        #expect(L.opacity(level: 0, half: 3, increaseContrast: false) == 1)
        #expect(L.opacity(level: 1, half: 3, increaseContrast: false) > L.opacity(level: 3, half: 3, increaseContrast: false))
        #expect(L.opacity(level: 4, half: 3, increaseContrast: false) == 0)
        #expect(L.opacity(level: 3, half: 3, increaseContrast: true) > L.opacity(level: 3, half: 3, increaseContrast: false))
        #expect(L.opacity(level: 1, half: 4, increaseContrast: true) <= 1)
    }

    @Test func modeFollowsServiceStates() {
        let synced = MusicLyrics(synced: [ln(0)], sourceName: "S")
        #expect(L.mode(for: .idle, timedOut: false) == .loading)
        #expect(L.mode(for: .loading, timedOut: false) == .loading)
        #expect(L.mode(for: .loading, timedOut: true) == .miss(.offline))
        #expect(L.mode(for: .idle, timedOut: true) == .miss(.offline))
        #expect(L.mode(for: .found(synced), timedOut: true) == .synced)
        #expect(L.mode(for: .found(MusicLyrics(plain: "a\nb")), timedOut: false) == .plain)
        #expect(L.mode(for: .found(MusicLyrics(instrumental: true)), timedOut: false) == .instrumental)
        #expect(L.mode(for: .found(MusicLyrics(plain: "[Verse]\n\n")), timedOut: false) == .miss(.notFound))
        #expect(L.mode(for: .none(.mix), timedOut: false) == .miss(.mix))
        #expect(L.mode(for: .none(.notFound), timedOut: false) == .miss(.notFound))
        #expect(L.mode(for: .none(.offline), timedOut: false) == .miss(.offline))
    }

    @Test func plainLinesSkipLabelsAndBlanks() {
        #expect(L.plainLines("[Verse 1]\nfirst\n\nsecond\nthird", limit: 2) == ["first", "second"])
        #expect(L.plainLines("", limit: 5).isEmpty)
    }

    @Test func visibilityByHeight() {
        // 159 pt left: hidden; 160 pt: shown.
        #expect(L.previewHeight(panelHeight: 700, detailsHeight: 700 - 32 - 12 - 159, verticalPadding: 16, gap: 12) == nil)
        #expect(L.previewHeight(panelHeight: 700, detailsHeight: 700 - 32 - 12 - 160, verticalPadding: 16, gap: 12) == 160)
        #expect(L.previewHeight(panelHeight: 700, detailsHeight: 0, verticalPadding: 16, gap: 12) == nil)
        #expect(L.isVisible(availableHeight: 200, lyricsTabShowing: false))
        #expect(!L.isVisible(availableHeight: 200, lyricsTabShowing: true))
        #expect(!L.isVisible(availableHeight: nil, lyricsTabShowing: false))
        #expect(!L.isVisible(availableHeight: 159, lyricsTabShowing: false))
    }

    @Test func subTextOnlyWhenPresent() {
        #expect(L.subText(nil, index: 0, original: "a") == nil)
        let sub = MusicLyricsSubLines(kind: .translation, target: "en", source: "te", lines: [MusicLyricSubLine(text: "hello"), nil])
        #expect(L.subText(sub, index: 0, original: "namaste") == "hello")
        #expect(L.subText(sub, index: 1, original: "x") == nil)
        #expect(L.subText(sub, index: 9, original: "x") == nil)
    }
}
