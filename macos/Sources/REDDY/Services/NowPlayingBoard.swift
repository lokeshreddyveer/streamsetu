import Foundation
import Observation

/// What the person's other devices are playing right now, learned over the Wi-Fi sync. Nothing is shown for a device that stopped, went private or has not been heard from lately.
@MainActor @Observable
final class NowPlayingBoard {
    struct Entry: Equatable, Identifiable {
        let deviceID: String
        var deviceName: String
        let title: String
        let position: Double
        /// Playlist key, kind and provider id: how every device names the same item.
        let key: [String]
        let at: Date
        var id: String { deviceID }
    }

    /// An entry older than this is dropped: devices tell each other when they stop, but a device that is switched off cannot.
    static let staleAfter: TimeInterval = 4 * 60

    private(set) var entries: [Entry] = []

    /// Records that arrived from a paired device.
    func ingest(_ records: [LanRecord]) {
        for r in records where r.kind == "now" {
            guard let id = r.key.first else { continue }
            let at = Date(timeIntervalSince1970: Double(r.ts) / 1000)
            if let existing = entries.first(where: { $0.deviceID == id }), existing.at >= at { continue }
            entries.removeAll { $0.deviceID == id }
            guard !r.deleted, let v = r.value, let title = v["title"]?.string, let src = v["src"]?.string, let kind = v["kind"]?.string, let prov = v["prov"]?.string else { continue }
            entries.append(Entry(deviceID: id, deviceName: v["dev"]?.string ?? "Another device", title: title, position: v["pos"]?.number ?? 0, key: [src, kind, prov], at: at))
        }
    }

    /// What to show now, newest first.
    func current(now: Date = Date()) -> [Entry] { entries.filter { now.timeIntervalSince($0.at) < Self.staleAfter }.sorted { $0.at > $1.at } }
}
