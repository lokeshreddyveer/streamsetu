import Foundation
import Observation

/// The first-run "Restore from iCloud": turns iCloud sync on, then waits for the person's playlists to arrive from their other
/// devices. If nothing turns up, sync is turned off again, so nothing is left switched on that the person did not get a result from.
@MainActor @Observable
final class ICloudRestore {
    enum Phase: Equatable { case idle, looking, nothingFound }
    private(set) var phase: Phase = .idle
    private(set) var detail = ""

    func start(container: AppContainer, state: AppState, patience: Int = 30, pause: UInt64 = 1_500_000_000) async {
        guard phase != .looking else { return }
        phase = .looking
        detail = "Looking in your iCloud…"
        container.settings.iCloudSync = true
        await container.updateCloudSync()
        await container.cloud.syncNow()
        for _ in 0..<patience {
            try? await Task.sleep(nanoseconds: pause)
            state.reload()
            detail = container.cloud.status.text
            if !state.sources.isEmpty { phase = .idle; return }       // the welcome screen closes by itself once a playlist exists
        }
        container.settings.iCloudSync = false
        await container.updateCloudSync()
        phase = .nothingFound
        detail = "Nothing was found in iCloud yet. Check that you are signed in to iCloud on this device, and that iCloud Sync is on in StreamSetu on the device that has your playlists."
    }
}
