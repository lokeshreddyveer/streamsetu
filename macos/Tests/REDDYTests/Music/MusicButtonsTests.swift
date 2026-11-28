import Testing
import SwiftUI
@testable import REDDY

// Pure logic of the Music button system, the shared page frame and the Devices page mapping.

@MainActor
struct MusicButtonsTests {
    // MARK: size scale and hit targets

    @Test func heightScaleIsOrderedAndMatchesTheSpec() {
        #expect(MusicButtonSize.compact.height == 28)
        #expect(MusicButtonSize.regular.height == 32)
        #expect(MusicButtonSize.large.height == 40)
        let heights = MusicButtonSize.allCases.map(\.height)
        #expect(heights == heights.sorted())
        #expect(MusicButtonSize.compact.horizontalPadding < MusicButtonSize.large.horizontalPadding)
    }

    @Test func everySizeMeetsThePlatformHitTarget() {
        for size in MusicButtonSize.allCases {
            #expect(MusicButtonMetrics.height(size, minimum: MusicHitTarget.macMinimum) >= MusicHitTarget.macMinimum)
            #expect(MusicButtonMetrics.height(size, minimum: MusicHitTarget.touchMinimum) >= MusicHitTarget.touchMinimum)
            #expect(MusicButtonMetrics.meetsHitTarget(size, minimum: MusicHitTarget.macMinimum))
            #expect(MusicButtonMetrics.iconSide(size, minimum: MusicHitTarget.touchMinimum) >= 44)
        }
        #expect(MusicButtonMetrics.height(.large, minimum: 28) == 40)
        #expect(MusicButtonMetrics.height(.compact, minimum: 44) == 44)
    }

