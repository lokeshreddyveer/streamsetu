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
}
