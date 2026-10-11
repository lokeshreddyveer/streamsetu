import Foundation
import CloudKit
import Observation
#if os(macOS)
import Security
#endif

/// What the Settings screen shows.
@MainActor @Observable
final class CloudSyncStatus {
    /// A line for Settings.
    var text: String {
        switch state {
        case .off: "Off"
        case .unavailable(let why): why
        case .idle: lastSync.map { "Up to date · " + $0.formatted(.relative(presentation: .named)) } ?? "Up to date"
        case .syncing: "Syncing…"
        case .failed(let why): why
        }
    }
    enum State: Equatable {
        case off
        case unavailable(String)          // not signed in to iCloud, restricted, or this build has no iCloud
        case idle
        case syncing
        case failed(String)
    }
    var state: State = .off
    var lastSync: Date?
    var pending = 0
    var summary: String?
}

/// Keeps the synced tables and settings in step with the person's private iCloud (CloudKit). Everything travels as one kind of
/// record (see `SyncRow`) in one zone of the private database; nothing is visible to anyone else, including us.
final class CloudKitSync: CKSyncEngineDelegate, @unchecked Sendable {
    static let containerID = "iCloud.app.streamsetu"
    static let recordType = "SyncRow"
    static let zoneID = CKRecordZone.ID(zoneName: "StreamSetu", ownerName: CKCurrentUserDefaultName)

    private let core: SyncCore
    private let db: DatabaseManager
    private let status: CloudSyncStatus
    private let onApplied: @Sendable (SyncApplyResult) -> Void
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var inflight: [String: SyncRow] = [:]               // rows being sent, by record name
    private var serverRecords: [String: CKRecord] = [:]          // last record the server holds, for change tags
    private var timer: Task<Void, Never>?

    init(core: SyncCore, db: DatabaseManager, status: CloudSyncStatus, onApplied: @escaping @Sendable (SyncApplyResult) -> Void) {
        self.core = core; self.db = db; self.status = status; self.onApplied = onApplied
    }

