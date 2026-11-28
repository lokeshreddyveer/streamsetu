import Testing
import SwiftUI
@testable import REDDY

@Suite("Music components: icons, skeletons, shelf paging") struct MusicComponentsTests {
    // MARK: icon morph and grid

    @Test func playPauseMorphEndpoints() {
        #expect(MusicPlayPauseMorph.points(progress: 0) == MusicPlayPauseMorph.play)
        #expect(MusicPlayPauseMorph.points(progress: 1) == MusicPlayPauseMorph.pause)
        #expect(MusicPlayPauseMorph.points(progress: -3) == MusicPlayPauseMorph.play)
        #expect(MusicPlayPauseMorph.points(progress: 9) == MusicPlayPauseMorph.pause)
        #expect(MusicPlayPauseMorph.points(progress: .nan) == MusicPlayPauseMorph.play)
    }

    @Test func playPauseMorphMidpointIsAverage() {
        let mid = MusicPlayPauseMorph.points(progress: 0.5)
        for (piece, (a, b)) in zip(mid, zip(MusicPlayPauseMorph.play, MusicPlayPauseMorph.pause)) {
            for (pt, (pa, pb)) in zip(piece, zip(a, b)) {
                #expect(abs(pt.x - (pa.x + pb.x) / 2) < 0.0001)
                #expect(abs(pt.y - (pa.y + pb.y) / 2) < 0.0001)
            }
        }
    }

    @Test func playPauseShapeAnimatesProgress() {
        var shape = MusicPlayPauseShape(progress: 0)
        shape.animatableData = 0.25
        #expect(shape.progress == 0.25)
    }

    @Test func strokeWidthIsOpticalAndBounded() {
        #expect(MusicIconGrid.strokeWidth(size: 0) == 0)
        #expect(MusicIconGrid.strokeWidth(size: 12) >= 1.25)
        #expect(abs(MusicIconGrid.strokeWidth(size: 24) - 1.75) < 0.0001)
        #expect(abs(MusicIconGrid.strokeWidth(size: 48) - 3) < 0.0001)
        // Relative weight falls as the glyph grows.
        #expect(MusicIconGrid.strokeWidth(size: 14) / 14 > MusicIconGrid.strokeWidth(size: 24) / 24)
        #expect(MusicIconGrid.strokeWidth(size: 24) / 24 > MusicIconGrid.strokeWidth(size: 48) / 48)
        #expect(MusicIconGrid.defaultSize == MusicIconSize.control)
    }

    @Test func everyGlyphDrawsInsideTheGrid() {
        let rect = CGRect(x: 0, y: 0, width: MusicIconGrid.units, height: MusicIconGrid.units)
        for glyph in MusicGlyph.allCases {
            let b = MusicGlyphShape(glyph: glyph).path(in: rect).boundingRect
            #expect(!b.isNull && b.width > 0 && b.height > 0, "\(glyph)")
            #expect(b.minX >= 0 && b.minY >= 0 && b.maxX <= MusicIconGrid.units && b.maxY <= MusicIconGrid.units, "\(glyph) \(b)")
        }
    }

    @Test func equalizerBarsStayInRangeAndRestWhenInactive() {
        #expect(MusicEqualizerBarMath.levels(time: 12.3, active: false) == MusicEqualizerBarMath.restLevels)
        for t in stride(from: 0.0, to: 5.0, by: 0.173) {
            let levels = MusicEqualizerBarMath.levels(time: t, active: true)
            #expect(levels.count == MusicEqualizerBarMath.barCount)
            #expect(levels.allSatisfy { $0 >= MusicEqualizerBarMath.minLevel - 0.0001 && $0 <= 1.0001 })
        }
        #expect(MusicEqualizerBarMath.levels(time: .infinity, active: true) == MusicEqualizerBarMath.restLevels)
    }

    @Test func loadingRotationWrapsOncePerPeriod() {
        #expect(MusicLoadingIcon.rotation(time: 0) == 0)
        #expect(abs(MusicLoadingIcon.rotation(time: MusicLoadingIcon.period / 2) - 180) < 0.001)
        #expect(MusicLoadingIcon.rotation(time: MusicLoadingIcon.period * 3) < 0.001)
        #expect(MusicLoadingIcon.rotation(time: .nan) == 0)
    }

    // MARK: skeleton and card geometry

    @Test func skeletonCardMatchesCardGeometry() {
        for size in MusicCardSize.allCases {
            let w = size.width
            let parts = MusicSkeletonGeometry.card(width: w)
            #expect(parts.cover == CGSize(width: w, height: w))
            #expect(parts.height == MusicCardGeometry.height(width: w))
            #expect(parts.titleBar.height <= parts.titleBox)
            #expect(parts.subtitleBar.height <= parts.subtitleBox)
            #expect(parts.titleBar.width <= w && parts.subtitleBar.width <= w)
        }
        #expect(MusicCardGeometry.hoverScale > 1 && MusicCardGeometry.hoverScale <= 1.05)
        #expect(MusicCardGeometry.defaultWidth == 150)
    }

