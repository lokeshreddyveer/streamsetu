import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
        MainActor.assumeIsolated { MainStallLog.start() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let media = SelfTest.requested { SelfTest.run(media) }
    }

    /// Closing the last window quits the app, except while the Music mini player is the only thing on screen (the main window is only hidden then): hiding it must
    /// not end the app. Quit from the menu or Command-Q is unaffected.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MainActor.assumeIsolated { MusicMiniPlayerController.shared.keepsAppAlive }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.coordinator?.shutdown(); MusicHub.shared.library.flush() }   // what was saved a moment ago (a like and its date) is on disk before the app ends
    }
}
