import SwiftUI
import UniformTypeIdentifiers

struct MenuCommands: Commands {
    let router: AppRouter
    let playback: PlaybackCoordinator?
    let state: AppState?
    /// While the app is locked no command acts (nothing is opened, navigated to or controlled); only the system's own items (About, Quit, updates) stay.
    let lock: AppLock?
    /// The destination state (the Services commands exist only where the platform's capabilities have services).
    var services: ServiceNavigation?
    /// The host of the service on screen (the generic web model resolves it).
    var activeCommands: (any ActiveServiceCommands)?
    /// Pin state for the Pin/Unpin command; presentation only.
    var servicePins: ServiceMenuPinning?
    private var activeHost: (any ActiveServiceCommands)? {
        guard let services, services.activeService != nil else { return nil }
        return activeCommands
    }
    private var locked: Bool { lock?.isLocked == true }
    /// A service is on screen: ⌘R and ⌘← / ⌘→ belong to it (Reload, Back, Forward), so the playlist refresh and the 10-second skips step aside.
    private var serviceShowing: Bool { services?.activeService != nil }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }.disabled(!AppUpdater.shared.isAvailable).atlas("menu.app.checkForUpdates")
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Playlist…") { router.modal = .addPlaylist }.keyboardShortcut("n").disabled(locked).atlas("menu.file.addPlaylist")
            Button("Open Video File…") { openVideoFile() }.keyboardShortcut("o").disabled(locked).atlas("menu.file.openVideoFile")
            Button("Files and Servers…") { openWindow(id: "files") }.disabled(locked).atlas("menu.file.filesAndServers")
            Button("Refresh All Playlists") { state?.syncAll() }.keyboardShortcut("r").disabled(locked || serviceShowing).atlas("menu.file.refreshAll")
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { openWindow(id: "feedback") }.disabled(locked).atlas("menu.help.sendFeedback")
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }.keyboardShortcut("/", modifiers: .command).disabled(locked).atlas("menu.help.keyboardShortcuts")
            Button("Ask Setu") { AssistantLauncher.shared.ask(nil) }.keyboardShortcut("/", modifiers: [.command, .option]).disabled(locked || serviceShowing).atlas("menu.help.askSetu")
        }
        CommandMenu("Navigate") {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button(tab.title) { router.navigate(tab) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)"))).disabled(locked).atlasCovers("menu.navigate.home")
            }
            if let services, !services.services.isEmpty {
                // ⌘6 opens the Services list in the top bar (never one particular service; there are no per-service shortcuts). ⌘0 goes back to StreamSetu, to the section that was open (⌘1 to ⌘5 also leave the service and open that tab).
                Button("Services") { NotificationCenter.default.post(name: .openServicesList, object: nil) }.keyboardShortcut("6").disabled(locked).atlas("menu.navigate.services")
                Button("StreamSetu") { services.returnToStreamSetu() }.keyboardShortcut("0").disabled(locked || services.navExpanded).atlas("menu.navigate.streamsetu")
            }
            Divider()
            Button("Search") { router.focusTopSearch() }.keyboardShortcut("k").disabled(locked).atlas("menu.navigate.search")
            Button("Search in This Screen") { router.focusCurrentScreenSearch() }.keyboardShortcut("f").disabled(locked || serviceShowing).atlas("menu.navigate.searchThisScreen")
            Divider()
            Button("Shuffle Recommendations") { state?.shuffleRecommendations() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(locked).atlas("menu.navigate.shuffle")
        }
        if let services, !services.services.isEmpty {
            // One Services menu. It acts on the service that is showing; nothing here opens a particular service, and every command is off when none is showing.
            CommandMenu("Services") {
                let host = activeHost
                let on = host != nil && !locked
                Button("Back") { host?.goBack() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(!on || host?.canGoBack != true).atlas("menu.services.back")
                Button("Forward") { host?.goForward() }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(!on || host?.canGoForward != true).atlas("menu.services.forward")
                Button("Reload") { host?.reload() }.keyboardShortcut("r").disabled(!on).atlas("menu.services.reload")
                Divider()
                Button("Zoom In") { host?.zoomIn() }.keyboardShortcut("=").disabled(!on || host?.canZoomIn != true).atlas("menu.services.zoomIn")
                Button("Zoom Out") { host?.zoomOut() }.keyboardShortcut("-").disabled(!on || host?.canZoomOut != true).atlas("menu.services.zoomOut")
                Button("Actual Size") { host?.resetZoom() }.keyboardShortcut("0", modifiers: [.command, .option]).disabled(!on || host?.isZoomDefault != false).atlas("menu.services.actualSize")
                Divider()
                Button("Open in Default Browser") { host?.openInDefaultBrowser() }.keyboardShortcut("o", modifiers: [.command, .option, .shift]).disabled(!on || host?.canOpenInBrowser != true).atlas("menu.services.openInBrowser")
                if let id = services.activeService, let pins = servicePins {
                    Button(pins.isPinned(id) ? "Unpin from Top Bar" : "Pin to Top Bar") { pins.toggle(id) }.disabled(locked).atlas("menu.services.pin")
                } else {
                    Button("Pin to Top Bar") {}.disabled(true).atlas("menu.services.pin")
                }
                Divider()
                Button("Clear Website Data…") { if let id = services.activeService, let host { confirmClearData(id, host) } }.disabled(!on).atlas("menu.services.clearData")
            }
        }
        CommandMenu("Playback") {
            Button("Open Multi-View") { openWindow(id: "multiview") }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(locked).atlas("menu.playback.openMultiView")
            Button("Open Player in New Window") { openWindow(id: "player") }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(locked || (playback?.current == nil)).atlas("menu.playback.openPlayerWindow")
            Button("Play / Pause") { playback?.togglePause() }.disabled(locked || (playback?.isActive != true)).atlas("menu.playback.playPause")
            Button("Next Channel") { playback?.nextChannel() }.keyboardShortcut("]").disabled(locked || (playback?.isLive != true)).atlas("menu.playback.nextChannel")
            Button("Previous Channel") { playback?.previousChannelInList() }.keyboardShortcut("[").disabled(locked || (playback?.isLive != true)).atlas("menu.playback.previousChannel")
            Button("Last Channel") { playback?.lastChannel() }.keyboardShortcut("l").disabled(locked || (playback?.isLive != true)).atlas("menu.playback.lastChannel")
            Divider()
            Button("Skip Forward 10 Seconds") { playback?.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(locked || serviceShowing).atlas("menu.playback.skipForward")
            Button("Skip Back 10 Seconds") { playback?.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(locked || serviceShowing).atlas("menu.playback.skipBack")
            Button("Next Episode") { playback?.playNextEpisode() }.keyboardShortcut("e").disabled(locked || (playback?.upNext == nil)).atlas("menu.playback.nextEpisode")
            Divider()
            Menu("Sleep Timer") {
                ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback?.startSleepTimer(minutes: m) }.atlas("menu.playback.sleepTimer") }
                Button("Stop at the End of This Episode or Movie") { playback?.startSleepTimerAtEndOfItem() }.disabled(playback?.isLive != false || playback?.duration == nil).atlas("menu.playback.sleepTimerEndOfItem")
                if playback?.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer") { playback?.cancelSleepTimer() }.atlas("menu.playback.sleepTimerCancel") }
            }.disabled(locked || playback?.isActive != true).atlas("menu.playback.sleepTimer")
            Divider()
            Button("Stop") { playback?.stop() }.keyboardShortcut(".").disabled(locked || (playback?.isActive != true)).atlas("menu.playback.stop")
        }
    }

    /// Asks first; clears only the website data of the service on screen (sign-in, cookies, caches), nothing else in the app.
    private func confirmClearData(_ id: ProviderID, _ host: any ActiveServiceCommands) {
        let alert = NSAlert()
        alert.messageText = Localized.string("Clear %@ website data?", id.title)
        alert.informativeText = Localized.string("This signs you out of %@ in StreamSetu and removes its cookies and saved site data. Your playlists and settings are not touched.", id.title)
        alert.addButton(withTitle: Localized.string("Clear Data")); alert.addButton(withTitle: Localized.string("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let report = await host.clearServiceDataReporting()
            guard report.remainingRecordCount > 0 else { return }
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = Localized.string("Could not clear all website data for %@.", id.title)
            a.addButton(withTitle: Localized.string("OK")); a.runModal()
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

/// What the Services menu does to the service on screen. Each web model conforms; the menu never sees a particular service.
@MainActor protocol ActiveServiceCommands: AnyObject {
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var canZoomIn: Bool { get }
    var canZoomOut: Bool { get }
    var isZoomDefault: Bool { get }
    func goBack()
    func goForward()
    func reload()
    func zoomIn()
    func zoomOut()
    func resetZoom()
    /// Only a service whose links are confirmed first (Netflix) can open its page in the default browser.
    var canOpenInBrowser: Bool { get }
    func openInDefaultBrowser()
    func clearServiceData() async
    func clearServiceDataReporting() async -> SessionClearing.ClearReport
}

extension ServiceWebModel: ActiveServiceCommands {
    var canZoomIn: Bool { zoom.canZoomIn }
    var canZoomOut: Bool { zoom.canZoomOut }
    var isZoomDefault: Bool { zoom.isDefault }
}

struct ServiceMenuPinning {
    var isPinned: (ProviderID) -> Bool
    var toggle: (ProviderID) -> Void
}
