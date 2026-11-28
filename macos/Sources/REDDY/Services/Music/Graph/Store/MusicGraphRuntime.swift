import Foundation

/// The one place the app gets the graph from. Created lazily: nothing touches disk until a caller asks the store for data. Safe from any thread.
final class MusicGraphRuntime: @unchecked Sendable {
    private let directory: @Sendable () -> URL
    private let lock = NSLock()
    private var _store: MusicGraphStore?
    private var _index: MusicEntityIndex?

    private var wipeHooks: [@Sendable () async -> Void] = []

    init(directory: @escaping @Sendable () -> URL) { self.directory = directory }

    /// Runs `hook` at the start of every privacy wipe (a feed point empties its queue there).
    func onWipe(_ hook: @escaping @Sendable () async -> Void) { lock.withLock { wipeHooks.append(hook) } }

    /// The graph store (a new actor on first use; the file is opened on its first call).
    var store: MusicGraphStore {
        lock.withLock {
            if let s = _store { return s }
            let s = MusicGraphStore(directory: directory())
            _store = s
            return s
        }
    }

    /// The side index of saved records.
    var index: MusicEntityIndex {
        let s = store
        return lock.withLock {
            if let i = _index { return i }
            let i = MusicEntityIndex(store: s)
            _index = i
            return i
        }
    }

    /// The privacy wipe (part of `MusicHub.wipeAll`): closes the database and deletes the Graph folder with its WAL and shm files. The next use starts empty.
    func wipe() async {
        let hooks = lock.withLock { wipeHooks }
        for h in hooks { await h() }
        let s = store
        try? await s.wipe()
        let i = lock.withLock { _index }
        await i?.forgetAll()
    }
}
