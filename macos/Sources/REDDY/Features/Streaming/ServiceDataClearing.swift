import AppKit

/// Clearing one service's data. One confirmation and one result wording for every route (Settings, the top-bar pill menu, the Services menu):
/// the confirmation names the service and says it signs the person out; only that service's store is cleared and only its own live web view is
/// touched (the model releases it first and reloads home when it was showing).
@MainActor enum ServiceDataClearing {
    enum Outcome: Equatable { case cleared, failed, unavailable }

    static func confirmationTitle(_ name: String) -> String { Localized.string("Clear data for %@?", name) }
    static func confirmationMessage(_ name: String) -> String {
        Localized.string("This signs you out of %@ and removes its saved data from this Mac. Your other services stay signed in.", name)
    }
    /// The one line shown after a clear (Settings shows it in the section; the pill menu shows it in an alert).
    static func resultMessage(_ outcome: Outcome, name: String) -> String {
        switch outcome {
        case .cleared: Localized.string("Data cleared for %@.", name)
        case .failed: Localized.string("Could not clear all data for %@.", name)
        case .unavailable: Localized.string("Clearing data is not available yet.")
        }
    }

    /// Asks first, clears exactly this service, then reports. Returns nil when the person cancelled. `ask` and `report` default to system alerts and
    /// are replaced in tests.
    @discardableResult static func confirmAndClear(_ id: ProviderID, name: String, hosts: ServiceHostRegistry,
                                                   ask: @MainActor (String, String) -> Bool = ServiceDataClearing.askWithAlert,
                                                   report: @MainActor (String) -> Void = ServiceDataClearing.reportWithAlert) async -> Outcome? {
        guard ask(confirmationTitle(name), confirmationMessage(name)) else { return nil }
        let outcome = await clear(id, hosts: hosts)
        report(resultMessage(outcome, name: name))
        return outcome
    }

    static func askWithAlert(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: Localized.string("Clear Data")); alert.addButton(withTitle: Localized.string("Cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func reportWithAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: Localized.string("OK"))
        alert.runModal()
    }

    /// Cleared only when the store reports nothing left; otherwise the person is told it did not all go.
    static func outcome(of report: SessionClearing.ClearReport) -> Outcome { report.remainingRecordCount == 0 ? .cleared : .failed }

    /// No confirmation here: the caller (Settings) has already asked. Clears exactly this service.
    static func clear(_ id: ProviderID, hosts: ServiceHostRegistry) async -> Outcome {
        guard let model = hosts.model(for: id) else { return .unavailable }
        return outcome(of: await model.clearServiceDataReporting())
    }
}

/// What the Settings scene needs from the running app: the same open route as the dropdown, and per-service clearing without a second prompt
/// (Settings asks first).
@MainActor enum ServiceHubWiring {
    static func settingsActions(_ coordinator: AppCoordinator) -> StreamingServicesSettingsActions {
        StreamingServicesSettingsActions(
            open: { id in coordinator.services.select(id) },
            clearWebsiteData: { id in
                switch await ServiceDataClearing.clear(id, hosts: coordinator.hosts) { case .cleared: .cleared; case .failed: .failed; case .unavailable: .unavailable }
            },
            reloadService: { id in coordinator.hosts.model(for: id)?.applyEnhancementChanges() },
            preferencesChanged: { NotificationCenter.default.post(name: StreamingServicesSettingsModel.preferencesDidChange, object: nil) })
    }
}

extension ServiceHubWiring {
    /// Pin state for the menu's Pin/Unpin command: the same saved preferences as the bar and Settings; presentation only.
    static func menuPinning() -> ServiceMenuPinning {
        ServiceMenuPinning(
            isPinned: { ServicePreferences.load().isPinned($0) },
            toggle: { id in
                var p = ServicePreferences.load()
                if p.isPinned(id) { p.unpin(id) } else { p.pin(id) }
                p.save(); NotificationCenter.default.post(name: StreamingServicesSettingsModel.preferencesDidChange, object: nil)
            })
    }
}