    @Test func skeletonCardCountFillsTheRow() {
        let w = MusicCardGeometry.defaultWidth
        #expect(MusicSkeletonGeometry.cardCount(available: 0, width: w) == 1)
        #expect(MusicSkeletonGeometry.cardCount(available: .nan, width: w) == 1)
        let n = MusicSkeletonGeometry.cardCount(available: 800, width: w)
        #expect(CGFloat(n) * MusicCardGeometry.step(width: w) - MusicCardGeometry.shelfSpacing >= 800)
        #expect(CGFloat(n - 1) * MusicCardGeometry.step(width: w) - MusicCardGeometry.shelfSpacing < 800)
    }

    @Test func partialFailureRules() {
        #expect(MusicPartialFailure.showsBanner(healthy: 3, failed: 1))
        #expect(!MusicPartialFailure.showsBanner(healthy: 0, failed: 2))
        #expect(!MusicPartialFailure.showsBanner(healthy: 3, failed: 0))
        #expect(MusicPartialFailure.showsFullError(healthy: 0, failed: 1))
        #expect(!MusicPartialFailure.showsFullError(healthy: 2, failed: 1))
    }

    // MARK: shelf paging and keyboard

    @Test func keyboardIndexClampsAtTheEnds() {
        #expect(MusicShelfKeyNav.nextIndex(current: 0, count: 5, delta: -1) == 0)
        #expect(MusicShelfKeyNav.nextIndex(current: 4, count: 5, delta: 1) == 4)
        #expect(MusicShelfKeyNav.nextIndex(current: 2, count: 5, delta: 1) == 3)
        #expect(MusicShelfKeyNav.nextIndex(current: 2, count: 5, delta: 99) == 4)
        #expect(MusicShelfKeyNav.nextIndex(current: 2, count: 0, delta: 1) == 0)
    }

    @Test func pagingMaths() {
        let step = MusicCardGeometry.step(width: 150)
        #expect(step == 162)
        #expect(MusicShelfPaging.itemsPerPage(viewport: 800, step: step) == 5)
        #expect(MusicShelfPaging.itemsPerPage(viewport: 0, step: step) == 1)
        let content: CGFloat = 10 * 150 + 9 * MusicCardGeometry.shelfSpacing
        #expect(MusicShelfPaging.itemCount(content: content, step: step) == 10)
        #expect(MusicShelfPaging.maxOffset(content: content, viewport: 800) == content - 800)
        #expect(MusicShelfPaging.maxOffset(content: 300, viewport: 800) == 0)
        #expect(!MusicShelfPaging.canPageBack(offset: 0))
        #expect(MusicShelfPaging.canPageBack(offset: 10))
        #expect(MusicShelfPaging.canPageForward(offset: 0, content: content, viewport: 800))
        #expect(!MusicShelfPaging.canPageForward(offset: content - 800, content: content, viewport: 800))
        #expect(!MusicShelfPaging.canPageForward(offset: 0, content: 300, viewport: 800))
    }

    @Test func pagingTargetsSnapAndClamp() {
        let step: CGFloat = 162
        let content: CGFloat = 10 * 150 + 9 * MusicCardGeometry.shelfSpacing
        #expect(MusicShelfPaging.target(offset: 0, direction: 1, items: 1, step: step, content: content, viewport: 800) == step)
        #expect(MusicShelfPaging.target(offset: 0, direction: 1, items: 5, step: step, content: content, viewport: 800) == content - 800)
        #expect(MusicShelfPaging.target(offset: content - 800, direction: -1, items: 5, step: step, content: content, viewport: 800) == 0)
        #expect(MusicShelfPaging.target(offset: 0, direction: -1, items: 1, step: step, content: content, viewport: 800) == 0)
        #expect(MusicShelfPaging.target(offset: 40, direction: 1, items: 0, step: 0, content: content, viewport: 800) == 40)
    }

    @Test func upcomingRangeIsBounded() {
        let step: CGFloat = 162
        #expect(MusicShelfPaging.firstVisibleIndex(offset: 170, step: step) == 1)
        #expect(MusicShelfPaging.firstVisibleIndex(offset: -20, step: step) == 0)
        #expect(MusicShelfPaging.upcomingRange(offset: 0, viewport: 800, step: step, count: 10, window: 4) == 0..<9)
        #expect(MusicShelfPaging.upcomingRange(offset: 0, viewport: 800, step: step, count: 6, window: 12) == 0..<6)
        #expect(MusicShelfPaging.upcomingRange(offset: 0, viewport: 800, step: step, count: 0, window: 4).isEmpty)
        #expect(MusicShelfPaging.upcomingRange(offset: 0, viewport: 800, step: step, count: 10, window: 0).isEmpty)
    }

    // MARK: tooltip text

    @Test func tooltipComposition() {
        #expect(MusicTooltipText.compose("Play", shortcut: nil) == "Play")
        #expect(MusicTooltipText.compose("Play", shortcut: "") == "Play")
        #expect(MusicTooltipText.compose("Play", shortcut: "Space") == "Play (Space)")
    }
}
