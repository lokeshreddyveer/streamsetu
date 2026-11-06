import SwiftUI

@main
struct ReddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("StreamSetu", id: "main") {
            RootView(coordinator: coordinator)
                .scrollIndicators(.hidden)
                .lockedBehind(coordinator.container?.appLock)
                .id(coordinator.container?.settings.themeKey ?? "")        // a theme change rebuilds the window so every view reads the new colours
                .task { await coordinator.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            MenuCommands(router: coordinator.router, playback: coordinator.container?.playback, state: coordinator.state, lock: coordinator.container?.appLock)
        }

        Window("StreamSetu Player", id: "player") {
            if let c = coordinator.container { PlayerWindowView(playback: c.playback).reddyTheme(c.settings).scrollIndicators(.hidden).lockedBehind(c.appLock) }
        }

        Window("Send Feedback", id: "feedback") {
            if let c = coordinator.container { FeedbackWindow().environment(\.container, c).reddyTheme(c.settings).lockedBehind(c.appLock) }
        }
        .windowResizability(.contentSize)

        Window("Files and Servers", id: "files") {
            if let c = coordinator.container { NavigationStack { OnYourDeviceView() }.environment(\.container, c).reddyTheme(c.settings).frame(minWidth: 480, minHeight: 420).lockedBehind(c.appLock) }
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            if let c = coordinator.container { ShortcutsView().reddyTheme(c.settings).scrollIndicators(.hidden).lockedBehind(c.appLock) }
        }
        .windowResizability(.contentSize)

        Window("Multi-View", id: "multiview") {
            if let c = coordinator.container { MultiViewWindow(model: c.multiView).reddyTheme(c.settings).environment(\.artwork, c.artwork).scrollIndicators(.hidden).lockedBehind(c.appLock) }
        }

        Settings {
            if let c = coordinator.container, let s = coordinator.state {
                SettingsView().id(c.settings.themeKey).environment(c.settings).environment(s).environment(coordinator.router).environment(\.container, c).environment(\.artwork, c.artwork).lockedBehind(c.appLock)
            } else { Text("Opening…").padding() }
        }
    }
}
