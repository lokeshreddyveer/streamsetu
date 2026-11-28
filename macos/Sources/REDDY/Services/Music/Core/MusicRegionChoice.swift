import Foundation
import Observation

/// The country whose charts Music shows: one value for the whole app. Listen Now and Explore both read it, so choosing a country on either changes
/// both, and it is saved where `MusicDiscoveryRegion.current()` reads it.
@MainActor @Observable final class MusicRegionChoice {
    static let shared = MusicRegionChoice()

    private(set) var region: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locale: Locale

    init(defaults: UserDefaults = .standard, locale: Locale = .current) {
        self.defaults = defaults; self.locale = locale
        region = MusicDiscoveryRegion.current(defaults: defaults, locale: locale)
    }

    /// Chooses `code` when it is a country the charts are offered for; anything else is ignored.
    @discardableResult func set(_ code: String) -> Bool {
        let c = code.lowercased()
        guard c != region, c.isEmpty || MusicDiscoveryRegion.supported.contains(where: { $0.code == c }) else { return false }
        region = c
        defaults.set(c, forKey: MusicDiscoveryRegion.defaultsKey)
        return true
    }

    /// Re-reads the saved value (after a privacy wipe or a settings reset).
    func reload() { region = MusicDiscoveryRegion.current(defaults: defaults, locale: locale) }
}
