import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The real macOS notification authorization, not REDDY's own toggle. REDDY never claims reminders work when macOS has
/// denied them.
enum NotificationStatus: Equatable, Sendable {
    case authorized, denied, notDetermined, unavailable

    var title: String {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Denied in System Settings"
        case .notDetermined: "Not asked yet"
        case .unavailable: "Unavailable (not running as an app)"
        }
    }
}

enum NotificationPermission {
    static func current() async -> NotificationStatus {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return .unavailable }
        let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch s {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func request() async -> NotificationStatus {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await current()
    }

    @MainActor static func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
