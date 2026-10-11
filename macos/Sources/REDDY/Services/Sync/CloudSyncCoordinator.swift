import Foundation
import Observation

/// Owns iCloud sync for the app: switches it on and off, and passes changes from other devices to the interface.
@MainActor @Observable
final class CloudSyncCoordinator {
    let status = CloudSyncStatus()
    let core: SyncCore
    private let db: DatabaseManager
    private var kit: CloudKitSync?
    private let remoteChange: @Sendable (SyncApplyResult) -> Void

    init(db: DatabaseManager, defaults: UserDefaults, onRemoteChange: @escaping @Sendable (SyncApplyResult) -> Void) {
        self.db = db
        core = SyncCore(db: db, settings: DefaultsSettingsSync(defaults: defaults, db: db))
        remoteChange = onRemoteChange
    }

    var isRunning: Bool { kit != nil && status.state != .off }

    /// Starts or stops sync to match the setting. Safe to call repeatedly.
    func setEnabled(_ on: Bool) async {
        if on {
            if kit == nil { kit = CloudKitSync(core: core, db: db, status: status, onApplied: remoteChange) }
            await kit?.start()
        } else {
            kit?.stop(); kit = nil
            status.state = .off
        }
    }

    func syncNow() async { await kit?.syncNow() }

    /// Called when the app comes to the front or settings change: notice local changes and send them.
    func poke() { kit?.queueChanges() }

    /// Turns sync off and removes this app's data from iCloud. The data on this device is untouched.
    func eraseCloudData() async {
        if kit == nil { kit = CloudKitSync(core: core, db: db, status: status, onApplied: remoteChange) }
        await kit?.eraseCloudData()
        kit = nil
    }
}
