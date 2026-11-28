import Foundation
import Observation

/// Where a person page keeps the role the person chose, so Back returns to it. The live one writes into `MusicPageMemoryCenter`; tests use a dictionary.
@MainActor
struct MusicPersonMemory {
    var loadRole: (String) -> String?
    var saveRole: (String, String) -> Void

    static func dictionary(_ box: MusicPersonMemoryBox) -> MusicPersonMemory {
        MusicPersonMemory(loadRole: { box.values[$0] }, saveRole: { key, role in box.values[key] = role })
    }
}

@MainActor final class MusicPersonMemoryBox { var values: [String: String] = [:] }

/// What the role-limited metadata refresh needs; returns true when something new landed. The live one asks the resolver (`enrichPerson(id, roles:)`).
typealias MusicPersonRoleEnricher = @Sendable (MusicEntityID, Set<MusicRole>) async -> Bool

/// The person page's model: a lease on the shared entity model (so Back is instant and the loads exist once), the role switcher's state, and the view
/// data of the chosen role. It never references the player and never blocks on a metadata source: every read is the graph's own.
@MainActor @Observable
final class MusicPersonGraphModel {
    let requestedID: MusicEntityID
    let roleHint: MusicRole?
    /// What the person typed when the route came from a name search; nil for every other route (the "Did you mean" row needs it).
    let nameSearchQuery: String?
    let memoryKey: String

    private(set) var chosen: MusicPersonView?
    private(set) var candidates: [MusicPersonCandidate] = []
    /// Bumped when the lease is taken or given back. The lease itself is not observed, so without this a page that drew before `open()` would never read the
    /// shared model it was just handed (it would stay on "Loading" until something unrelated redrew it).
    private(set) var leaseEpoch = 0
    /// Counts the times the person picked another role chip. The page starts its pills again on this, never on the role settling after a hint.
    private(set) var userSelections = 0

    @ObservationIgnored private let center: MusicEntityModelCenter
    @ObservationIgnored private let memory: MusicPersonMemory
    @ObservationIgnored private let enrichRoles: MusicPersonRoleEnricher?
    @ObservationIgnored private var lease: MusicEntityLease?
    @ObservationIgnored private var enriched: Set<MusicPersonView> = []
    @ObservationIgnored private var candidateTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private(set) var candidateLoads = 0

    init(id: MusicEntityID, roleHint: MusicRole?, nameSearchQuery: String?, memoryKey: String, center: MusicEntityModelCenter, memory: MusicPersonMemory,
         enrichRoles: MusicPersonRoleEnricher? = nil) {
        requestedID = id; self.roleHint = roleHint; self.nameSearchQuery = nameSearchQuery; self.memoryKey = memoryKey
        self.center = center; self.memory = memory; self.enrichRoles = enrichRoles
    }

    // MARK: lifecycle

    /// Takes the lease and starts the sections every role shares. Safe to call twice.
    func open() {
        guard lease == nil else { return }
        let l = center.acquire(requestedID)
        lease = l
        leaseEpoch += 1
        chosen = chosen ?? memory.loadRole(memoryKey).flatMap(MusicPersonView.init(rawValue:))
        l.model.load(MusicPersonProfileLoader())
        l.model.load(MusicPersonGroupLoader())
        sync()
    }

    /// Tries again after the person's row could not be read (a failed page was a dead end): the shared model reads the row anew.
    func retry() { lease?.model.restart() }

    /// Releases the lease; the shared model stays for its grace window.
    func close() {
        candidateTask?.cancel(); candidateTask = nil
        enrichTask?.cancel(); enrichTask = nil
        enriched = []   // a refresh that was cancelled by leaving starts again when the page returns
        lease?.release(); lease = nil
        leaseEpoch += 1
    }

    // MARK: what the page reads

    var entity: MusicEntityModel? { _ = leaseEpoch; return lease?.model }
    var phase: MusicEntityPhase { entity?.phase ?? .idle }
    var snapshot: MusicEntitySnapshot? { entity?.snapshot }
    var isGroup: Bool { snapshot?.kind == .group || requestedID.kind == .group }

