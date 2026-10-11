import Foundation

/// Where fullscreen is in its window transition (macOS drives this from real window callbacks).
enum FullscreenPhase: Equatable, Sendable { case windowed, entering, fullscreen, exiting }

/// Who is showing the video. Only the view whose owner matches `PlaybackCoordinator.surfaceOwner` renders it.
enum SurfaceOwner: Sendable {
    /// Live TV preview pane
    case embedded
    /// The bottom bar thumbnail (movies and series, and live when no preview pane is open)
    case bar
    case expanded, fullscreen, popout
}
