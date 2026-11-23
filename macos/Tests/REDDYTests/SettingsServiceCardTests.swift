import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// The Streaming Services cards in Settings and the top-bar pill menu: the status line is built only from what was recorded, the distribution
/// note appears once, the pill menu lists exactly its items per state, and Clear Data asks first and clears only the chosen service.
@Suite("Settings: service cards and pill menu") @MainActor struct SettingsServiceCardTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "reddy-svc-cards-\(UUID().uuidString)")! }

    // MARK: status line from CompatibilityResult

    @Test func passedChecksAreListedWithTheDay() throws {
        let c = CompatibilityResult.ownerChecked(on: "2026-11-22", build: "Release", passed: [.siteLoads, .signInCompletes, .video], note: "x")
        let line = try #require(StreamingServicesSettingsModel.statusLine(c))
        #expect(line.hasPrefix("Site loads · Sign-in works · Video plays — checked by you on "))
        #expect(line.contains("2026") && line.contains("22"))
        #expect(!line.contains("manual check"))
    }

    @Test func failedChecksAreShownPlainAndUncheckedOnesAreOmitted() throws {
        let c = CompatibilityResult.ownerChecked(on: "2026-11-22", build: "Release", passed: [.siteLoads], failed: [.signInCompletes], notApplicable: [.fullscreen], note: "x")
        let line = try #require(StreamingServicesSettingsModel.statusLine(c))
        #expect(line.contains("Site loads") && line.contains("Sign-in failed"))
        #expect(!line.contains("Full screen") && !line.contains("Video") && !line.contains("Needs a manual check"))
        let onlyFailed = CompatibilityResult.ownerChecked(on: "2026-11-22", build: "Release", passed: [], failed: [.signInCompletes], note: "x")
        #expect(StreamingServicesSettingsModel.statusLine(onlyFailed) == "Sign-in failed")
    }

    @Test func nothingRecordedMeansNoStatusLine() {
        #expect(StreamingServicesSettingsModel.statusLine(.unchecked) == nil)
        let allNotApplicable = CompatibilityResult.ownerChecked(on: "2026-11-22", build: "Release", passed: [], notApplicable: [.audio], note: "x")
        #expect(StreamingServicesSettingsModel.statusLine(allNotApplicable) == nil)
    }

    @Test func everyRowShowsRecordedFactsNeverTheOldNoise() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        for r in m.rows {
            let line = r.statusLine ?? ""
            #expect(!line.contains("Needs a manual check") && !line.contains("Enabled for testing") && !line.contains("Distribution"))
        }
        #expect(m.rows.first { $0.id == .primevideo }?.statusLine?.contains("checked by you") == true, "an owner-recorded service shows its recorded facts")
        #expect(m.rows.first { $0.id == .netflix }?.statusLine == nil, "Netflix has nothing recorded in the catalog, so no line")
        #expect(m.rows.first { $0.id == .netflix }?.pinLabel == "In top bar")
        #expect(m.rows.first { $0.id == .hulu }?.pinLabel == "Not in top bar")
        #expect(m.rows.first { $0.id == .jiohotstar } == nil, "on hold: no row")
    }

    // MARK: pill menu

    private func nav(pinned: [ProviderID], active: ProviderID? = nil) -> ServicesNavigationBinding {
        var n = ServicesNavigationBinding(); n.pinned = pinned; n.active = active
        n.canReload = { $0 == active }
        n.canClearData = { _ in true }
        return n
    }

    @Test func pinnedPillMenuIsReloadUnpinMovesAndClearData() {
        let items = ServicePillItem.items(for: .hulu, nav: nav(pinned: [.netflix, .hulu, .peacock], active: .hulu))
        #expect(items.map(\.title) == ["Reload", "Unpin from Top Bar", "Move Left", "Move Right", "Clear Data…"])
        #expect(items.map(\.enabled) == [true, true, true, true, true])
        #expect(!items.contains { $0.title.hasPrefix("Open") })
    }

    @Test func pillMenuDisablesWhatDoesNotApply() {
        let first = ServicePillItem.items(for: .netflix, nav: nav(pinned: [.netflix, .hulu]))
        #expect(first.first { $0.kind == .moveLeft }?.enabled == false && first.first { $0.kind == .moveRight }?.enabled == true)
        #expect(first.first { $0.kind == .reload }?.enabled == false)               // not the open service
        let last = ServicePillItem.items(for: .hulu, nav: nav(pinned: [.netflix, .hulu]))
        #expect(last.first { $0.kind == .moveRight }?.enabled == false)
    }

    @Test func unpinnedPillMenuHasNoMovesAndNoOpen() {
        let items = ServicePillItem.items(for: .peacock, nav: nav(pinned: [.netflix]))
        #expect(items.map(\.title) == ["Reload", "Pin to Top Bar", "Clear Data…"])
        var off = nav(pinned: []); off.canClearData = { _ in false }
        #expect(ServicePillItem.items(for: .peacock, nav: off).last?.enabled == false)
    }

    @Test func clearDataItemUsesItsOwnAtlasId() {
        #expect(ServicePillItem(kind: .clearData, enabled: true).atlas == "control.services.clearData")
    }

    // MARK: Clear Data confirmation and result

    @Test func cancellingTheConfirmationClearsNothingAndSaysNothing() async {
        var asked: [String] = [], reported: [String] = []
        let hosts = ServiceHostRegistry(makeModel: { _ in fatalError("a cancelled clear must not touch any service") })
        let outcome = await ServiceDataClearing.confirmAndClear(.hulu, name: "Hulu", hosts: hosts, ask: { t, _ in asked.append(t); return false }, report: { reported.append($0) })
        #expect(outcome == nil && reported.isEmpty)
        #expect(asked == ["Clear data for Hulu?"])
    }

    @Test func theConfirmationNamesTheServiceAndTheResultIsReported() async {
        #expect(ServiceDataClearing.confirmationMessage("Disney+").contains("Disney+") && ServiceDataClearing.confirmationMessage("Disney+").contains("signs you out"))
        #expect(!ServiceDataClearing.confirmationTitle("Hulu").contains("ebsite"))
        var message: String?
        let hosts = ServiceHostRegistry(makeModel: { _ in fatalError("an unknown service has no model") })
        let outcome = await ServiceDataClearing.confirmAndClear(ProviderID(unchecked: "nonexistent"), name: "Nowhere", hosts: hosts, ask: { _, _ in true }, report: { message = $0 })
        #expect(outcome == .unavailable && message == "Clearing data is not available yet.")
        #expect(ServiceDataClearing.resultMessage(.cleared, name: "Hulu") == "Data cleared for Hulu.")
        #expect(ServiceDataClearing.resultMessage(.failed, name: "Hulu") == "Could not clear all data for Hulu.")
    }

    @Test func settingsAndThePillShareTheSameWording() {
        let m = StreamingServicesSettingsModel(defaults: defaults())
        #expect(m.confirmationTitle(.hulu) == ServiceDataClearing.confirmationTitle("Hulu"))
        #expect(m.confirmationMessage(.hulu) == ServiceDataClearing.confirmationMessage("Hulu"))
    }

    // MARK: render (PNGs for a person to look at; runs only when SETTINGS_FIX_SHOTS names a folder)

    private func card(_ base: StreamingServicesSettingsModel.Row, status: String?, pinned: Bool, left: Bool, right: Bool) -> StreamingServicesSettingsModel.Row {
        StreamingServicesSettingsModel.Row(id: base.id, name: base.name, availability: base.availability, badge: base.badge, statusLine: status, limitation: base.limitation,
                                           pinned: pinned, pinLabel: pinned ? "In top bar" : "Not in top bar", canMoveLeft: left, canMoveRight: right, canOpen: true,
                                           note: base.note, enhancements: base.enhancements, regionLines: base.regionLines)
    }

    @Test func renderTheSection() throws {
        guard let dir = ProcessInfo.processInfo.environment["SETTINGS_FIX_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current
        defer { ThemeStore.current = saved }
        let model = StreamingServicesSettingsModel(defaults: defaults(), actions: .init(open: { _ in }, clearWebsiteData: { _ in .cleared }))
        func base(_ id: ProviderID) -> StreamingServicesSettingsModel.Row { model.rows.first { $0.id == id }! }
        let rows = [
            card(base(.netflix), status: "Site loads · Sign-in works · Video plays — checked by you on 22 Nov 2026", pinned: true, left: false, right: true),
            card(base(.youtube), status: "Site loads · Sign-in failed", pinned: true, left: true, right: false),
            card(base(.hulu), status: nil, pinned: false, left: false, right: false),
        ]
        let themes = [AppTheme.allCases.first!, AppTheme.allCases.last!]
        for theme in themes {
            ThemeStore.current = theme
            for (label, width) in [("normal", CGFloat(720)), ("narrow", CGFloat(480))] {
                let view = SettingsGroup(title: "Streaming Services", footer: "Pin services to the top bar and put them in order.") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: model.distributionNote ?? "").font(Typography.row).foregroundStyle(ColorTokens.textSecondary)
                        ForEach(rows) { ServiceSettingsRow(row: $0, model: model, enhancements: model.enhancements, canClear: true) }
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 24)
                .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .background(ColorTokens.background)
                .environment(\.reddyAccent, ColorTokens.accentDefault).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: AnyView(view))
                host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1400))
                let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
                for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                host.layoutSubtreeIfNeeded()
                host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "services-\(theme.rawValue.replacingOccurrences(of: " ", with: "-"))-\(label).png"
                try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                withExtendedLifetime(win) {}
            }
        }
    }
}
