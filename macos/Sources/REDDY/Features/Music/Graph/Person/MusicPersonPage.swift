import SwiftUI

/// The page of a person or group, by entity route. It shows what the graph holds at once, adds sections as their loads land, and offers a role
/// switcher only when edges back more than one role (never "actor" for a singer or "singer" for an actor). Every artist, actor and node route of a
/// person or group lands here.
struct MusicPersonPage: View {
    let entity: MusicEntityID
    let role: MusicRole?
    let hub: MusicHub
    @State private var model: MusicPersonGraphModel
    @State private var playback: MusicPersonPlayback
    @State private var showNetwork = false
    @State private var state: MusicArtistPageState
    private let memoryKey: String

    init(entity: MusicEntityID, role: MusicRole?, hub: MusicHub) {
        self.entity = entity; self.role = role; self.hub = hub
        let key = MusicRoute.person(entity, role: role).scrollKey
        let memory = MusicPersonMemory(loadRole: { MusicPageMemoryCenter.shared.memory(for: $0).filters["role"] },
                                       saveRole: { key, value in MusicPageMemoryCenter.shared.update(key) { $0.filters["role"] = value } })
        let remembered = MusicPageMemoryCenter.shared.memory(for: key)
        let query = remembered.filters["nameSearch"]
        self.memoryKey = key
        _state = State(initialValue: MusicArtistPageState(restoring: MusicArtistPageSnapshot.decode(tab: remembered.selectedTab, filters: remembered.filters)))
        let runtime = MusicEntityRuntime.shared
        _model = State(initialValue: MusicPersonGraphModel(id: entity, roleHint: role, nameSearchQuery: query, memoryKey: key, center: runtime.center, memory: memory,
                                                           enrichRoles: { id, roles in
                                                               guard let r = MusicFilmGraphLink.shared.resolver else { return false }
                                                               let o = await r.enrichPerson(id, roles: roles)
                                                               return o.edgesWritten > 0 || !o.fetched.isEmpty
                                                           }))
        _playback = State(initialValue: MusicPersonPlayback(hub: hub, person: entity, graph: runtime.store.graph))
    }

    /// The person this page shows: the row the graph resolved to after a merge or redirect, else the one that was asked for.
    private var personID: MusicEntityID { model.entity?.id ?? entity }

    var body: some View {
        MusicPageScaffold(hub: hub) {
            if model.phase == .failed {
                MusicEmptyState(symbol: "person.crop.circle.badge.questionmark", title: MusicPersonWording.unavailable, actionTitle: Localized.string("Try again")) { model.retry() }
            } else if let header = model.header {
                let _ = { playback.sourceName = header.names.display }()
                MusicPersonHeaderView(hub: hub, model: model, header: header, playback: playback, catalog: catalog, personal: state.personal)
                MusicPersonDidYouMean(hub: hub, candidates: model.candidates)
                pillsAndContent(header)
            } else {
                MusicLoadingView().frame(height: 240).accessibilityLabel(MusicPersonWording.loadingPerson)
            }
        }
        .task(id: model.viewData?.sections.reduce(0) { $0 + $1.entries.count } ?? 0) {
            // The first albums and films on this page start loading now; tapping one finds it ready.
            let ids = (model.viewData?.visible ?? []).flatMap { $0.entries.filter { [.album, .release, .film].contains($0.kind) }.prefix(2).map(\.id) }
            MusicEntityWarmer.shared.warm(ids, hub: hub)
            playback.prefetchFallback(retry: true)
        }
        .onAppear { MusicPageMemoryCenter.shared.update(memoryKey) { $0.filters["nameSearch"] = nil }; model.open(); playback.prefetchFallback(); playback.allowsProviderFallback = !(model.activeView == .actor || model.activeView == .director) }
        .onDisappear { model.close(); playback.cancel() }
        .onChange(of: model.syncToken) { _, _ in model.sync(); playback.prefetchFallback(retry: true) }
        .onChange(of: model.activeView) { _, v in playback.allowsProviderFallback = !(v == .actor || v == .director) }
        // Only the person's own pick of another role starts the pills again; a hint settling into the chosen role (or Back restoring the page) keeps what was remembered.
        .onChange(of: model.userSelections) { _, _ in state.reset() }
        .onChange(of: state.snapshot) { _, snap in
            let saved = snap.encoded()
            MusicPageMemoryCenter.shared.update(memoryKey) { m in
                m.selectedTab = saved.tab
                m.filters[MusicArtistPageSnapshot.songsKey] = saved.filters[MusicArtistPageSnapshot.songsKey]
                m.filters[MusicArtistPageSnapshot.listsKey] = saved.filters[MusicArtistPageSnapshot.listsKey]
                m.filters[MusicArtistPageSnapshot.filmsKey] = saved.filters[MusicArtistPageSnapshot.filmsKey]
            }
        }
        .task(id: listeningKey) { await refreshListening() }
        .atlasScreen("screen.music.person")
    }

