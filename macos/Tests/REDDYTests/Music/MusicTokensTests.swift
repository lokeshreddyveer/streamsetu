import Testing
import CoreGraphics
@testable import REDDY

@Suite("Music tokens, motion and layout grid") struct MusicTokensTests {
    @Test func layoutClassBreakpoints() {
        #expect(MusicLayoutClass.resolve(width: 0) == .compact)
        #expect(MusicLayoutClass.resolve(width: 699.9) == .compact)
        #expect(MusicLayoutClass.resolve(width: 700) == .medium)
        #expect(MusicLayoutClass.resolve(width: 999) == .medium)
        #expect(MusicLayoutClass.resolve(width: 1000) == .expanded)
        #expect(MusicLayoutClass.resolve(width: 1399) == .expanded)
        #expect(MusicLayoutClass.resolve(width: 1400) == .wide)
        #expect(MusicLayoutClass.resolve(width: 5000) == .wide)
        #expect(MusicLayoutClass.resolve(width: -20) == .compact)
        #expect(MusicLayoutClass.resolve(width: .infinity) == .compact)
        #expect(MusicLayoutClass.resolve(width: .nan) == .compact)
    }

    @Test func layoutClassIsMonotonic() {
        var last = MusicLayoutClass.compact
        for w in stride(from: CGFloat(0), through: 2000, by: 25) {
            let c = MusicLayoutClass.resolve(width: w)
            #expect(c >= last)
            last = c
        }
    }

    @Test func regionWidthsStayInRange() {
        for cls in MusicLayoutClass.allCases {
            #expect(MusicLayoutGrid.navCompactRange.contains(MusicLayoutGrid.navWidth(for: cls, expanded: false)))
            let nav = MusicLayoutGrid.navWidth(for: cls, expanded: true)
            #expect(MusicLayoutGrid.navCompactRange.contains(nav) || MusicLayoutGrid.navExpandedRange.contains(nav))
            #expect(MusicLayoutGrid.contextPanelRange.contains(MusicLayoutGrid.contextPanelWidth(for: cls)))
            #expect(MusicLayoutGrid.pageMarginRange.contains(MusicLayoutGrid.pageMargin(for: cls)))
        }
        #expect(MusicLayoutGrid.navWidth(for: .medium, expanded: true) == MusicLayoutGrid.navCompactWidth)
        #expect(MusicLayoutGrid.navWidth(for: .expanded, expanded: true) == MusicLayoutGrid.navExpandedWidth)
        #expect(MusicLayoutGrid.contextPanelInline(for: .wide) && MusicLayoutGrid.contextPanelInline(for: .expanded) && MusicLayoutGrid.contextPanelInline(for: .medium))
        #expect(!MusicLayoutGrid.contextPanelInline(for: .compact))
    }

    @Test func contentWidthIsCappedAndNeverNegative() {
        #expect(MusicLayoutGrid.contentWidth(available: 3000) == MusicLayoutGrid.maxContentWidth)
        #expect(MusicLayoutGrid.contentWidth(available: 0) == 0)
        #expect(MusicLayoutGrid.contentWidth(available: 500) == CGFloat(452))
    }

    @Test func motionDurationsAreOrderedAndInRange() {
        let ms = MusicMotion.Kind.allCases.map(\.baseMilliseconds)
        #expect(ms == ms.sorted())
        #expect(ms.first == 80)
        #expect(ms.last == 500)
        #expect(Set(ms).count == ms.count)
    }

    @Test func reduceMotionBehaviour() {
        for kind in MusicMotion.Kind.allCases {
            let full = MusicMotion.milliseconds(kind, reduce: false)
            let reduced = MusicMotion.milliseconds(kind, reduce: true)
            #expect(full == kind.baseMilliseconds)
            #expect(reduced <= full)
            #expect(reduced <= MusicMotion.reducedFadeMilliseconds)
            if kind.isSpatial {
                #expect(reduced == 0)
                #expect(MusicMotion.animation(kind, reduce: true) == nil)
            }
            #expect(MusicMotion.animation(kind, reduce: false) != nil)
        }
        #expect(MusicMotion.interruptible(reduce: true) == nil)
        #expect(MusicMotion.interruptible(reduce: false) != nil)
    }

    @Test func spacingScaleIsTheAgreedOne() {
        #expect(MusicSpace.scale == [4, 8, 12, 16, 20, 24, 32, 40, 48])
    }

    @Test func typeRolesDescendInSize() {
        let sizes = MusicTypeRole.allCases.map(\.pointSize)
        #expect(sizes == sizes.sorted(by: >))
        #expect(MusicTypeRole.allCases.count == 8)
    }

    @Test func cornerRangesFollowTheGeometryTable() {
        #expect(MusicCorner.range(for: .control) == 6...8)
        #expect(MusicCorner.range(for: .compactCard) == 10...12)
        #expect(MusicCorner.range(for: .card).lowerBound >= 12 && MusicCorner.range(for: .card).upperBound == 16)
        #expect(MusicCorner.range(for: .panel).lowerBound >= 16 && MusicCorner.range(for: .panel).upperBound == 20)
        #expect(MusicCorner.range(for: .immersive) == 20...28)
    }

    @Test func elevationOnlyFloatingLevelsCastShadows() {
        for level in MusicElevation.allCases {
            if level < .floating { #expect(level.shadowRadius == 0 && level.shadowOpacity == 0) } else { #expect(level.shadowRadius > 0) }
        }
        let radii = MusicElevation.allCases.map(\.shadowRadius)
        #expect(radii == radii.sorted())
    }

    @Test func iconSizesAscend() {
        #expect(MusicIconSize.scale == MusicIconSize.scale.sorted())
    }
}
