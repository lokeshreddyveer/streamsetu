import Foundation

/// Keeps a few recent backups on this Mac without being asked: when REDDY starts and the last automatic backup is a week old,
/// it writes one (folder order, hidden items, renames, favorites, collections, preferences and playlist names; never passwords)
/// into Application Support/…/Backups and removes all but the newest five.
@MainActor
final class AutoBackupService {
    static let interval: TimeInterval = 7 * 86400
    static let keep = 5
    private let backup: BackupService
    private let settings: AppSettings
    private let channelPrefs: ChannelPlaybackPrefs
    private let directory: URL
    private let now: () -> Date

    init(backup: BackupService, settings: AppSettings, channelPrefs: ChannelPlaybackPrefs, directory: URL = StorageService.backups, now: @escaping () -> Date = Date.init) {
        self.backup = backup; self.settings = settings; self.channelPrefs = channelPrefs; self.directory = directory; self.now = now
    }

    var isDue: Bool {
        guard settings.autoBackup else { return false }
        guard let last = settings.lastAutoBackup else { return true }
        return now().timeIntervalSince(last) >= Self.interval
    }

    /// Writes a backup if one is due. Returns the file written, or nil.
    @discardableResult
    func runIfDue() -> URL? {
        guard isDue else { return nil }
        return runNow()
    }

    @discardableResult
    func runNow() -> URL? {
        guard let data = try? backup.export(.standard, settings: settings, channelPrefs: channelPrefs) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = directory.appendingPathComponent("StreamSetu-auto-\(f.string(from: now())).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { return nil }
        settings.lastAutoBackup = now()
        prune()
        return url
    }

    /// Newest first.
    func existing() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("StreamSetu-auto-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune() { for old in existing().dropFirst(Self.keep) { try? FileManager.default.removeItem(at: old) } }
}
