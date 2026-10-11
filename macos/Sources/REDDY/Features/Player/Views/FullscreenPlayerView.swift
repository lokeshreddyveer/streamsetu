import SwiftUI

struct FullscreenPlayerView: View {
    let playback: PlaybackCoordinator
    var program: EPGProgram?
    var nextProgram: EPGProgram?
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(playback: playback, owner: .fullscreen)
            PlayerControlsOverlay(playback: playback, program: program, nextProgram: nextProgram, isFullscreenPlayer: true, onToggleFullscreen: onClose, onChannelList: nil, onClose: onClose)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video player")
    }
}

/// A separate window so the catalog can be browsed on one display while video plays on another.
struct PlayerWindowView: View {
    let playback: PlaybackCoordinator
    var body: some View {
        ZStack {
            Color.black
            VideoSurface(playback: playback, owner: .popout)
            PlayerControlsOverlay(playback: playback, onToggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) })
        }
        .onAppear { playback.isPoppedOut = true }
        .onDisappear { playback.isPoppedOut = false }
        .frame(minWidth: 480, minHeight: 270)
        .navigationTitle(playback.title.isEmpty ? "StreamSetu Player" : playback.title)
    }
}
