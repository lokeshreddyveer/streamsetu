import AppKit

/// Clearing one service's website data. The confirmation names the service and says what happens; only that service's store is cleared and
/// only its live web view is touched (the model releases it first and reloads home when it was showing).
@MainActor enum ServiceDataClearing {
    enum Outcome: Equatable { case cleared, failed, unavailable }

    /// Asks first (the menu route). Returns whether everything was cleared.
    @discardableResult static func confirmAndClear(_ def: ProviderDefinition, model: ServiceWebModel) async -> Bool {
        let alert = NSAlert()
        alert.messageText = Localized.string("Clear %@ website data?", def.displayName)
        alert.informativeText = Localized.string("This signs you out of %@ in StreamSetu and removes its cookies and saved site data. Your playlists and settings are not touched.", def.displayName)
        alert.addButton(withTitle: Localized.string("Clear Data")); alert.addButton(withTitle: Localized.string("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return await model.clearServiceDataReporting().remainingRecordCount == 0
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
