import SwiftUI
import AppKit

/// Fullscreen content: the video, the same controls, and Escape / double-click / the button all leave fullscreen.
struct FullscreenPlayerRoot: View {
    let container: AppContainer
    @State private var program: EPGProgram?
    @State private var nextProgram: EPGProgram?

    var body: some View {
        let p = container.playback
        FullscreenPlayerView(playback: p, program: program, nextProgram: nextProgram) { p.isFullscreen = false }
            .environment(container.settings).environment(\.container, container)
            .reddyTheme(container.settings)
            .task(id: p.currentChannel?.id) {
                guard let id = p.currentChannel?.id else { program = nil; nextProgram = nil; return }
                let list = await Task.detached { (try? container.epgRepo.nowNext(channelIDs: [id], at: Date()))?[id] ?? [] }.value
                program = list.first { $0.isLive() }; nextProgram = list.first { $0.start > Date() }
            }
    }
}

/// The window's content: the SwiftUI root hosted in an AppKit view (kept here so the playback layer stays free of SwiftUI).
extension PlayerFullscreenWindow {
    convenience init(title: String, content: FullscreenPlayerRoot) { self.init(title: title, contentView: NSHostingView(rootView: content)) }
}
