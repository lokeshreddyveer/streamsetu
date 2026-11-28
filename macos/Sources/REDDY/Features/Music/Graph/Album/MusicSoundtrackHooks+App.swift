import Foundation

// The page's two doors to the rest of the app, as hooks the builders call: enrichment through the shared entity store, and a bounded provider search
// for a film's soundtrack. Both are consent-gated (music consent, no Kids profile or app lock, online) and run off the main actor; neither is ever on
// the playback path.

extension MusicSoundtrackHooks {
    @MainActor
    static func app(hub: MusicHub) -> MusicSoundtrackHooks {
        let entityStore = MusicEntityRuntime.shared.store
        let flags = MusicEnrichmentFlags.shared
        return MusicSoundtrackHooks(
            enrich: { id in
                guard flags.consentGiven, !flags.kidsOrLocked, !flags.offline else { return }
                // single-flight on the store: a second page asking for the same entity joins the first one's task
                let task = await MainActor.run { entityStore.enrich(id) }
                await task.value
            },
            providerAlbums: { film in
                guard flags.consentGiven, !flags.kidsOrLocked, !flags.offline else { return [] }
                guard let provider = await MainActor.run(body: { hub.registry.activeMetadata }) else { return [] }
                let query = film.title + " soundtrack"
                guard let page = try? await provider.searchAlbums(query, page: nil) else { return [] }
                return page.items.prefix(12).map { a in
                    MusicSoundtrackProviderAlbum(id: .provisional(kind: .release, providerUID: a.uid), title: a.title, year: MusicGraphAdapters.year(a.releaseDate),
                                                 imageRef: a.thumbnails.best(minSide: 300), artistLine: a.artists.map(\.name).joined(separator: ", "), providerUID: a.uid)
                }
            },
            persistInferred: { album, film in
                guard !album.providerUID.isEmpty else { return nil }
                let graph = MusicGraphRuntime.shared.store
                var draft = MusicEntityDraft(kind: .release, name: album.title, subkind: MusicAlbumSubkind.soundtrack.rawValue, year: album.year, imageRef: album.imageRef,
                                             externalIDs: [ExternalID(.provider, album.providerUID)], provisional: true)
                draft.attrs["filmHint"] = film.title
                guard let id = try? await graph.upsert(draft).id else { return nil }
                // An INFERRED claim from the matcher: it can never be verified by itself, and the page tags it "inferred film link".
                // Both years known and agreeing is real evidence (0.7); a match on the title alone stays under the 0.6 a film link needs, so it is never shown as the film's soundtrack.
                let yearsKnown = album.year != nil && film.year != nil
                let confidence: Float = yearsKnown ? 0.7 : 0.5
                let claim = MusicProvenance(source: .matcher, license: .derived, score: confidence, matcherVersion: 1, evidence: [yearsKnown ? "title+year" : "title"])
                _ = try? await graph.addEdge(MusicEdge(subject: id, predicate: .soundtrackOf, object: film.id, confidence: confidence, status: .inferred), provenance: claim)
                await MainActor.run { entityStore.notifyChanged([id, film.id]) }
                return id
            })
    }
}