    /// Ragas, concerts and more-from-the-artist belong to a musician; an actor or a director never gets a namesake singer's.
    private var musicalView: Bool { model.activeView != .actor && model.activeView != .director }

    // MARK: artist pills

    private var catalog: MusicArtistCatalog? { model.viewData.map(MusicArtistCatalog.build) }

    private var listeningKey: String {
        "\(hub.library.historyRevision)|\(hub.library.likedRevision)|\(model.activeView?.rawValue ?? "")|\(playback.providerArtist?.id ?? "")|\(model.viewData?.sections.reduce(0) { $0 + $1.entries.count } ?? 0)|\(model.header?.names.display ?? "")"
    }

    /// "Your listening" is about the songs this person performs: on a composer, lyricist, producer or label page the catalog's songs are written or released by them and
    /// sung by others, so matching the play history by who performed would call every one of them unplayed. Those views (and actor and director) have none.
    nonisolated static func hasPersonalListening(_ view: MusicPersonView?) -> Bool {
        guard let view else { return true }
        return [.singer, .instrumentalist, .conductor].contains(view)
    }

    /// Personal stats for this artist from the play history, worked out off the main thread. Nil (no pill) when nothing of theirs was ever played.
    private func refreshListening() async {
        // An actor's or director's page is not about singing: their "listening" would only be namesakes, so there is none. A page with no provider artist has no id to match by.
        guard let name = model.header?.names.display, Self.hasPersonalListening(model.activeView), playback.providerArtist != nil else { state.listening = nil; state.personal = .empty; return }
        let history = hub.library.history
        let liked = hub.library.liked
        let pa = playback.providerArtist
        let identity = MusicArtistIdentity(providerID: pa?.providerID, artistID: pa?.id, name: name)
        let songs = catalog?.songs ?? []
        // The provider ids of the catalog's recordings (read once each, at most the first 400), so a plain song and its live or remixed take are told apart by id.
        let uids = await songUIDs(for: songs)
        let (stats, personal) = await Task.detached(priority: .utility) {
            (MusicArtistListening.compute(history: history, identity: identity, songs: songs, uids: uids), MusicArtistPersonal.build(history: history, liked: liked, identity: identity, uids: uids))
        }.value
        if !Task.isCancelled { state.listening = stats.hasData ? stats : nil; state.personal = personal }
    }

    private func songUIDs(for songs: [MusicPersonEntry]) async -> [MusicEntityID: [String]] {
        var out = state.songUIDs
        let graph = playback.graph
        for e in songs.prefix(400) where out[e.id] == nil {
            if Task.isCancelled { break }
            // A read that failed or was cancelled stores nothing (an empty list would send this song to title matching for good); it is asked again next time.
            guard let ids = try? await graph.externalIDs(of: e.id), !Task.isCancelled else { continue }
            out[e.id] = MusicProviderUID.uids(in: ids)
        }
        state.songUIDs = out
        return out
    }