    /// This build can only talk to CloudKit if it was signed with the iCloud entitlement. Asking CloudKit without it would crash.
    static var isEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        return true
        #endif
    }

    // MARK: switching on and off

    @MainActor func start() async {
        guard engine == nil else { return }
        guard Self.isEntitled else { status.state = .unavailable("This build isn't set up for iCloud."); return }
        let container = CKContainer(identifier: Self.containerID)
        switch (try? await container.accountStatus()) ?? .couldNotDetermine {
        case .available: break
        case .noAccount: status.state = .unavailable("Sign in to iCloud in Settings to sync."); return
        case .restricted: status.state = .unavailable("iCloud is restricted on this device."); return
        default: status.state = .unavailable("iCloud isn't available right now."); return
        }
        do { try core.enqueueEverything() } catch { status.state = .failed("Couldn't prepare your data for iCloud."); return }
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: savedState(), delegate: self)
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        lock.withLock { engine = e }
        e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        status.state = .syncing
        queueChanges()
        timer = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000_000); self?.queueChanges() }
        }
    }

    @MainActor func stop() {
        timer?.cancel(); timer = nil
        lock.withLock { engine = nil }
        status.state = .off
    }

    /// Switches sync off and removes everything this app stored in iCloud (the data on this device stays).
    @MainActor func eraseCloudData() async {
        let container = CKContainer(identifier: Self.containerID)
        stop()
        _ = try? await container.privateCloudDatabase.deleteRecordZone(withID: Self.zoneID)
        try? db.write { c in
            try c.execute("DELETE FROM sync_meta"); try c.execute("DELETE FROM sync_state WHERE name = 'ck-engine'")
            try c.execute("DELETE FROM sync_settings_seen")
        }
    }

    func syncNow() async {
        queueChanges()
        guard let e = currentEngine else { return }
        try? await e.fetchChanges()
        try? await e.sendChanges()
    }

    private var currentEngine: CKSyncEngine? { lock.withLock { engine } }

    // MARK: queueing what changed here

    /// Looks for local changes (settings included) and hands them to the engine.
    func queueChanges() {
        guard let e = currentEngine else { return }
        do {
            try core.detectSettingsChanges()
            let pending = try core.pending()
            guard !pending.isEmpty else { Task { @MainActor in self.status.pending = 0 }; return }
            let rows = try core.rows(for: pending)
            lock.withLock { for r in rows { inflight[r.recordName] = r } }
            e.state.add(pendingRecordZoneChanges: rows.map { .saveRecord(CKRecord.ID(recordName: $0.recordName, zoneID: Self.zoneID)) })
            let n = pending.count
            Task { @MainActor in self.status.pending = n }
        } catch { Task { @MainActor in self.status.state = .failed("Couldn't read your changes.") } }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                let text = data.base64EncodedString()
                try? db.write { try $0.execute("INSERT OR REPLACE INTO sync_state(name, value) VALUES('ck-engine', ?)", [text]) }
            }
        case .accountChange(let e):
            switch e.changeType {
            case .signIn: break
            case .signOut, .switchAccounts:
                // another iCloud account is another set of data: start from this device's data for the new one
                try? db.write { c in try c.execute("DELETE FROM sync_meta"); try c.execute("DELETE FROM sync_state WHERE name = 'ck-engine'") }
                try? core.enqueueEverything()
                await MainActor.run { self.status.state = .unavailable("The iCloud account changed. Turn sync off and on again.") }
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let e):
            if e.deletions.contains(where: { $0.zoneID == Self.zoneID }) {        // the iCloud data was erased elsewhere: send everything again
                try? db.write { c in try c.execute("DELETE FROM sync_meta") }
                try? core.enqueueEverything()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                queueChanges()
            }
        case .fetchedRecordZoneChanges(let e):
            let rows: [SyncRow] = lock.withLock {
                var out: [SyncRow] = []
                for m in e.modifications { serverRecords[m.record.recordID.recordName] = m.record; if let r = Self.row(from: m.record) { out.append(r) } }
                return out
            }
            guard !rows.isEmpty else { return }
            if let result = try? core.apply(rows) {
                onApplied(result)
                await MainActor.run { self.status.lastSync = Date() }
            }
        case .sentRecordZoneChanges(let e):
            let delivered: [SyncRow] = lock.withLock {
                var out: [SyncRow] = []
                for r in e.savedRecords { serverRecords[r.recordID.recordName] = r; if let row = inflight.removeValue(forKey: r.recordID.recordName) { out.append(row) } }
                return out
            }
            if !delivered.isEmpty { try? core.markPushed(delivered) }
            for failure in e.failedRecordSaves {
                guard failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord else { continue }
                // someone else wrote this row first: the later change wins, and our change is sent again if it is the later one
                lock.withLock { serverRecords[server.recordID.recordName] = server }
                if let theirs = Self.row(from: server) {
                    _ = try? core.apply([theirs])
                    if let ours = lockedInflight(server.recordID.recordName), ours.modified > theirs.modified {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                    }
                }
            }
            await MainActor.run { self.status.lastSync = Date(); self.status.state = .idle; self.status.pending = self.core.pendingCount() }
        case .willFetchChanges, .willSendChanges:
            await MainActor.run { if self.status.state != .off { self.status.state = .syncing } }
        case .didFetchChanges, .didSendChanges:
            await MainActor.run { if self.status.state == .syncing { self.status.state = .idle }; self.status.pending = self.core.pendingCount() }
        default: break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let row = self.lockedInflight(recordID.recordName) else { syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)]); return nil }
            return self.record(for: row)
        }
    }

    // MARK: records

    private func lockedInflight(_ name: String) -> SyncRow? { lock.withLock { inflight[name] } }

    private func record(for row: SyncRow) -> CKRecord {
        let existing = lock.withLock { serverRecords[row.recordName] }
        let r = existing ?? CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: row.recordName, zoneID: Self.zoneID))
        r["tbl"] = row.table as CKRecordValue
        r["key"] = row.key as CKRecordValue
        r["vals"] = (row.values ?? "") as CKRecordValue
        r["gone"] = (row.deleted ? 1 : 0) as CKRecordValue
        r["modified"] = row.modified as CKRecordValue
        return r
    }

    static func row(from r: CKRecord) -> SyncRow? {
        guard r.recordType == recordType, let t = r["tbl"] as? String, let k = r["key"] as? String, let m = r["modified"] as? Double else { return nil }
        let gone = (r["gone"] as? Int64 ?? 0) != 0
        return SyncRow(table: t, key: k, values: gone ? nil : (r["vals"] as? String ?? "{}"), modified: m)
    }

    private func savedState() -> CKSyncEngine.State.Serialization? {
        guard let text = (try? db.read { try $0.queryOne("SELECT value FROM sync_state WHERE name = 'ck-engine'") { $0.string(0) } }) ?? nil,
              let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}
