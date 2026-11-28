import Foundation

extension MusicGraphIngest {
    /// The app's feed point: writes into the shared graph store, and stands down while the app is locked or a Kids profile is on. The privacy wipe empties it.
    static let shared: MusicGraphIngest = {
        let ingest = MusicGraphIngest(store: { MusicGraphRuntime.shared.store }, gate: { await MainActor.run { !MusicHub.shared.gated } })
        MusicGraphRuntime.shared.onWipe { await ingest.reset() }
        return ingest
    }()
}
