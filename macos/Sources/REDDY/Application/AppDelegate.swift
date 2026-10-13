import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let media = SelfTest.requested { SelfTest.run(media) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.coordinator?.shutdown() }
    }
}
