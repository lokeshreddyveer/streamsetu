import SwiftUI

/// The video box of the Live TV player: the shared video surface with its controls on top. It fills whatever size it is
/// given; the surface letterboxes the picture inside, so any source aspect ratio is shown whole and undistorted.
/// Nothing here owns playback. Resizing or re-laying out only moves this box; the engine and its surface are the same.
struct LivePlayerStage: View {
    let playback: PlaybackCoordinator
    var program: EPGProgram?
    var nextProgram: EPGProgram?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(playback: playback, owner: .embedded)
            PlayerControlsOverlay(playback: playback, program: program, nextProgram: nextProgram,
                                  onToggleFullscreen: { playback.isFullscreen = true }, onChannelList: nil)
        }
        .onAppear { playback.livePreviewVisible = true }
        .onDisappear { playback.livePreviewVisible = false }
        .clipShape(RoundedRectangle(cornerRadius: LayoutTokens.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.radiusLarge, style: .continuous).strokeBorder(ColorTokens.line))
    }
}
