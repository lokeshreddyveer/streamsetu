import Foundation
import UserNotifications

/// What Settings > Guide shows for reminders: the permission state and the reminders that are set.
struct GuideReminderItem: Identifiable, Sendable, Equatable { let id: String; let programID: Int64; let title: String; let detail: String; let fires: Date? }

enum GuideReminderPermission: String, Sendable { case notDetermined, denied, allowed, unavailable }

extension ReminderService {
    /// Minutes before the start; "Remind me" uses this. 5 by default.
    static let leadKey = "guide.reminder.leadMinutes"
    static func leadTime(_ d: UserDefaults = .standard) -> TimeInterval { TimeInterval(max(1, min(30, d.object(forKey: leadKey) as? Int ?? 5)) * 60) }

    private var liveCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }
    func permission() async -> GuideReminderPermission {
        guard let c = liveCenter else { return .unavailable }
        switch await c.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }
    /// Programme reminders only (alerts from keywords have their own list), soonest first.
    func pending() async -> [GuideReminderItem] {
        guard let c = liveCenter else { return [] }
        let reqs = await c.pendingNotificationRequests()
        return reqs.filter { $0.identifier.hasPrefix("reddy.reminder.") }.compactMap { r -> GuideReminderItem? in
            guard let pid = Int64(r.identifier.dropFirst("reddy.reminder.".count)) else { return nil }
            let fires = (r.trigger as? UNTimeIntervalNotificationTrigger).map { Date().addingTimeInterval($0.timeInterval) }
            return GuideReminderItem(id: r.identifier, programID: pid, title: r.content.title, detail: r.content.body, fires: fires)
        }.sorted { ($0.fires ?? .distantFuture) < ($1.fires ?? .distantFuture) }
    }
    func cancelAllProgrammeReminders() async {
        guard let c = liveCenter else { return }
        let ids = await c.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("reddy.reminder.") }
        c.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