    @Test func onlyChipsAreCapsules() {
        for v in MusicButtonVariant.allCases { #expect(MusicButtonMetrics.usesCapsule(v) == [.primary, .hero, .secondary, .chip, .glassIcon, .destructive].contains(v)) }
        #expect(MusicButtonSize.regular.corner == MusicCorner.control)
        #expect(MusicButtonSize.large.corner == MusicCorner.controlLarge)
    }

    // MARK: state, fill and label

    @Test func stateOrderIsDisabledThenPressedThenHover() {
        #expect(MusicButtonLogic.state(enabled: false, pressed: true, hovering: true) == .disabled)
        #expect(MusicButtonLogic.state(enabled: true, pressed: true, hovering: true) == .pressed)
        #expect(MusicButtonLogic.state(enabled: true, pressed: false, hovering: true) == .hover)
        #expect(MusicButtonLogic.state(enabled: true, pressed: false, hovering: false) == .rest)
    }

    @Test func fillOpacityDimsWhenPressedAndDisabled() {
        #expect(MusicButtonLogic.fillOpacity(.rest) == 1)
        #expect(MusicButtonLogic.fillOpacity(.hover) < 1)
        #expect(MusicButtonLogic.fillOpacity(.pressed) < MusicButtonLogic.fillOpacity(.hover))
        #expect(MusicButtonLogic.fillOpacity(.disabled) < MusicButtonLogic.fillOpacity(.pressed))
    }

    @Test func filledVariants() {
        #expect(MusicButtonLogic.isFilled(.primary))
        #expect(MusicButtonLogic.isFilled(.hero))
        #expect(!MusicButtonLogic.isFilled(.secondary))
        #expect(!MusicButtonLogic.isFilled(.chip))
        // a chosen chip is tonal (a tint, an edge and a check), not a solid accent block
        #expect(!MusicButtonLogic.isFilled(.chip, selected: true))
        #expect(MusicButtonLogic.isTonal(.chip, selected: true) && !MusicButtonLogic.isTonal(.chip, selected: false) && !MusicButtonLogic.isTonal(.primary, selected: true))
        #expect(MusicButtonLogic.tonalOpacity(.rest) < MusicButtonLogic.tonalOpacity(.hover) && MusicButtonLogic.tonalOpacity(.hover) < MusicButtonLogic.tonalOpacity(.pressed))
    }

    @Test func labelInkIsReadableOnDarkAndLightFills() {
        let onDark = ColorTokens.luminance(of: MusicButtonLogic.labelInk(fill: Color(hex: 0x1A237E)))
        let onLight = ColorTokens.luminance(of: MusicButtonLogic.labelInk(fill: Color(hex: 0xFFD54F)))
        #expect(onDark > 0.9)
        #expect(onLight < 0.05)
    }

    @Test func focusRingIsKeyboardOnly() {
        #expect(MusicButtonLogic.showsFocusRing(focused: true, keyboard: true))
        #expect(!MusicButtonLogic.showsFocusRing(focused: true, keyboard: false))
        #expect(!MusicButtonLogic.showsFocusRing(focused: false, keyboard: true))
    }

    @Test func pressScaleIsOffUnderReduceMotion() {
        #expect(MusicButtonLogic.pressScale(pressed: true, reduceMotion: false) < 1)
        #expect(MusicButtonLogic.pressScale(pressed: true, reduceMotion: true) == 1)
        #expect(MusicButtonLogic.pressScale(pressed: false, reduceMotion: false) == 1)
    }

    // MARK: page frame

    private let widths: [CGFloat] = [500, 700, 900, 1000, 1180, 1400, 1800, 2600]
    private let pages = ["Devices", "Room", "Downloads", "Stats", "Import", "Library", "Detail", "Home", "Explore", "Search"]

    @Test func everyPageStartsAtTheSameX() {
        for w in widths {
            let edges = Set(pages.map { _ in MusicLayout.frame(available: w).leadingEdge })
            #expect(edges.count == 1, "width \(w)")
        }
    }

    @Test func frameUsesTheGridMarginsAndCap() {
        for w in widths {
            let f = MusicPageFrame.resolve(available: w)
            #expect(f.margin == MusicLayoutGrid.pageMargin(for: MusicLayoutClass.resolve(width: w)))
            #expect(f.contentWidth <= MusicLayoutGrid.maxContentWidth)
            #expect(f.contentWidth == MusicLayoutGrid.contentWidth(available: w))
            #expect(f.leadingEdge >= f.margin)
            // The column is centred: the same room is left on the right.
            #expect(abs((w - f.leadingEdge - f.contentWidth) - f.leadingEdge) < 0.001)
        }
    }

    @Test func narrowWindowsStartAtTheMargin() {
        let f = MusicPageFrame.resolve(available: 900)
        #expect(f.leadingEdge == f.margin)
        #expect(f.contentWidth == 900 - f.margin * 2)
    }

    @Test func wideWindowsCentreTheCappedColumn() {
        let f = MusicPageFrame.resolve(available: 2600)
        #expect(f.contentWidth == MusicLayoutGrid.maxContentWidth)
        #expect(f.leadingEdge > f.margin)
    }

    @Test func leftEdgeNeverMovesLeftAsTheWindowGrows() {
        var last: CGFloat = 0
        for w in stride(from: CGFloat(600), through: 3000, by: 100) {
            let f = MusicPageFrame.resolve(available: w)
            #expect(f.leadingEdge >= last)
            last = f.leadingEdge
        }
    }

    @Test func degenerateWidthsGiveAnEmptyColumn() {
        for w in [CGFloat.nan, .infinity, -10, 0] {
            let f = MusicPageFrame.resolve(available: w)
            #expect(f.contentWidth == 0 && f.leadingEdge == 0)
        }
    }

    // MARK: Devices page mapping

    @Test func peerStateMapping() {
        #expect(MusicDevicesLogic.peerState(isPaired: false, isConnected: false, codeOpen: false) == .available)
        #expect(MusicDevicesLogic.peerState(isPaired: false, isConnected: false, codeOpen: true) == .pairing)
        #expect(MusicDevicesLogic.peerState(isPaired: true, isConnected: false, codeOpen: false) == .paired)
        #expect(MusicDevicesLogic.peerState(isPaired: true, isConnected: true, codeOpen: false) == .connected)
        #expect(MusicDevicesLogic.peerState(isPaired: false, isConnected: true, codeOpen: true) == .connected)
    }

    @Test func actionTitlesAndPrimary() {
        #expect(MusicDevicesLogic.actionTitle(.paired) == "Control")
        #expect(MusicDevicesLogic.actionTitle(.available) == "Pair")
        #expect(MusicDevicesLogic.actionTitle(.pairing) == "Cancel")
        #expect(MusicDevicesLogic.actionTitle(.connected) == "Disconnect")
        #expect(MusicDevicesLogic.actionIsPrimary(.paired))
        #expect([MusicDevicesLogic.PeerState.available, .pairing, .connected].allSatisfy { !MusicDevicesLogic.actionIsPrimary($0) })
    }

    @Test func searchStateAndChips() {
        #expect(MusicDevicesLogic.searchState(browsing: false, peerCount: 3) == .idle)
        #expect(MusicDevicesLogic.searchState(browsing: true, peerCount: 0) == .searching)
        #expect(MusicDevicesLogic.searchState(browsing: true, peerCount: 2) == .found(2))
        #expect(MusicDevicesLogic.searchChip(.idle) == nil)
        #expect(MusicDevicesLogic.searchChip(.searching)?.title == "Searching")
        #expect(MusicDevicesLogic.chip(.connected).tone == .good)
        #expect(MusicDevicesLogic.chip(.paired).title == "Paired")
        #expect(MusicDevicesLogic.chip(.available).title == "New")
    }

    @Test func codeEntryKeepsSixDigits() {
        #expect(MusicDevicesLogic.cleanedCode("12a34 5678") == "123456")
        #expect(MusicDevicesLogic.cleanedCode("") == "")
    }
}
