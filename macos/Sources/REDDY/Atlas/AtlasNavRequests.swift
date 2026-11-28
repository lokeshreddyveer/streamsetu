import Foundation
import Observation

/// Things the atlas asks the screen to do that only a view can do (open a window, pick a Settings tab). The view that owns the capability watches the request and clears it.
@MainActor @Observable final class AtlasNavRequests {
    static let shared = AtlasNavRequests()
    /// A window id from ReddyApp ("shortcuts", "files", "multiview", ...).
    var window: String?
    /// A Settings tab name ("Playback"), taken when the Settings window shows it.
    var settingsTab: String?
    func takeSettingsTab() -> String? { defer { settingsTab = nil }; return settingsTab }
    /// Opens the Settings window. Since macOS 14 only a view's `openSettings` action does that (the old `showSettingsWindow:` selector does nothing), so the main window installs it here.
    @ObservationIgnored var settingsOpener: (() -> Void)?
    /// Opens Settings, on `tab` when given. False when no window has installed the opener; no tab is left waiting then, so a later manual open does not jump.
    @discardableResult func showSettings(tab: String? = nil) -> Bool {
        guard let open = settingsOpener else { return false }
        if let tab { settingsTab = tab }
        open()
        return true
    }
}
