import Foundation

/// The one primary player UI on screen. Exactly one of these is true at any time.
enum PrimaryPlayerSurface: Equatable, Sendable {
    /// Nothing is playing: no player UI at all.
    case none
    /// The compact bar at the bottom of the main window.
    case bar
    /// Live TV's own preview pane has the video; the bar would only repeat it, so it is hidden.
    case livePreview
    /// The "Now Playing" popup over the main window.
    case expanded
    /// The full-screen window (also while it is entering or leaving).
    case fullscreen
    /// The separate player window. The main window keeps a bar as a remote, showing artwork instead of video.
    case popout
}

/// Pure rules for which player surface is primary. The views read this and nothing else to decide what to show, so the
/// bar, the popup and full screen can never be visible together. Priority: full screen, pop-out window, popup, live preview, bar.
struct PlayerSurfaceInputs: Equatable, Sendable {
    var hasPlayback: Bool
    var isFullscreenRequested = false
    var fullscreenPhase: FullscreenPhase = .windowed
    var isPoppedOut = false
    var isExpanded = false
    var isLive = false
    var onLiveTV = false
    var livePreviewVisible = false
}

enum PlayerSurfaceModel {
    static func primary(_ i: PlayerSurfaceInputs) -> PrimaryPlayerSurface {
        guard i.hasPlayback else { return .none }
        if i.isFullscreenRequested || i.fullscreenPhase != .windowed { return .fullscreen }
        if i.isPoppedOut { return .popout }
        if i.isExpanded { return .expanded }
        if i.onLiveTV && i.isLive && i.livePreviewVisible { return .livePreview }
        return .bar
    }

    /// The bottom bar shows only when it is the primary surface (or as the remote of the pop-out window).
    static func showsBar(_ s: PrimaryPlayerSurface) -> Bool { s == .bar || s == .popout }
    static func showsExpanded(_ s: PrimaryPlayerSurface) -> Bool { s == .expanded }
    /// The bar's thumbnail may hold the video only when the bar is the video's owner; otherwise it shows artwork.
    static func barHoldsVideo(_ s: PrimaryPlayerSurface) -> Bool { s == .bar }
    /// Height the main window reserves at the bottom (the Setu bubble and toasts sit above it).
    static func reservedBottom(_ s: PrimaryPlayerSurface, isLive: Bool) -> CGFloat { showsBar(s) ? BottomPlayerLayout.height(isLive: isLive) : 0 }
}

extension PlaybackCoordinator {
    var primarySurface: PrimaryPlayerSurface {
        PlayerSurfaceModel.primary(PlayerSurfaceInputs(hasPlayback: current != nil, isFullscreenRequested: isFullscreen, fullscreenPhase: fullscreenPhase,
                                                       isPoppedOut: isPoppedOut, isExpanded: isExpanded, isLive: isLive, onLiveTV: livePreviewVisible, livePreviewVisible: livePreviewVisible))
    }
}
