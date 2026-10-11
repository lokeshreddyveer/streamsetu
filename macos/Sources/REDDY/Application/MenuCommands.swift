import SwiftUI

struct MenuCommands: Commands {
    let router: AppRouter
    let playback: PlaybackCoordinator?
    let state: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Playlist…") { router.modal = .addPlaylist }.keyboardShortcut("n")
            Button("Refresh All Playlists") { state?.syncAll() }.keyboardShortcut("r")
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { openWindow(id: "feedback") }
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }.keyboardShortcut("/", modifiers: .command)
        }
        CommandMenu("Navigate") {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button(tab.title) { router.navigate(tab) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button("Search") { router.focusTopSearch() }.keyboardShortcut("k")
            Button("Search in This Screen") { router.focusCurrentScreenSearch() }.keyboardShortcut("f")
        }
        CommandMenu("Playback") {
            Button("Open Multi-View") { openWindow(id: "multiview") }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Open Player in New Window") { openWindow(id: "player") }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(playback?.current == nil)
            Button("Play / Pause") { playback?.togglePause() }.disabled(playback?.isActive != true)
            Button("Next Channel") { playback?.nextChannel() }.keyboardShortcut("]").disabled(playback?.isLive != true)
            Button("Previous Channel") { playback?.previousChannelInList() }.keyboardShortcut("[").disabled(playback?.isLive != true)
            Button("Last Channel") { playback?.lastChannel() }.keyboardShortcut("l").disabled(playback?.isLive != true)
            Divider()
            Button("Skip Forward 10 Seconds") { playback?.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Skip Back 10 Seconds") { playback?.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Episode") { playback?.playNextEpisode() }.keyboardShortcut("e").disabled(playback?.upNext == nil)
            Divider()
            Menu("Sleep Timer") {
                ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback?.startSleepTimer(minutes: m) } }
                Button("Stop at the End of This Episode or Movie") { playback?.startSleepTimerAtEndOfItem() }.disabled(playback?.isLive != false || playback?.duration == nil)
                if playback?.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer") { playback?.cancelSleepTimer() } }
            }.disabled(playback?.isActive != true)
            Divider()
            Button("Stop") { playback?.stop() }.keyboardShortcut(".").disabled(playback?.isActive != true)
        }
    }
}
