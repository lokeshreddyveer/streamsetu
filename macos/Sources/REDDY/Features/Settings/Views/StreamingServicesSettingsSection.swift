import SwiftUI

/// What the Settings section asks the rest of the app to do. Supplied by the app root; the default does nothing, so the section is safe
/// (and testable) on its own. The clear action must clear exactly one service's website data (the session-clearing API) and update only
/// that service's live web view.
struct StreamingServicesSettingsActions {
    enum ClearOutcome: Equatable, Sendable { case cleared, failed, unavailable }

    /// Opens a service inside the app (the same route as the dropdown). nil hides the Open button.
    var open: (@MainActor (ProviderID) -> Void)?
    /// Clears the website data of one service. nil means clearing is not wired yet.
    var clearWebsiteData: (@MainActor (ProviderID) async -> ClearOutcome)?
    /// Called after the pin list changed and was saved, so a live top bar can reload it.
    var preferencesChanged: (@MainActor () -> Void)?

    static let unwired = StreamingServicesSettingsActions()
}

private struct StreamingServicesActionsKey: EnvironmentKey { static let defaultValue = StreamingServicesSettingsActions.unwired }
extension EnvironmentValues {
    var streamingServicesActions: StreamingServicesSettingsActions {
        get { self[StreamingServicesActionsKey.self] }
        set { self[StreamingServicesActionsKey.self] = newValue }
    }
}

/// Everything the section shows and does, with no views, so it can be tested. Pins and order are the shared `ServicePreferences`; this model never
/// reimplements them and never touches website data on its own.
@MainActor @Observable
final class StreamingServicesSettingsModel {
    /// Posted (object: nil) after the pin list was saved by Settings.
    nonisolated static let preferencesDidChange = Notification.Name("streaming.servicePreferencesDidChange")

    struct Row: Identifiable, Equatable {
        let id: ProviderID
        let name: String
        let availability: ServiceAvailability
        let badge: String            // English key: Available, Unverified, Disabled
        let statusLine: String
        let distributionLine: String
        let limitation: String?
        let pinned: Bool
        let canMoveLeft: Bool
        let canMoveRight: Bool
        let canOpen: Bool
    }

    private(set) var preferences: ServicePreferences
    var pendingClear: ProviderID?
    private(set) var notice: String?

    private let registry: ProviderRegistry
    private let defaults: UserDefaults
    var actions: StreamingServicesSettingsActions
    private let available: [ProviderID]

    init(registry: ProviderRegistry = .standard, defaults: UserDefaults = .standard, actions: StreamingServicesSettingsActions = .unwired) {
        self.registry = registry; self.defaults = defaults; self.actions = actions
        available = registry.listed(on: .macOS).map(\.id)
        preferences = ServicePreferences.load(from: defaults, available: available)
    }

    // MARK: rows

    /// Pinned services first, in pinned order, then the rest in catalog order. Every listed service appears, with its badge.
    var rows: [Row] {
        let listed = registry.listed(on: .macOS)
        let pinned = preferences.pinned.compactMap { id in listed.first { $0.id == id } }
        let others = listed.filter { !preferences.isPinned($0.id) }
        return (pinned + others).map(row)
    }

    private func row(_ d: ProviderDefinition) -> Row {
        let index = preferences.pinned.firstIndex(of: d.id)
        return Row(id: d.id, name: d.displayName, availability: d.availability, badge: Self.badge(d.availability),
                   statusLine: Self.statusLine(d.capabilities), distributionLine: Self.distributionLine(d.distributionAuthorization),
                   limitation: d.authentication == .signedOutOnly ? "Google sign-in is not supported in this view, so this service is used signed out." : nil,
                   pinned: index != nil, canMoveLeft: (index ?? 0) > 0, canMoveRight: index.map { $0 < preferences.pinned.count - 1 } ?? false,
                   canOpen: d.presentation == .embedded && actions.open != nil)
    }

    nonisolated static func badge(_ a: ServiceAvailability) -> String {
        switch a {
        case .available: "Available"
        case .unverified: "Unverified"
        case .disabled: "Disabled"
        case .registered: "Not offered"
        }
    }

    nonisolated static func word(_ s: CapabilityStatus) -> String {
        switch s {
        case .enabledForTesting: "Enabled for testing"
        case .manualVerificationRequired: "Needs a manual check"
        case .unavailable: "Unavailable"
        case .ownerVerified: "Checked by you"
        case .unsupported: "Not supported"
        case .notPermitted: "Not permitted"
        }
    }

    /// "Website: Enabled for testing · Sign-in: Needs a manual check · Playback: Needs a manual check". The words are translated, never claims of playback.
    nonisolated static func statusLine(_ m: CapabilityMatrix) -> String {
        [("Website", m.websiteLoading.status), ("Sign-in", m.authentication.status), ("Playback", m.protectedPlayback.status)]
            .map { Localized.string($0.0) + ": " + Localized.string(word($0.1)) }.joined(separator: " · ")
    }

    /// A plain recorded status. Nothing gates on it.
    nonisolated static func distributionLine(_ a: DistributionAuthorization) -> String {
        Localized.string(a == .confirmed ? "Distribution permission: confirmed" : "Distribution permission: unresolved")
    }

    // MARK: pin and order (the shared preferences API)

    private func commit() {
        preferences.save(to: defaults)
        actions.preferencesChanged?()
        NotificationCenter.default.post(name: Self.preferencesDidChange, object: nil)
    }

    func reload() { preferences = ServicePreferences.load(from: defaults, available: available) }