    var profile: MusicPersonProfile? { entity?.section(MusicPersonProfileLoader.sectionKey).items(MusicPersonProfile.self).first }
    /// The header from the profile, or from the bare row while the profile (aliases, roles) is still loading.
    var header: MusicPersonHeaderData? { profile?.header ?? snapshot.map { MusicPersonHeaderData.build(snapshot: $0, aliases: []) } }
    var roles: MusicPersonRoleSummary { profile?.roles ?? .empty }
    var rolesSettled: Bool {
        guard let p = entity?.section(MusicPersonProfileLoader.sectionKey).phase else { return false }
        return p == .loaded || p == .empty || p == .failed
    }

    /// The role view shown now: the person's choice if they have it, else the remembered or hinted one, else the one with most credits. While nothing
    /// has loaded the hint is held, so the page does not flip when edges arrive.
    var activeView: MusicPersonView? {
        if let c = chosen, roles.has(c) { return c }
        return MusicPersonRoles.initialView(summary: roles, remembered: nil, hint: roleHint, loaded: rolesSettled)
    }

    var viewData: MusicPersonViewData? {
        guard let v = activeView else { return nil }
        return entity?.section(MusicPersonViewLoader.key(v)).items(MusicPersonViewData.self).first
    }
    var viewPhase: MusicSectionPhase {
        guard let v = activeView else { return .idle }
        return entity?.section(MusicPersonViewLoader.key(v)).phase ?? .idle
    }
    var viewLoadFailed: Bool { viewPhase == .failed && viewData == nil }

    /// Members of a group, or the groups of a person.
    var groupSections: [MusicPersonSection] { entity?.section(MusicPersonGroupLoader.sectionKey).items(MusicPersonSection.self) ?? [] }
    var members: [MusicPersonEntry] { groupSections.first { $0.id == .members }?.entries ?? [] }
    var memberOf: [MusicPersonEntry] { groupSections.first { $0.id == .memberOf }?.entries ?? [] }

    /// Changes whenever `sync()` has something new to start (the entity row arrived, the roles settled, the active view moved). The page calls
    /// `sync()` from `.onChange(of: model.syncToken)`.
    var syncToken: String { "\(snapshot?.id.rawValue ?? "-")|\(rolesSettled)|\(activeView?.rawValue ?? "-")" }

    /// Section loads that ran (tests: one per role however often the person switches).
    func runs(of view: MusicPersonView) -> Int { entity?.sectionRuns[MusicPersonViewLoader.key(view)] ?? 0 }

    // MARK: actions

    /// The person picks a role: remembered for Back, loaded once, and its metadata refreshed in the background.
    func select(_ v: MusicPersonView) {
        guard roles.has(v) || roles.isEmpty else { return }
        if v != activeView { userSelections += 1 }
        chosen = v
        memory.saveRole(memoryKey, v.memoryValue)
        sync()
    }

    /// Starts what the active view needs (idempotent): its loader, the role-limited refresh, and the disambiguation row. Call after anything
    /// that can change the active view (the profile arriving, the entity row arriving).
    func sync() {
        guard let m = entity else { return }
        if let v = activeView { m.load(MusicPersonViewLoader(view: v)); refresh(v) }
        loadCandidates()
    }

    /// Asks again for the active role's list after a failed load.
    func retryView() {
        guard let m = entity, let v = activeView else { return }
        m.load(MusicPersonViewLoader(view: v), force: true)
    }

    private func refresh(_ v: MusicPersonView) {
        guard let enrichRoles, rolesSettled, enriched.insert(v).inserted else { return }
        let id = entity?.id ?? requestedID, store = center.store, roles = v.roles
        enrichTask?.cancel()
        enrichTask = Task { [weak self] in
            let changed = await enrichRoles(id, roles)
            // A refresh cancelled by a quick role switch did not finish: let the view ask again when the person comes back to it.
            guard !Task.isCancelled else { await MainActor.run { _ = self?.enriched.remove(v) }; return }
            guard changed else { return }
            await MainActor.run { store.notifyChanged([id]); self?.sync() }
        }
    }

    private func loadCandidates() {
        guard candidateTask == nil, nameSearchQuery != nil, let s = snapshot, s.kind.isAgent else { return }
        candidateLoads += 1
        let q = nameSearchQuery, graph = center.store.graph
        candidateTask = Task { [weak self] in
            let list = await MusicPersonDisambiguation.candidates(for: s, query: q, store: graph)
            guard !Task.isCancelled else { return }
            self?.candidates = list
        }
    }
}
