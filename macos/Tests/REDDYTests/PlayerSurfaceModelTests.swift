import Testing
import Foundation
@testable import REDDY

@Suite struct PlayerSurfaceModelTests {
    private func inputs(_ edit: (inout PlayerSurfaceInputs) -> Void) -> PlayerSurfaceInputs {
        var i = PlayerSurfaceInputs(hasPlayback: true); edit(&i); return i
    }

    @Test func everyStateHasExactlyOnePrimaryAndNeverBarWithPopup() {
        let table: [(String, PlayerSurfaceInputs, PrimaryPlayerSurface)] = [
            ("nothing playing", .init(hasPlayback: false, isExpanded: true), .none),
            ("play a movie", inputs { _ in }, .bar),
            ("expand the bar", inputs { $0.isExpanded = true }, .expanded),
            ("full screen requested from bar", inputs { $0.isFullscreenRequested = true }, .fullscreen),
            ("full screen requested from popup", inputs { $0.isFullscreenRequested = true; $0.isExpanded = true }, .fullscreen),
            ("entering", inputs { $0.fullscreenPhase = .entering; $0.isExpanded = true }, .fullscreen),
            ("exiting", inputs { $0.fullscreenPhase = .exiting }, .fullscreen),
            ("popped out", inputs { $0.isPoppedOut = true }, .popout),
            ("popped out with popup flag", inputs { $0.isPoppedOut = true; $0.isExpanded = true }, .popout),
            ("live preview on Live TV", inputs { $0.isLive = true; $0.onLiveTV = true; $0.livePreviewVisible = true }, .livePreview),
            ("live elsewhere keeps the bar", inputs { $0.isLive = true }, .bar),
            ("popup over live preview", inputs { $0.isLive = true; $0.onLiveTV = true; $0.livePreviewVisible = true; $0.isExpanded = true }, .expanded),
        ]
        for (name, i, want) in table {
            let got = PlayerSurfaceModel.primary(i)
            #expect(got == want, "\(name)")
            let visible = [PlayerSurfaceModel.showsBar(got), PlayerSurfaceModel.showsExpanded(got)].filter { $0 }.count
            #expect(visible <= 1, "\(name): bar and popup together")
            if got == .expanded || got == .fullscreen || got == .none || got == .livePreview { #expect(!PlayerSurfaceModel.showsBar(got), "\(name)") }
        }
    }

    @Test func barKeepsTheVideoOnlyWhenItOwnsIt() {
        #expect(PlayerSurfaceModel.barHoldsVideo(.bar))
        #expect(!PlayerSurfaceModel.barHoldsVideo(.popout))
        #expect(PlayerSurfaceModel.reservedBottom(.expanded, isLive: false) == 0)
        #expect(PlayerSurfaceModel.reservedBottom(.bar, isLive: false) == BottomPlayerLayout.height(isLive: false))
    }

    /// The reported bug: the popup was open while the bar was still shown with an empty thumbnail.
    @Test func openingThePopupHidesTheBar() {
        let before = PlayerSurfaceModel.primary(inputs { _ in })
        let after = PlayerSurfaceModel.primary(inputs { $0.isExpanded = true })
        #expect(PlayerSurfaceModel.showsBar(before)); #expect(!PlayerSurfaceModel.showsBar(after)); #expect(PlayerSurfaceModel.showsExpanded(after))
    }
}
