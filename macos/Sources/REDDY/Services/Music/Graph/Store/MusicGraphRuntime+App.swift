import Foundation

extension MusicGraphRuntime {
    /// `<Music storage root>/Graph`: excluded from backup by the store itself, never part of the app database, backup or sync.
    static let shared = MusicGraphRuntime(directory: { MusicStorage.subfolder("Graph") })
}
