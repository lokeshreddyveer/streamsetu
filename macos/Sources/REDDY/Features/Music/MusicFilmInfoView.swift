import SwiftUI

// Film info card of the right panel. The view only reads `MusicFilmInfo`; finding the film is MusicFilmResolver and MusicFilmService.

/// Loads the film for an album or a song, once, and the composers' artist pages.
@MainActor @Observable
final class MusicFilmModel {
    enum State: Equatable { case loading, none, loaded }
    private(set) var state = State.loading
    private(set) var info: MusicFilmInfo?
    private(set) var providerID = ""
    private(set) var composerArtists: [String: MusicArtist] = [:]
    /// The listed singers the album's or song's own credits name with a provider id (never found by searching a name, so a namesake is never opened).
    private(set) var singerArtists: [String: MusicArtist] = [:]
    /// The graph person of each cast member and director, by the film layer's person id (found by TMDB, Wikidata or IMDb id, never by name).
    private(set) var personIDs: [String: MusicEntityID] = [:]

    func load(hub: MusicHub, album: MusicAlbum?, track: MusicTrack?, albumTracks: [MusicTrack], service: MusicFilmService = MusicFilmService()) async {
        let ref = album ?? track.flatMap { t in t.album.map { hub.album(from: $0, providerID: t.providerID) } }
        providerID = ref?.providerID ?? track?.providerID ?? ""
        state = .loading; info = nil; composerArtists = [:]; singerArtists = [:]; personIDs = [:]   // the previous film's card does not stay while the next one loads
        var facts: MusicFilmProviderFacts?
        if let ref, ref.providerID == "jiosaavn" {
            let key = "facts." + ref.uid
            if let cached = service.cache.read(MusicFilmProviderFacts.self, key: key) { facts = cached }
            else { facts = await MusicFilmProviderFactsFetcher.fetch(album: ref); if let facts { service.cache.write(facts, key: key) } }
        }
        if Task.isCancelled { return }   // a cancelled load must not set `.none` over a newer one
        guard let identity = MusicFilmResolver.identify(album: ref, track: track, albumTracks: albumTracks, facts: facts) else { state = .none; info = nil; return }
        let looked = await service.info(for: identity)
        if Task.isCancelled { return }
        guard let found = looked, found.isUseful else { state = .none; info = nil; return }
        info = found; state = .loaded
        await resolvePeople(found.cast.prefix(8) + found.directors.prefix(4) + found.composers.prefix(2))
        await resolveComposers(found.composers.prefix(2).map(\.name), hub: hub, album: ref)
        if Task.isCancelled { return }
        singerArtists = Self.singerLinks(names: Array(found.singers.prefix(4)), credits: (ref?.artists ?? []) + (track?.artists ?? []), providerID: providerID, hub: hub)
    }

    /// Each listed singer that one of the item's own credits names (same name, a usable artist with an id) opens that provider artist; the others stay plain text.
    static func singerLinks(names: [String], credits: [MusicArtistRef], providerID: String, hub: MusicHub) -> [String: MusicArtist] {
        var out: [String: MusicArtist] = [:]
        for n in names {
            if let r = credits.first(where: { !$0.id.isEmpty && MusicCompilationArtist.isUsableArtist($0) && MusicTransliterationKey.similarity($0.name, n) >= 0.9 }) {
                out[n] = hub.artist(from: r, providerID: providerID)
            }
        }
        return out
    }

    private func resolvePeople(_ people: some Sequence<MusicFilmPerson>) async {
        var out: [String: MusicEntityID] = [:]
        for p in people {
            if Task.isCancelled { return }
            if let id = await MusicFilmPageRouting.personID(for: p, store: MusicGraphRuntime.shared.store) { out[p.id] = id }
        }
        if Task.isCancelled { return }
        personIDs = out
    }

