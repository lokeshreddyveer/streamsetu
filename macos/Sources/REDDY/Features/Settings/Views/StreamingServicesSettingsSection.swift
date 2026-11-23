import SwiftUI
import AppKit

/// What the Settings section asks the rest of the app to do. Supplied by the app root; the default does nothing, so the section is safe
/// (and testable) on its own. The clear action must clear exactly one service's website data (the session-clearing API) and update only
/// that service's live web view.
struct StreamingServicesSettingsActions {
    enum ClearOutcome: Equatable, Sendable { case cleared, failed, unavailable }

    /// Opens a service inside the app (the same route as the dropdown). nil hides the Open button.
    var open: (@MainActor (ProviderID) -> Void)?
    /// Clears the website data of one service. nil means clearing is not wired yet.
    var clearWebsiteData: (@MainActor (ProviderID) async -> ClearOutcome)?
    /// Reloads an open service's page so a changed page option applies now. nil hides the Reload button.
    var reloadService: (@MainActor (ProviderID) -> Void)?
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
        /// What the owner recorded (passed and failed checks, the date); nil when nothing was recorded, so an unchecked service shows no status line.
        let statusLine: String?
        let limitation: String?
        let pinned: Bool
        /// "In top bar" or "Not in top bar": the quiet trailing label of the card.
        let pinLabel: String
        let canMoveLeft: Bool
        let canMoveRight: Bool
        let canOpen: Bool
        /// A recorded note about the service (region, redirects), shown as plain text; nil when there is none.
        let note: String?
        /// Optional page additions this service declares (empty for every service but one).
        let enhancements: [PageEnhancement]
        /// The four separate region lines (preference, network, service, playback) for a service that declares a preference; empty for every other.
        let regionLines: [String]
    }

    private(set) var preferences: ServicePreferences
    var pendingClear: ProviderID?
    private(set) var notice: String?
    /// The page options' toggles and consent step, shared with the first-open prompt through one store.
    let enhancements = EnhancementToggleModel()

    private let registry: ProviderRegistry
    private let defaults: UserDefaults
    var actions: StreamingServicesSettingsActions
    private let available: [ProviderID]

    private let diagnostics: ServiceDiagnostics
    /// The Mac's own locale. Held only so a test can prove it is never consulted for a service's region: a service's preference comes from its definition.
    let systemLocale: LocaleProvider

    init(registry: ProviderRegistry = .standard, defaults: UserDefaults = .standard, actions: StreamingServicesSettingsActions = .unwired, diagnostics: ServiceDiagnostics = .shared,
         systemLocale: @escaping LocaleProvider = { .current }) {
        self.registry = registry; self.defaults = defaults; self.actions = actions; self.diagnostics = diagnostics; self.systemLocale = systemLocale
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
                   statusLine: Self.statusLine(d.capabilities.compatibility),
                   limitation: d.authentication == .signedOutOnly ? "Google sign-in is not supported in this view, so this service is used signed out." : nil,
                   pinned: index != nil, pinLabel: index != nil ? "In top bar" : "Not in top bar", canMoveLeft: (index ?? 0) > 0, canMoveRight: index.map { $0 < preferences.pinned.count - 1 } ?? false,
                   canOpen: d.presentation == .embedded && actions.open != nil, note: d.releaseNote.map { Localized.string($0) },
                   enhancements: PageEnhancement.allCases.filter(d.pageEnhancements.contains), regionLines: RegionStatus.of(d)?.lines ?? [])
    }

    // MARK: recent blocked hosts and errors (in memory only)

    /// "host: blocked" or "host: error -1009" lines, newest last. Hosts and error numbers only.
    func diagnosticLines(_ id: ProviderID) -> [String] {
        diagnostics.entries(for: id).map { e in
            switch e.kind {
            case .blocked: e.host + ": " + Localized.string("blocked")
            case .failure(let code): e.host + ": " + Localized.string("error %lld", Int64(code))
            case .subframeBlocked: e.host + ": " + Localized.string("embedded frame blocked")
            case .popupRefused: e.host + ": " + Localized.string("new window refused")
            case .processTerminated: e.host + ": " + Localized.string("page process ended")
            case .httpStatus(let s): e.host + ": " + Localized.string("HTTP %lld", Int64(s))
            case .redirectHop(let i): e.host + ": " + Localized.string("redirect hop %lld", Int64(i + 1))
            case .providerRegionalPage: e.host + ": " + Localized.string("provider regional page reached")
            }
        }
    }
    /// "Redirect chain: a -> b" for the latest chain, host names only; nil when none was seen.
    func redirectChainLine(_ id: ProviderID) -> String? {
        let chain = diagnostics.lastRedirectChain(for: id)
        return chain.count > 1 ? Localized.string("Redirect chain: %@", chain.joined(separator: " -> ")) : nil
    }
    func diagnosticHostList(_ id: ProviderID) -> String { diagnostics.hostList(for: id) }
    func copyDiagnosticHosts(_ id: ProviderID) {
        let text = diagnostics.hostList(for: id)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func clearDiagnostics(_ id: ProviderID) { diagnostics.clear(id) }

    nonisolated static func badge(_ a: ServiceAvailability) -> String {
        switch a {
        case .available: "Available"
        case .unverified: "Unverified"
        case .disabled: "Disabled"
        case .registered: "Not offered"
        }
    }

    /// What was RECORDED for a service, never a claim: "Site loads · Sign-in works · Video plays — checked by you on 22 Nov 2026", then any failed check
    /// in plain words ("Sign-in failed"). Unchecked and not-applicable checks are left out; nil when nothing was passed or failed.
    nonisolated static func statusLine(_ c: CompatibilityResult) -> String? {
        let passed = CompatibilityResult.Check.allCases.filter { c.outcome($0) == .passed }.map { Localized.string(passedWords($0)) }
        let failed = CompatibilityResult.Check.allCases.filter { c.outcome($0) == .failed }.map { Localized.string(failedWords($0)) }
        var parts: [String] = []
        if !passed.isEmpty {
            var text = passed.joined(separator: " · ") + " — "
            if let day = c.checkedOn { text += Localized.string("checked by you on %@", dayText(day)) } else { text += Localized.string("checked by you") }
            parts.append(text)
        }
        parts.append(contentsOf: failed)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The recorded day, in the person's language and always the same calendar day the owner entered (it is stored at midnight UTC).
    nonisolated static func dayText(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateStyle = .medium; f.timeStyle = .none; f.locale = .current
        return f.string(from: d)
    }

    nonisolated static func passedWords(_ c: CompatibilityResult.Check) -> String {
        switch c {
        case .siteLoads: "Site loads"
        case .signInPageRenders: "Sign-in page loads"
        case .signInCompletes: "Sign-in works"
        case .catalog: "Catalog browses"
        case .video: "Video plays"
        case .audio: "Audio plays"
        case .fullscreen: "Full screen works"
        case .sessionPersistsAfterRestart: "Stays signed in after a restart"
        case .switchingStopsAudio: "Audio stops when you switch"
        case .errorScreenRetryAndReturn: "Error screen recovers"
        }
    }
    nonisolated static func failedWords(_ c: CompatibilityResult.Check) -> String {
        switch c {
        case .siteLoads: "Site did not load"
        case .signInPageRenders: "Sign-in page failed"
        case .signInCompletes: "Sign-in failed"
        case .catalog: "Catalog failed"
        case .video: "Video failed"
        case .audio: "Audio failed"
        case .fullscreen: "Full screen failed"
        case .sessionPersistsAfterRestart: "Sign-in was lost after a restart"
        case .switchingStopsAudio: "Audio kept playing after a switch"
        case .errorScreenRetryAndReturn: "Error screen did not recover"
        }
    }

    /// The single honest note about distribution permission, shown once at the top of the section instead of on every card. nil when every listed
    /// service is confirmed.
    var distributionNote: String? { Self.distributionNote(for: registry.listed(on: .macOS).map(\.distributionAuthorization)) }

    nonisolated static func distributionNote(for all: [DistributionAuthorization]) -> String? {
        let open = all.filter { $0 != .confirmed }.count
        if open == 0 || all.isEmpty { return nil }
        return open == all.count ? Localized.string("Distribution permission: unresolved for every service")
                                 : Localized.string("Distribution permission: unresolved for %lld services", Int64(open))
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

    /// Shows the first-open prompt for this service again (the only way it comes back).
    func resetPrompt(_ id: ProviderID) { enhancements.store.resetPrompt(for: id) }
    func reloadService(_ id: ProviderID) { actions.reloadService?(id); enhancements.clearReloadHint() }

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
    func confirmationTitle(_ id: ProviderID) -> String { ServiceDataClearing.confirmationTitle(name(of: id)) }
    func confirmationMessage(_ id: ProviderID) -> String { ServiceDataClearing.confirmationMessage(name(of: id)) }

    /// Runs only after the explicit confirmation, and only for the service that was confirmed.
    func confirmClear() async {
        guard let id = pendingClear else { return }
        pendingClear = nil
        let n = name(of: id)
        guard let clear = actions.clearWebsiteData else { notice = ServiceDataClearing.resultMessage(.unavailable, name: n); return }
        switch await clear(id) {
        case .cleared: notice = ServiceDataClearing.resultMessage(.cleared, name: n)
        case .failed: notice = ServiceDataClearing.resultMessage(.failed, name: n)
        case .unavailable: notice = ServiceDataClearing.resultMessage(.unavailable, name: n)
        }
    }

    func dismissNotice() { notice = nil }
}

/// Settings > Privacy > Streaming Services. One list over the shared pin preferences; no second dropdown. Each service is one themed card.
struct StreamingServicesSettingsSection: View {
    @Environment(\.streamingServicesActions) private var actions
    @State private var model = StreamingServicesSettingsModel()

    var body: some View {
        SettingsGroup(title: "Streaming Services", footer: "Pin services to the top bar and put them in order. Unpinning only hides a service from the bar; it never signs you out or clears anything. Each service keeps its own sign-in on this Mac.") {
            VStack(alignment: .leading, spacing: 16) {
                if let note = model.distributionNote {
                    Text(verbatim: note).font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.rows) { row in
                    ServiceSettingsRow(row: row, model: model, enhancements: model.enhancements, canClear: model.canClear)
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
        .enhancementConsentAlert(model.enhancements)
        .alert(Text(verbatim: model.pendingClear.map(model.confirmationTitle) ?? ""), isPresented: Binding(get: { model.pendingClear != nil }, set: { if !$0 { model.cancelClear() } })) {
            Button("Cancel", role: .cancel) { model.cancelClear() }.atlas("control.settings.servicesClear")
            Button("Clear Data", role: .destructive) { Task { await model.confirmClear() } }.atlas("control.settings.servicesClear")
        } message: { Text(verbatim: model.pendingClear.map(model.confirmationMessage) ?? "") }
    }
}

/// A compact quiet button for a service card: one height, one radius, a wash on hover, theme colours only. `destructive` tints the label.
private struct ServiceCardButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(Typography.rowMedium).lineLimit(1)
            .foregroundStyle(destructive ? ColorTokens.danger : ColorTokens.textPrimary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(shape.fill(ColorTokens.textPrimary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(destructive ? ColorTokens.danger.opacity(0.35) : ColorTokens.line, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

struct ServiceSettingsRow: View {
    let row: StreamingServicesSettingsModel.Row
    let model: StreamingServicesSettingsModel
    @Bindable var enhancements: EnhancementToggleModel
    let canClear: Bool

    /// Optional page additions (off by default; each asks first). The same store as the first-open prompt.
    private var pageOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page options".loc).font(Typography.eyebrow).textCase(.uppercase).tracking(0.9).foregroundStyle(ColorTokens.textTertiary)
            EnhancementToggleGroup(enhancements: row.enhancements, model: enhancements)
            if enhancements.reloadHint {
                HStack {
                    Text(Localized.string("Changes apply the next time %@ loads.", row.name)).font(.callout).foregroundStyle(.secondary)
                    if model.actions.reloadService != nil { Button("Reload") { model.reloadService(row.id) }.atlas("control.settings.enhancementReload") }
                }
            }
            Button("Show the First-Open Prompt Again") { model.resetPrompt(row.id) }.buttonStyle(.link).atlas("control.settings.enhancementPromptReset")
        }
        .padding(.top, 4)
    }

    /// Name, badge and (when there is room) where the service sits. On a narrow window the position label is dropped: the Pin / Unpin button says the same.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showPin: true)
            headerRow(showPin: false)
        }
    }

    private func headerRow(showPin: Bool) -> some View {
        HStack(spacing: 12) {
            ServiceGlyph(id: row.id, size: 32)
            Text(verbatim: row.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
            Text(row.badge.loc).font(Typography.micro).lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(badgeColor.opacity(0.18))).foregroundStyle(badgeColor)
                .accessibilityLabel(Text(verbatim: Localized.string(row.badge)))
            Spacer(minLength: 8)
            if showPin { Text(row.pinLabel.loc).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1).fixedSize() }
        }
    }

    private var pinButton: some View {
        Button { model.togglePin(row.id) } label: { Label(row.pinned ? "Unpin from Top Bar" : "Pin to Top Bar", systemImage: row.pinned ? "pin.slash" : "pin") }
            .buttonStyle(ServiceCardButtonStyle())
            .accessibilityLabel(Text(verbatim: Localized.string(row.pinned ? "Unpin %@ from the top bar" : "Pin %@ to the top bar", row.name))).atlas("control.settings.servicesPin")
    }

    /// Left and right in one small segmented control; each end is disabled at the end of the list.
    private var moveControl: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 0) {
            Button { model.moveLeft(row.id) } label: { Image(systemName: "arrow.left").frame(width: 32, height: 28) }.disabled(!row.canMoveLeft)
                .help(Text("Move Left")).accessibilityLabel(Text(verbatim: Localized.string("Move %@ left", row.name))).atlas("control.settings.servicesMove")
            Rectangle().fill(ColorTokens.line).frame(width: 0.5, height: 16)
            Button { model.moveRight(row.id) } label: { Image(systemName: "arrow.right").frame(width: 32, height: 28) }.disabled(!row.canMoveRight)
                .help(Text("Move Right")).accessibilityLabel(Text(verbatim: Localized.string("Move %@ right", row.name))).atlas("control.settings.servicesMove")
        }
        .buttonStyle(.plain).font(Typography.rowMedium).foregroundStyle(ColorTokens.textPrimary)
        .background(shape.fill(ColorTokens.textPrimary.opacity(0.04)))
        .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.5))
        .clipShape(shape)
    }

    private var openButton: some View {
        Button { model.open(row.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }.disabled(!row.canOpen)
            .buttonStyle(ServiceCardButtonStyle())
            .accessibilityLabel(Text(verbatim: Localized.string("Open %@", row.name))).atlas("control.settings.servicesOpen")
    }

    private var clearButton: some View {
        Button(role: .destructive) { model.requestClear(row.id) } label: { Label("Clear Data…", systemImage: "trash") }.disabled(!canClear)
            .buttonStyle(ServiceCardButtonStyle(destructive: true))
            .accessibilityLabel(Text(verbatim: Localized.string("Clear data for %@", row.name))).atlas("control.settings.servicesClear")
    }

    /// One compact row, left-aligned: Pin, Move, Open, Clear Data. When the card is too narrow it wraps into two aligned rows, never full-width bars.
    private var actionRow: some View {
        let embedded = row.availability.presentation == .embedded
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                pinButton
                if row.pinned { moveControl }
                if embedded { openButton; clearButton }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { pinButton; if row.pinned { moveControl } }
                if embedded { HStack(spacing: 8) { openButton; clearButton } }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 4) {
                if let status = row.statusLine { Text(verbatim: status).font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
                if let note = row.note { Text(verbatim: note).font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
                if !row.regionLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(row.regionLines.enumerated()), id: \.offset) { _, l in Text(verbatim: l).font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    }.accessibilityElement(children: .combine)
                }
                if let limitation = row.limitation { Text(limitation.loc).font(Typography.row).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            if !row.enhancements.isEmpty && !enhancements.isRestricted { pageOptions }
            actionRow
            if row.availability.presentation == .embedded { diagnostics }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PremiumCardSurface(radius: LayoutTokens.radiusPanel, elevated: false))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var diagnostics: some View {
        let lines = model.diagnosticLines(row.id)
        DisclosureGroup("Recent blocked hosts and errors") {
            VStack(alignment: .leading, spacing: 6) {
                if let chain = model.redirectChainLine(row.id) { Text(verbatim: chain).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                if lines.isEmpty { Text("Nothing recorded.").font(.callout).foregroundStyle(.secondary) }
                else { ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(verbatim: l).font(.system(.callout, design: .monospaced)).textSelection(.enabled) } }
                Text("Shown only on this Mac; hosts and error codes only; cleared when you quit.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SettingsActions {
                    Button { model.copyDiagnosticHosts(row.id) } label: { Label("Copy Hosts", systemImage: "doc.on.doc") }.disabled(lines.isEmpty)
                        .accessibilityLabel(Text(verbatim: Localized.string("Copy hosts for %@", row.name))).atlas("control.settings.servicesDiagnosticsCopy")
                    Button { model.clearDiagnostics(row.id) } label: { Label("Clear", systemImage: "xmark.circle") }.disabled(lines.isEmpty)
                        .accessibilityLabel(Text(verbatim: Localized.string("Clear recent hosts and errors for %@", row.name))).atlas("control.settings.servicesDiagnosticsClear")
                }
            }.padding(.top, 4)
        }.font(Typography.row)
    }

    private var badgeColor: Color {
        switch row.availability {
        case .available: .green
        case .unverified: .orange
        default: .secondary
        }
    }
}
