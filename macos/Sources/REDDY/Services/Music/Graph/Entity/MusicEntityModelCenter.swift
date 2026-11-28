import Foundation

/// A page's (or panel's) hold on an entity model. Release it when the view goes away; a lease that is simply dropped releases itself.
@MainActor
final class MusicEntityLease {
    let model: MusicEntityModel
    private let token: LeaseToken
    fileprivate init(model: MusicEntityModel, onRelease: @escaping @MainActor @Sendable () -> Void) {
        self.model = model
        token = LeaseToken(onRelease)
    }
    /// Idempotent.
    func release() { token.fire() }
    deinit { token.fireFromDeinit() }

    private final class LeaseToken: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@MainActor @Sendable () -> Void)?
        init(_ a: @escaping @MainActor @Sendable () -> Void) { action = a }
        private func take() -> (@MainActor @Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; let a = action; action = nil; return a }
        @MainActor func fire() { take()?() }
        func fireFromDeinit() { if let a = take() { Task { @MainActor in a() } } }
    }
}

/// Hands out one `MusicEntityModel` per entity id and shares it between every view that holds a lease (the album page, the Related tab, the film
/// view), so the loads exist once. A model nobody holds stays for a grace window (30 s, and at most 12 idle models) so Back is instant; after that
/// its tasks are cancelled and it is dropped.
@MainActor
final class MusicEntityModelCenter {
    static let defaultGrace: Duration = .seconds(30)
    static let maxIdle = 12
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let store: MusicEntityStore
    let graceWindow: Duration
    let maxIdleModels: Int
    private let sleeper: Sleeper

    private struct Slot {
        var model: MusicEntityModel
        var leases = 0
        var idleSince: UInt64 = 0
        var graceTask: Task<Void, Never>?
    }
    private var slots: [MusicEntityID: Slot] = [:]
    private var clock: UInt64 = 0
    private var listener: Task<Void, Never>?
    /// Starts the full-list (completeness) run of an entity when its model is first taken and cancels it when the model is dropped: the lease is the lifetime.
    var completeness: (any MusicEntityCompleting)?

    init(store: MusicEntityStore, graceWindow: Duration = MusicEntityModelCenter.defaultGrace, maxIdleModels: Int = MusicEntityModelCenter.maxIdle,
         sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.store = store; self.graceWindow = graceWindow; self.maxIdleModels = max(1, maxIdleModels); self.sleeper = sleeper
    }

    deinit { listener?.cancel() }

    /// The number of models alive (held or inside their grace window).
    var liveCount: Int { slots.count }
    var idleCount: Int { slots.values.filter { $0.leases == 0 }.count }
    func holds(_ id: MusicEntityID) -> Bool { slots[store.canonical(id)] != nil }
    func leaseCount(_ id: MusicEntityID) -> Int { slots[store.canonical(id)]?.leases ?? 0 }

    /// Takes a hold on the model for `id` (made and started on first use). A provisional id that the store knows has merged gets the survivor's model.
    func acquire(_ requested: MusicEntityID) -> MusicEntityLease {
        listenIfNeeded()
        let id = store.canonical(requested)
        MusicRequestFocus.shared.entity = id   // the page the person is on goes first on a shared lane
        var slot = slots[id] ?? Slot(model: MusicEntityModel(id: id, store: store))
        slot.graceTask?.cancel(); slot.graceTask = nil
        slot.leases += 1
        let fresh = slots[id] == nil
        slots[id] = slot
        if fresh { slot.model.start(); completeness?.begin(id) }
        return MusicEntityLease(model: slot.model) { [weak self] in self?.release(id) }
    }

    private func release(_ id: MusicEntityID) {
        guard var slot = slots[id], slot.leases > 0 else { return }
        slot.leases -= 1
        if slot.leases == 0 {
            clock += 1
            slot.idleSince = clock
            let grace = graceWindow, sleeper = self.sleeper
            slot.graceTask = Task { [weak self] in
                do { try await sleeper(grace) } catch { return }
                self?.expire(id)
            }
        }
        slots[id] = slot
        trimIdle()
    }

    private func expire(_ id: MusicEntityID) {
        guard let slot = slots[id], slot.leases == 0 else { return }
        drop(id)
    }

    private func drop(_ id: MusicEntityID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.graceTask?.cancel()
        slot.model.cancelAll()
        completeness?.end(id)
    }

    /// At most `maxIdleModels` idle models: the one idle longest goes first.
    private func trimIdle() {
        let idle = slots.filter { $0.value.leases == 0 }
        guard idle.count > maxIdleModels else { return }
        for (id, _) in idle.sorted(by: { $0.value.idleSince < $1.value.idleSince }).prefix(idle.count - maxIdleModels) { drop(id) }
    }

    /// Drops every model now (the privacy wipe, or the app going to the background with nothing open).
    func dropAll() { for id in Array(slots.keys) { drop(id) } }

    // MARK: graph changes

    private func listenIfNeeded() {
        guard listener == nil else { return }
        let stream = store.changes()
        listener = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                self.apply(change)
            }
        }
    }

    /// A change reached the store: the models it concerns refresh. A retired id's model hands over to the survivor's.
    func apply(_ change: MusicEntityChange) {
        for (loser, winner) in change.merged {
            guard let slot = slots[loser] else { continue }
            if slots[winner] == nil, slot.leases == 0 { drop(loser) }
        }
        for id in change.ids {
            guard let slot = slots[id] else { continue }
            let model = slot.model
            Task { await model.refresh() }
        }
    }
}