    private func resolveComposers(_ names: [String], hub: MusicHub, album: MusicAlbum?) async {
        var out: [String: MusicArtist] = [:]
        for n in names {
            if let a = album, let r = a.artists.first(where: { !$0.id.isEmpty && MusicTransliterationKey.similarity($0.name, n) >= 0.9 }) {
                out[n] = hub.artist(from: r, providerID: a.providerID); continue
            }
            guard let p = hub.registry.metadataProvider(id: providerID) ?? hub.registry.activeMetadata,
                  let page = try? await p.searchArtists(n, page: nil),
                  let best = page.items.first(where: { MusicTransliterationKey.similarity($0.name, n) >= 0.9 }) else { continue }
            out[n] = best
        }
        if Task.isCancelled { return }   // a cancelled earlier load must not overwrite a newer film's composer links
        composerArtists = out
    }
}

/// The film an album or song belongs to: who is in it, who directed it, who scored it. Draws nothing when the item is not a film's soundtrack or
/// no source knows the film. It is the narrow card of the right panel.
struct MusicFilmInfoView: View {
    var album: MusicAlbum?
    var track: MusicTrack?
    var albumTracks: [MusicTrack] = []
    var hub: MusicHub = .shared
    @State private var model = MusicFilmModel()
    @State private var opening = false

    private var taskKey: String { (album?.uid ?? "") + "|" + (track?.uid ?? "") + "|" + (albumTracks.isEmpty ? "0" : "1") }

