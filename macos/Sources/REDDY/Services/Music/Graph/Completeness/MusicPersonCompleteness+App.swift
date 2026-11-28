import Foundation

extension MusicEntityRuntime {
    /// Builds the completeness pass over the metadata layer's resolver, governed transport and gate, and hands it to the model center. Everything is lazy:
    /// nothing runs until a page takes the entity, and every request is the same gated, paced, cached kind the other metadata sources make.
    func installCompleteness(resolver: MusicEntityResolver, transport: any MusicMetadataTransport, gate: any MusicEnrichmentGating, catalogue: (any MusicPersonCatalogueFetching)?) {
        let pass = MusicPersonCompleteness(resolver: resolver, transport: transport, gate: gate, catalogue: catalogue)
        let store = self.store
        let coordinator = MusicEntityCompletenessCoordinator(pass: pass) { ids in store.notifyChanged(ids) }
        install(completeness: coordinator)
    }
}

extension MusicPersonCatalogueFetcher {
    /// The app's enabled metadata providers, only while Music is allowed, online and unlocked.
    @MainActor static func app(hub: MusicHub) -> MusicPersonCatalogueFetcher {
        let flags = MusicEnrichmentFlags.shared
        return MusicPersonCatalogueFetcher(providers: {
            guard flags.consentGiven, !flags.kidsOrLocked, !flags.offline else { return [] }
            return await MainActor.run { hub.registry.metadata }
        })
    }
}
