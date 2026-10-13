import SwiftUI
import Sparkle

/// Keeps the Mac app current: checks the public release feed in the background and offers new versions (signed, so only ours install).
/// Only runs in builds that carry a feed address (the downloadable app); development runs and tests have none and stay quiet.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = hasFeed ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Called once at launch so the updater (and its daily background check) is running.
    func start() { _ = controller }
}
