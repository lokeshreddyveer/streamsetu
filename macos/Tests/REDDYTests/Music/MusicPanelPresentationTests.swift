import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("The context panel only opens when asked") struct MusicPanelPresentationTests {
    @Test func aRememberedOpenPanelIsNotPutOverThePageAsAnOverlay() {
        #expect(!MusicPanelPresentation.shown(isOpen: true, hasTrack: true, inline: false, overlayArmed: false))
        #expect(MusicPanelPresentation.shown(isOpen: true, hasTrack: true, inline: false, overlayArmed: true))
    }
    @Test func theInlinePanelOfAWideWindowFollowsTheRememberedState() {
        #expect(MusicPanelPresentation.shown(isOpen: true, hasTrack: true, inline: true, overlayArmed: false))
        #expect(!MusicPanelPresentation.shown(isOpen: false, hasTrack: true, inline: true, overlayArmed: true))
        #expect(!MusicPanelPresentation.shown(isOpen: true, hasTrack: false, inline: true, overlayArmed: true))
    }
    @Test func theContentNeverGetsMoreThanTheWindowHas() {
        for w in stride(from: 300.0, through: 2000.0, by: 37.0) {
            for expanded in [true, false] {
                let g = MusicShellGeometry.resolve(totalWidth: CGFloat(w), sidebarExpanded: expanded, panelOpen: true)
                #expect(g.navWidth + g.contentWidth + (g.panelInline ? g.panelWidth : 0) <= CGFloat(w) + 0.5 || g.contentWidth == 0, "width \(w)")
            }
        }
    }
    @Test func armingFollowsTheOpenAndCloseButtonsAndResetsOnANewSection() {
        let s = MusicContextPanelState(defaults: UserDefaults(suiteName: "panel-test-\(UUID().uuidString)")!)
        #expect(!s.overlayArmed)
        s.toggleOpen(); #expect(s.isOpen && s.overlayArmed)
        s.enter(.explore); #expect(!s.overlayArmed)
        s.toggleOpen(); s.toggleOpen(); #expect(!s.overlayArmed)
    }
}
