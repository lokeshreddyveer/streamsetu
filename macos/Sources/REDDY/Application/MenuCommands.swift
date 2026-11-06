import SwiftUI
import UniformTypeIdentifiers

struct MenuCommands: Commands {
    let router: AppRouter
    let playback: PlaybackCoordinator?
    let state: AppState?
    /// While the app is locked no command acts (nothing is opened, navigated to or controlled); only the system's own items (About, Quit, updates) stay.
    let lock: AppLock?
    private var locked: Bool { lock?.isLocked == true }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }.disabled(!AppUpdater.shared.isAvailable)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Playlist…") { router.modal = .addPlaylist }.keyboardShortcut("n").disabled(locked)
            Button("Open Video File…") { openVideoFile() }.keyboardShortcut("o").disabled(locked)
            Button("Files and Servers…") { openWindow(id: "files") }.disabled(locked)
            Button("Refresh All Playlists") { state?.syncAll() }.keyboardShortcut("r").disabled(locked)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { openWindow(id: "feedback") }.disabled(locked)
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }.keyboardShortcut("/", modifiers: .command).disabled(locked)
        }
        CommandMenu("Navigate") {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button(tab.title) { router.navigate(tab) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)"))).disabled(locked)
            }
            Divider()
            Button("Search") { router.focusTopSearch() }.keyboardShortcut("k").disabled(locked)
            Button("Search in This Screen") { router.focusCurrentScreenSearch() }.keyboardShortcut("f").disabled(locked)
        }
        CommandMenu("Playback") {
            Button("Open Multi-View") { openWindow(id: "multiview") }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(locked)
            Button("Open Player in New Window") { openWindow(id: "player") }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(locked || (playback?.current == nil))
            Button("Play / Pause") { playback?.togglePause() }.disabled(locked || (playback?.isActive != true))
            Button("Next Channel") { playback?.nextChannel() }.keyboardShortcut("]").disabled(locked || (playback?.isLive != true))
            Button("Previous Channel") { playback?.previousChannelInList() }.keyboardShortcut("[").disabled(locked || (playback?.isLive != true))
            Button("Last Channel") { playback?.lastChannel() }.keyboardShortcut("l").disabled(locked || (playback?.isLive != true))
            Divider()
            Button("Skip Forward 10 Seconds") { playback?.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(locked)
            Button("Skip Back 10 Seconds") { playback?.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(locked)
            Button("Next Episode") { playback?.playNextEpisode() }.keyboardShortcut("e").disabled(locked || (playback?.upNext == nil))
            Divider()
            Menu("Sleep Timer") {
                ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback?.startSleepTimer(minutes: m) } }
                Button("Stop at the End of This Episode or Movie") { playback?.startSleepTimerAtEndOfItem() }.disabled(playback?.isLive != false || playback?.duration == nil)
                if playback?.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer") { playback?.cancelSleepTimer() } }
            }.disabled(locked || playback?.isActive != true)
            Divider()
            Button("Stop") { playback?.stop() }.keyboardShortcut(".").disabled(locked || (playback?.isActive != true))
        }
    }

    private func openVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audiovisualContent, .item]
        guard panel.runModal() == .OK, let url = panel.url, let playback else { return }
        playback.play(file: url, title: LocalMedia.title(fromFileName: url.lastPathComponent), subtitles: LocalMedia.sidecarURLs(for: url))
        playback.isExpanded = true
    }
}