    var body: some View {
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if model.state == .loaded, let info = model.info {
                compactBody(info)
            }
        }
        .task(id: taskKey) { await model.load(hub: hub, album: album, track: track, albumTracks: albumTracks) }
    }

    @ViewBuilder private func crew(_ info: MusicFilmInfo) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            if !info.directors.isEmpty { directorLine(info) }
            if !info.composers.isEmpty { composerLine(info) }
            if !info.singers.isEmpty { crewLine(Localized.string("Singers"), names: Array(info.singers.prefix(4)), links: true) }
        }
    }

    /// The directors; each one the graph knows by id opens their page on the director role, the others stay plain text.
    private func directorLine(_ info: MusicFilmInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
            Text(verbatim: Localized.string("Directed by")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            ForEach(Array(info.directors.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 0) {
                    if let id = model.personIDs[d.id] {
                        MusicInlineLink(title: d.name, font: Typography.body, label: Localized.string("Open director %1$@", d.name)) { hub.open(id, role: .director) }
                            .atlas("control.music.filmInfoDirector")
                    } else {
                        Text(verbatim: d.name).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    }
                    if i < info.directors.count - 1 { Text(verbatim: ",").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                }
            }
        }
    }

    /// The composers: one the graph knows by id opens their person page on the composer role; else the provider's artist page when it found one.
    private func composerLine(_ info: MusicFilmInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
            Text(verbatim: Localized.string("Music by")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            ForEach(Array(info.composers.enumerated()), id: \.offset) { i, c in
                HStack(spacing: 0) {
                    if let id = model.personIDs[c.id] {
                        MusicInlineLink(title: c.name, font: Typography.body, label: Localized.string("Open artist %1$@", c.name)) { hub.open(id, role: .composer) }
                            .atlas("control.music.filmInfoComposer")
                    } else if let a = model.composerArtists[c.name] {
                        MusicInlineLink(title: c.name, font: Typography.body, label: Localized.string("Open artist %1$@", c.name)) { hub.openArtist(a, role: .composer) }
                            .atlas("control.music.filmInfoComposer")
                    } else {
                        Text(verbatim: c.name).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    }
                    if i < info.composers.count - 1 { Text(verbatim: ",").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                }
            }
        }
    }

    private func crewLine(_ label: String, names: [String], links: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
            Text(verbatim: label).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 0) {
                    if links, let a = model.singerArtists[n] {
                        MusicInlineLink(title: n, font: Typography.body, label: Localized.string("Open artist %1$@", n)) { hub.openArtist(a, role: .singer) }
                            .atlas("control.music.filmInfoSinger")
                    } else {
                        Text(verbatim: n).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    }
                    if i < names.count - 1 { Text(verbatim: ",").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                }
            }
        }
    }

    // MARK: compact

    private func compactBody(_ info: MusicFilmInfo) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text(verbatim: title(info)).musicText(.card).foregroundStyle(ColorTokens.textPrimary).lineLimit(2).accessibilityAddTraits(.isHeader)
            MusicInlineLink(title: Localized.string("View film"), label: Localized.string("Open the page of %1$@", info.title)) { openFilmPage(info) }
                .atlas("control.music.filmViewFilm")
            if !info.cast.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: MusicSpace.sm) {
                        ForEach(info.cast.prefix(6)) { p in
                            Button { open(p, info) } label: {
                                VStack(spacing: MusicSpace.xxs) {
                                    MusicCoverImage(thumbs: thumbs(p), artworkClass: .artistPortrait, size: MusicArtistRow.portrait, corner: MusicCardGeometry.roundCorner,
                                                    seed: p.name, initials: MusicArtistPortrait.initials(p.name), subject: .person(p.name, roles: [.actor]))
                                    Text(verbatim: p.name).musicText(.micro).foregroundStyle(ColorTokens.textSecondary).lineLimit(2).multilineTextAlignment(.center)
                                        .frame(width: MusicArtistRow.portrait + MusicSpace.md)
                                }
                                .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverHighlight()
                            .accessibilityLabel(Localized.string("Open actor %1$@", p.name)).atlas("control.music.filmActor")
                        }
                    }
                }
            }
            crew(info)
        }
    }

    // MARK: helpers

    private func title(_ info: MusicFilmInfo) -> String {
        info.year.map { Localized.string("From the film %1$@ (%2$@)", info.title, String($0)) } ?? Localized.string("From the film %1$@", info.title)
    }

    private func thumbs(_ p: MusicFilmPerson) -> [MusicThumbnail] { p.photoURL.map { [MusicThumbnail(url: $0, width: 185, height: 278)] } ?? [] }

    /// Opens the film's own page: the graph entity for this film (found by any of its ids, or written from what the film layer found), by id only.
    private func openFilmPage(_ info: MusicFilmInfo) {
        guard !opening else { return }
        opening = true
        let hub = self.hub
        Task { @MainActor in
            defer { opening = false }
            var id: MusicEntityID?
            if let resolver = MusicFilmGraphLink.shared.resolver, let report = try? await resolver.ingest(MusicFilmGraphBridge.batch(from: info)) {
                id = report.ids.values.filter { $0.kind == .film }.min { $0.rawValue < $1.rawValue }
            }
            if id == nil {
                // No metadata layer yet: write the film itself (a strong id finds the entity it already has; with none, the name and year make the id).
                let ids = MusicFilmPageRouting.writeIDs(for: info)
                let draft = MusicEntityDraft(kind: .film, name: info.title, lang: info.language, year: info.year, externalIDs: ids, provisional: MusicFilmPageRouting.externalIDs(for: info).isEmpty)
                id = try? await MusicGraphRuntime.shared.store.upsert(draft).id
            }
            let target: MusicEntityID
            if let id { target = id } else { target = await MusicFilmPageRouting.filmID(for: info, store: MusicGraphRuntime.shared.store) }
            hub.open(target)
        }
    }

    private func open(_ p: MusicFilmPerson, _ info: MusicFilmInfo) {
        if let id = model.personIDs[p.id] { hub.open(id, role: .actor); return }
        // A person with strong ids is found or written by those ids, never by name.
        let ids = MusicFilmPageRouting.personExternalIDs(p)
        if !ids.isEmpty {
            let hub = self.hub
            Task { @MainActor in
                let draft = MusicEntityDraft(kind: .person, name: p.name, subkind: "actor", lang: info.language, externalIDs: ids)
                if let id = try? await MusicGraphRuntime.shared.store.upsert(draft).id { hub.open(id, role: .actor); return }
                hub.open(.actor(MusicActorRoute(person: p, language: info.language, providerID: model.providerID, filmTitle: info.title)))
            }
            return
        }
        hub.open(.actor(MusicActorRoute(person: p, language: info.language, providerID: model.providerID, filmTitle: info.title)))
    }
}
