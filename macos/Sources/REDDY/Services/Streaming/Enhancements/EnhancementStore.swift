import Foundation
import Observation

/// The one place the choices are kept: whether each enhancement is on, the record of the person's agreement (version and date), and whether the
/// first-open prompt was answered. Settings and the prompt both use this, so they cannot disagree. Everything defaults to off.
@MainActor @Observable
final class EnhancementStore {
    static let shared = EnhancementStore()

    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped on every change, so views and web models that read it update.
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isEnabled(_ e: PageEnhancement) -> Bool { _ = revision; return defaults.bool(forKey: e.enabledKey) }

    /// The agreement on record: its version and date, nil when there is none (or it cannot be read).
    func consent(_ e: PageEnhancement) -> (version: Int, date: Date)? {
        _ = revision
        guard let raw = defaults.string(forKey: e.consentKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let v = Int(parts[0]), let t = Double(parts[1]) else { return nil }
        return (v, Date(timeIntervalSince1970: t))
    }

    /// An agreement to the current wording exists.
    func hasConsent(_ e: PageEnhancement) -> Bool { (consent(e)?.version ?? 0) >= e.consentVersion }

    /// On AND agreed to. Only this ever lets anything run or be sent.
    func isActive(_ e: PageEnhancement) -> Bool { isEnabled(e) && hasConsent(e) }

    /// Records the agreement (version and date) and turns it on. Called only after the person confirmed the explanation.
    func grant(_ e: PageEnhancement, now: Date = Date()) {
        defaults.set("\(e.consentVersion)|\(now.timeIntervalSince1970)", forKey: e.consentKey)
        defaults.set(true, forKey: e.enabledKey)
        revision += 1
    }

    /// Turns it off. The record of the agreement stays, so it can be turned on again after a fresh confirmation (the toggle always asks again).
    func disable(_ e: PageEnhancement) {
        defaults.set(false, forKey: e.enabledKey)
        revision += 1
    }

    #if DEBUG
    /// Test only: the "enabled" preference alone, as if it had been edited by hand without ever agreeing.
    func setEnabledOnlyForTest(_ e: PageEnhancement) { defaults.set(true, forKey: e.enabledKey); revision += 1 }
    #endif

    // MARK: first-open prompt

    /// When the prompt for a service was answered or dismissed; nil while it has not been.
    func promptAnswered(for id: ProviderID) -> Date? {
        _ = revision
        return defaults.object(forKey: PageEnhancement.prompt(key: id)) as? Date
    }
    func recordPromptAnswered(for id: ProviderID, now: Date = Date()) { defaults.set(now, forKey: PageEnhancement.prompt(key: id)); revision += 1 }
    func resetPrompt(for id: ProviderID) { defaults.removeObject(forKey: PageEnhancement.prompt(key: id)); revision += 1 }
}

/// What the page additions need from the rest of the app, with every default safe: nothing active, nothing sent.
@MainActor
final class EnhancementRuntime {
    static let shared = EnhancementRuntime()

    var store: EnhancementStore
    var client: SponsorSegmentsFetching
    /// True while a kids profile is in use or the app is locked: nothing is installed, asked or sent then. Set by the app at start-up.
    var isRestricted: () -> Bool = { true }

    init(store: EnhancementStore = .shared, client: SponsorSegmentsFetching = SponsorBlockClient()) { self.store = store; self.client = client }

    /// What may run for a service right now: declared by its definition AND on AND agreed to AND not restricted, and only for an https service address.
    func active(for definition: ProviderDefinition) -> Set<PageEnhancement> {
        guard !definition.pageEnhancements.isEmpty, !isRestricted(), definition.homeURL.scheme == "https",
              let host = definition.homeURL.host?.lowercased(), definition.urlPolicy.isAllowedHost(host) else { return [] }
        return definition.pageEnhancements.filter(store.isActive)
    }

    /// Whether the first-open prompt should be shown for this service now.
    func shouldPrompt(for definition: ProviderDefinition) -> Bool {
        !definition.pageEnhancements.isEmpty && !isRestricted() && definition.homeURL.scheme == "https"
            && store.promptAnswered(for: definition.id) == nil && !definition.pageEnhancements.contains(where: store.isActive)
            && !definition.pageEnhancements.contains(where: store.hasConsent)
    }
}
