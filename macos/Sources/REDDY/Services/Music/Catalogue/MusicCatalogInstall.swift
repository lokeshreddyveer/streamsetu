import Foundation

extension MusicCatalogRuntime {
    /// Called once by `MusicBuiltIns.register`. Builds the matcher over the registry's enabled audio and catalogue sources.
    @MainActor
    func install(registry: MusicRegistry, library: MusicLibrary?, store: MusicCanonicalStore = .shared, defaults: UserDefaults = .standard) {
        let env = MusicCatalogMatcher.Environment(
            audio: { await MainActor.run { registry.audio } },
            catalogue: { await MainActor.run {
                registry.all.filter { registry.isEnabled($0.id) && $0.capabilities.contains(.catalogue) && $0.capabilities.contains(.search) && !$0.capabilities.contains(.audio) }
                    .compactMap { $0 as? any MusicMetadataProvider }
            } })
        let cc = library.map { l in { @Sendable () async -> String in await MainActor.run { l.settings.countryCode } } }
        configure(matcher: MusicCatalogMatcher(store: store, environment: env), store: store, defaults: defaults,
                  initialCountry: library?.settings.countryCode, country: cc)
    }
}
