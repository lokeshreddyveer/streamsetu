import Foundation
import UserNotifications

/// Local notifications for upcoming programs. Nothing leaves the device.
final class ReminderService: @unchecked Sendable {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires an app bundle; it is unavailable when running as a bare executable (tests).
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func identifier(_ programID: Int64) -> String { "reddy.reminder.\(programID)" }

    @discardableResult
    func schedule(program: EPGProgram, channelName: String, leadTime: TimeInterval = 60) async -> Bool {
        guard let center, program.start.timeIntervalSinceNow > leadTime, await requestAuthorization() else { return false }
        let content = UNMutableNotificationContent()
        content.title = program.title
        content.body = "Starting on \(channelName) at \(TimeFormatter.time(program.start))"
        content.sound = .default
        let fire = max(1, program.start.timeIntervalSinceNow - leadTime)
        let req = UNNotificationRequest(identifier: Self.identifier(program.id), content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false))
        do { try await center.add(req); return true } catch { return false }
    }

    func cancel(programID: Int64) { center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier(programID)]) }

    func hasReminder(programID: Int64) async -> Bool {
        guard let center else { return false }
        return await center.pendingNotificationRequests().contains { $0.identifier == Self.identifier(programID) }
    }
}