    @ViewBuilder private func pillsAndContent(_ header: MusicPersonHeaderData) -> some View {
        let cat = catalog
        let hasAbout = header.life != nil || !header.aliases.isEmpty || header.bio != nil || (cat.map { !MusicArtistStats($0).isEmpty } ?? false)
        let pills = MusicArtistPills.available(cat, hasListening: state.listening != nil, hasAbout: hasAbout)
        let active = MusicArtistPills.active(state.pill, in: pills)
        if pills.count > 1 { MusicArtistPillBar(pills: pills, view: model.activeView ?? .singer, state: state, active: active) }
        switch active {
        case .overview: content(header)
        case .songs: if let cat { MusicArtistSongsView(hub: hub, catalog: cat, playback: playback, state: state) }
        case .albums: if let cat { MusicArtistAlbumsView(hub: hub, catalog: cat, state: state) }
        case .films: if let cat { MusicArtistFilmsView(hub: hub, catalog: cat, state: state, person: personID) }
        case .collaborators:
            if let cat { MusicArtistCollaboratorsView(hub: hub, catalog: cat, person: personID, name: header.names.display, showNetwork: musicalView) { showNetwork = true }
                .sheet(isPresented: $showNetwork) { MusicCollaboratorNetworkSheet(hub: hub, person: personID) { showNetwork = false } } }
        case .timeline: if let cat { MusicArtistTimelineView(hub: hub, header: header, catalog: cat, state: state) }
        case .listening: if let s = state.listening { MusicArtistListeningView(hub: hub, playback: playback, name: header.names.display, stats: s) }
        case .about: MusicArtistAboutView(model: model, header: header, catalog: cat)
        }
    }

    /// The language chips of the page open the Songs pill filtered to that language, when the page has a Songs pill.
    private var exploreLanguage: ((String) -> Void)? {
        guard !(catalog?.songs.isEmpty ?? true) else { return nil }
        let st = state
        return { code in var f = MusicArtistSongFilter(); f.language = code; st.openSongs(f) }
    }

    @ViewBuilder private func content(_ header: MusicPersonHeaderData) -> some View {
        let name = header.names.display
        MusicCompletenessLine(id: model.entity?.id ?? entity)
        if let cat = catalog {
            MusicArtistExploreRow(options: MusicArtistExplore.options(cat, includeLanguages: (model.viewData?.section(.languages)?.entries.isEmpty ?? true)), state: state)
        }
        if let cat = catalog { MusicArtistLatestRelease(hub: hub, catalog: cat) }
        if musicalView { MusicPersonRagaChips(name: name) }
        if musicalView { Button { showNetwork = true } label: { Label(Localized.string("Collaborator network"), systemImage: "point.3.connected.trianglepath.dotted") }
            .musicButton(.secondary, size: .compact).atlas("control.music.networkOpenFromPerson")
            .sheet(isPresented: $showNetwork) { MusicCollaboratorNetworkSheet(hub: hub, person: personID) { showNetwork = false } } }
        if musicalView { MusicConcertsSection(hub: hub, person: personID, name: name) }
        if !model.groupSections.isEmpty {
            MusicPersonSectionsView(hub: hub, data: MusicPersonViewData(person: entity, view: model.activeView ?? .singer, sections: model.groupSections, complete: true, truncated: false),
                                    name: name, playback: playback, memoryKey: model.memoryKey)
        }
        if let data = model.viewData {
            MusicPersonSectionsView(hub: hub, data: data, name: name, playback: playback, memoryKey: model.memoryKey,
                                    exploreLanguage: exploreLanguage)
                .id(data.view)
            if musicalView { SoundCloudMoreShelf(hub: hub, name: name) }
        } else if model.viewLoadFailed {
            // The role's list did not load: say so and offer to ask again, instead of "Nothing more to show".
            MusicEmptyState(symbol: "exclamationmark.triangle", title: Localized.string("This page did not load."), message: Localized.string("Check your connection and try again."),
                            actionTitle: Localized.string("Try again")) { model.retryView() }
        } else if model.activeView != nil, model.viewPhase != .failed, model.viewPhase != .empty {
            MusicShelfSkeleton(count: 5)
        } else if model.rolesSettled, model.groupSections.isEmpty {
            // "Nothing more to show" is only true once the full list has finished loading; before that a skeleton holds the place, so the page does not jump when the songs and albums arrive.
            if MusicCompletenessTracker.shared.isRunning(model.entity?.id ?? entity) { MusicShelfSkeleton(count: 5) }
            else { MusicEmptyState(symbol: "music.note.list", title: MusicPersonWording.sparseTitle, message: MusicPersonWording.sparseMessage) }
        }
    }
}