    func togglePin(_ id: ProviderID) {
        let changed = preferences.isPinned(id) ? preferences.unpin(id) : preferences.pin(id, available: available)
        if changed { commit() }
    }
    func moveLeft(_ id: ProviderID) { if preferences.moveLeft(id) { commit() } }
    func moveRight(_ id: ProviderID) { if preferences.moveRight(id) { commit() } }
    func resetOrder() { preferences.resetOrder(available: available); commit() }

    func open(_ id: ProviderID) {
        guard let d = registry.definition(for: id), d.presentation == .embedded else { return }
        actions.open?(id)
    }

    // MARK: clearing one service's website data

    var canClear: Bool { actions.clearWebsiteData != nil }

    func requestClear(_ id: ProviderID) { if registry.definition(for: id) != nil { pendingClear = id } }
    func cancelClear() { pendingClear = nil }

    func name(of id: ProviderID) -> String { registry.definition(for: id)?.displayName ?? id.rawValue }

    /// Wording of the confirmation; names the service and says it signs the person out.
    func confirmationTitle(_ id: ProviderID) -> String { Localized.string("Clear website data for %@?", name(of: id)) }
    func confirmationMessage(_ id: ProviderID) -> String { Localized.string("This signs you out of %@ and removes its saved website data from this Mac. Your other services stay signed in.", name(of: id)) }

    /// Runs only after the explicit confirmation, and only for the service that was confirmed.
    func confirmClear() async {
        guard let id = pendingClear else { return }
        pendingClear = nil
        let n = name(of: id)
        guard let clear = actions.clearWebsiteData else { notice = Localized.string("Clearing website data is not available yet."); return }
        switch await clear(id) {
        case .cleared: notice = Localized.string("Website data cleared for %@.", n)
        case .failed: notice = Localized.string("Could not clear all website data for %@.", n)
        case .unavailable: notice = Localized.string("Clearing website data is not available yet.")
        }
    }

    func dismissNotice() { notice = nil }
}

/// Settings > Privacy > Streaming Services. One list over the shared pin preferences; no second dropdown.
struct StreamingServicesSettingsSection: View {
    @Environment(\.streamingServicesActions) private var actions
    @State private var model = StreamingServicesSettingsModel()

    var body: some View {
        SettingsGroup(title: "Streaming Services", footer: "Pin services to the top bar and put them in order. Unpinning only hides a service from the bar; it never signs you out or clears anything. Each service keeps its own sign-in on this Mac.") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.rows) { row in
                    ServiceSettingsRow(row: row, model: model, canClear: model.canClear)
                    if row.id != model.rows.last?.id { Divider() }
                }
                SettingsActions {
                    Button { model.resetOrder() } label: { Label("Reset Order", systemImage: "arrow.counterclockwise") }.atlas("control.settings.servicesReset")
                }
                if let notice = model.notice {
                    Text(verbatim: notice).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .onAppear { model.actions = actions; model.reload() }
        .atlasCovers("control.settings.servicesRow")
        .alert(Text(verbatim: model.pendingClear.map(model.confirmationTitle) ?? ""), isPresented: Binding(get: { model.pendingClear != nil }, set: { if !$0 { model.cancelClear() } })) {
            Button("Cancel", role: .cancel) { model.cancelClear() }.atlas("control.settings.servicesClear")
            Button("Clear Website Data", role: .destructive) { Task { await model.confirmClear() } }.atlas("control.settings.servicesClear")
        } message: { Text(verbatim: model.pendingClear.map(model.confirmationMessage) ?? "") }
    }
}

private struct ServiceSettingsRow: View {
    let row: StreamingServicesSettingsModel.Row
    let model: StreamingServicesSettingsModel
    let canClear: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: row.name).font(.system(size: 13, weight: .semibold))
                Text(row.badge.loc).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.18))).foregroundStyle(badgeColor)
                    .accessibilityLabel(Text(verbatim: Localized.string(row.badge)))
                Spacer(minLength: 0)
                Text(row.pinned ? "Pinned" : "Not pinned").font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: row.statusLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: row.distributionLine).font(.callout).foregroundStyle(.secondary)
            if let limitation = row.limitation { Text(limitation.loc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            SettingsActions {
                Button { model.togglePin(row.id) } label: { Label(row.pinned ? "Unpin from Top Bar" : "Pin to Top Bar", systemImage: row.pinned ? "pin.slash" : "pin") }
                    .accessibilityLabel(Text(verbatim: Localized.string(row.pinned ? "Unpin %@ from the top bar" : "Pin %@ to the top bar", row.name))).atlas("control.settings.servicesPin")
                if row.pinned {
                    Button { model.moveLeft(row.id) } label: { Label("Move Left", systemImage: "arrow.left") }.disabled(!row.canMoveLeft)
                        .accessibilityLabel(Text(verbatim: Localized.string("Move %@ left", row.name))).atlas("control.settings.servicesMove")
                    Button { model.moveRight(row.id) } label: { Label("Move Right", systemImage: "arrow.right") }.disabled(!row.canMoveRight)
                        .accessibilityLabel(Text(verbatim: Localized.string("Move %@ right", row.name))).atlas("control.settings.servicesMove")
                }
                if row.availability.presentation == .embedded {
                    Button { model.open(row.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }.disabled(!row.canOpen)
                        .accessibilityLabel(Text(verbatim: Localized.string("Open %@", row.name))).atlas("control.settings.servicesOpen")
                    Button(role: .destructive) { model.requestClear(row.id) } label: { Label("Clear Website Data…", systemImage: "trash") }.disabled(!canClear)
                        .accessibilityLabel(Text(verbatim: Localized.string("Clear website data for %@", row.name))).atlas("control.settings.servicesClear")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var badgeColor: Color {
        switch row.availability {
        case .available: .green
        case .unverified: .orange
        default: .secondary
        }
    }
}
