import SwiftUI

/// The first-run "tell Music what you like" window: languages, genres, artists, and a few optional extras. Every step can be skipped; "Done" is always one tap away.
/// What is chosen shapes Recently Added, Radio and autoplay (songs in a genre marked not for me are left out of them), and it stays on this device.
struct MusicSetupSheet: View {
    let hub: MusicHub
    let close: () -> Void
    @State private var flow = MusicSetupFlow(prefs: MusicTastePreferences.shared.prefs)
    @State private var suggestions: [MusicArtist] = []
    /// The languages `suggestions` were made for: a different set (after Back and a new pick) asks again instead of showing the old list.
    @State private var suggestionsFor: Set<String>?
    @State private var loadingArtists = false
    @State private var query = ""
    @State private var found: [MusicArtist] = []
    @State private var sonicOn = SonicJobs.isEnabled
    @State private var folderCount = LocalMediaFolders.shared.folders.count
    @Environment(\.reddyAccent) private var accent

    private let languages = MusicLanguage.allCases.filter { $0 != .latin }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localized.string("Tell Music what you like")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                    Text(stepSubtitle).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer()
                Button(Localized.string("Skip setup")) { finish(save: false) }.musicButton(.secondary, size: .compact).atlas("control.music.setupSkip")
            }
            ProgressView(value: flow.progress).tint(accent).accessibilityHidden(true)
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if !flow.isFirst { Button(Localized.string("Back")) { flow.back() }.musicButton(.secondary, size: .large).atlas("control.music.setupBack") }
                Spacer()
                Button(flow.isLast ? Localized.string("Done") : Localized.string("Continue")) { if flow.isLast { finish(save: true) } else { flow.next() } }
                    .musicButton(.primary, size: .large).atlas("control.music.setupNext")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 540, maxHeight: .infinity, alignment: .top)
        .task(id: flow.step) { if flow.step == .artists { await loadSuggestions() } }
    }

    private var stepSubtitle: String {
        switch flow.step {
        case .languages: Localized.string("Which languages do you listen to? Pick any number, or none.")
        case .genres: Localized.string("Which kinds of music do you like?")
        case .artists: Localized.string("Pick artists you like. You can add one that is not listed.")
        case .extras: Localized.string("A few optional things. You can do these later in Settings.")
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .languages:
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(languages, id: \.self) { l in MusicChip(title: Localized.string(l.englishName), selected: flow.languages.contains(l.rawValue)) { flow.toggleLanguage(l.rawValue) } }
            }
        case .genres:
            Text(Localized.string("Tap to like, double-tap to love, press and hold for not for me.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(MusicSetupFlow.genreVocabulary, id: \.self) { g in genreChip(g) }
            }
        case .artists:
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                MusicSheetField(placeholder: Localized.string("Add an artist"), text: $query, atlas: "control.music.setupArtistSearch")
                    .task(id: query) { await search() }
                // With no search typed, the artists already picked come first, so each can be switched off (a saved pick from an earlier language set is not in the suggestions).
                let searching = query.trimmingCharacters(in: .whitespaces).count >= 2
                let list: [MusicArtist] = searching ? found : {
                    let picked = flow.artists
                    let have = Set(picked.map(\.uid))
                    return picked + suggestions.filter { !have.contains($0.uid) }
                }()
                if loadingArtists && list.isEmpty { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 80) }
                else if list.isEmpty { Text(Localized.string("No suggestions yet. Search for an artist above, or continue.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary) }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MusicSpace.sm)], spacing: MusicSpace.sm) {
                        ForEach(list) { a in artistTile(a) }
                    }
                }
                if !flow.artists.isEmpty { Text(Localized.plural(flow.artists.count, one: "%@ artist picked", other: "%@ artists picked")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
            }
        case .extras:
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                summary
                #if os(macOS)
                extraRow("folder.badge.plus", Localized.string("Add a music folder"), folderCount > 0 ? Localized.plural(folderCount, one: "%@ folder added", other: "%@ folders added") : Localized.string("Play your own files. Nothing is uploaded."), action: Localized.string("Choose…")) {
                    LocalMediaFolders.shared.chooseAndAdd()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        folderCount = LocalMediaFolders.shared.folders.count
                        // A folder was added so its songs can be played: the Local files source is switched on with it (it is off in the default set).
                        if folderCount > 0 { hub.registry.setEnabled(true, id: MusicSetupPresets.localFilesID, reason: .setup) }
                    }
                }
                #endif
                MusicSheetCard {
                    Toggle(isOn: Binding(get: { sonicOn }, set: { sonicOn = $0; SonicJobs.isEnabled = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Localized.string("Sound analysis")).font(Typography.bodyMedium)
                            Text(Localized.string("Find songs that sound alike, from your own files. It runs quietly in the background.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        }
                    }.toggleStyle(.switch).atlas("control.music.setupSonic")
                }
                extra("link", Localized.string("Connect Last.fm or ListenBrainz"), Localized.string("Better suggestions from your own listening history.")) { MusicChromeState.shared.openSettings(.plugins, anchor: "plugins.scrobbling") }
            }
        }
    }

    /// The Apple pattern: tap likes, double tap loves, press and hold says not for me. The same three are in the chip's menu and as VoiceOver actions.
    private func genreChip(_ g: String) -> some View {
        let st = flow.state(of: g)
        let label: String = {
            switch st { case .none: Localized.string(g); case .liked: Localized.string(g); case .loved: "♥ " + Localized.string(g); case .notForMe: "⊘ " + Localized.string(g) }
        }()
        return Text(verbatim: label).font(Typography.bodyMedium)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(st == .loved ? accent.opacity(0.35) : (st == .liked ? accent.opacity(0.18) : (st == .notForMe ? ColorTokens.danger.opacity(0.14) : ColorTokens.elevated.opacity(0.5)))))
            .overlay(Capsule().strokeBorder(st == .none ? ColorTokens.line : (st == .notForMe ? ColorTokens.danger.opacity(0.5) : accent.opacity(0.7)), lineWidth: 1))
            .strikethrough(st == .notForMe)
            .contentShape(Capsule())
            .onTapGesture(count: 2) { flow.loveGenre(g) }
            .onTapGesture { flow.toggleGenre(g) }
            .onLongPressGesture(minimumDuration: 0.45) { flow.rejectGenre(g) }
            .contextMenu {
                Button(Localized.string("Like")) { flow.toggleGenre(g) }.atlas("control.music.setupGenreLike")
                Button(Localized.string("Love")) { flow.loveGenre(g) }.atlas("control.music.setupGenreLove")
                Button(Localized.string("Not for me")) { flow.rejectGenre(g) }.atlas("control.music.setupGenreNo")
            }
            .atlas("control.music.setupGenre")
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: Localized.string(g)))
            .accessibilityValue(Text(verbatim: st == .loved ? Localized.string("Loved") : (st == .liked ? Localized.string("Liked") : (st == .notForMe ? Localized.string("Not for me") : ""))))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(Localized.string("Like"))) { flow.toggleGenre(g) }
            .accessibilityAction(named: Text(Localized.string("Love"))) { flow.loveGenre(g) }
            .accessibilityAction(named: Text(Localized.string("Not for me"))) { flow.rejectGenre(g) }
    }

    private func artistTile(_ a: MusicArtist) -> some View {
        let on = flow.hasArtist(a)
        return Button { flow.toggleArtist(a); if flow.hasArtist(a) { Task { await addSimilar(to: a) } } } label: {
            HStack(spacing: MusicSpace.xs) {
                MusicArtwork(a.thumbnails, size: 40, corner: 20)
                Text(verbatim: a.name).font(Typography.bodyMedium).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            }
            .padding(MusicSpace.xs).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? accent.opacity(0.16) : ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(on ? accent.opacity(0.6) : ColorTokens.line, lineWidth: on ? 1.2 : 0.75))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).atlas("control.music.setupArtist")
    }

    /// What will be saved, in words, so the last step says what Done does.
    private var summary: some View {
        let parts = [flow.languages.isEmpty ? nil : Localized.plural(flow.languages.count, one: "%@ language", other: "%@ languages"),
                     flow.genres.isEmpty && flow.lovedGenres.isEmpty ? nil : Localized.plural(flow.genres.count, one: "%@ genre", other: "%@ genres"),
                     flow.artists.isEmpty ? nil : Localized.plural(flow.artists.count, one: "%@ artist", other: "%@ artists"),
                     flow.dislikedGenres.isEmpty ? nil : Localized.plural(flow.dislikedGenres.count, one: "%@ genre not for me", other: "%@ genres not for me")].compactMap { $0 }
        return Text(parts.isEmpty && flow.pickedNothing ? Localized.string("You have not picked anything. Music will learn from what you play.") : Localized.string("Done saves: %@. They shape Recently Added, Radio and autoplay, and you can change them any time in Settings.", parts.joined(separator: ", ")))
            .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
    }

    private func extraRow(_ symbol: String, _ title: String, _ detail: String, action label: String, perform: @escaping () -> Void) -> some View {
        MusicSheetCard {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: symbol).font(MusicTokens.iconSmall).frame(width: 30, height: 30).background(ColorTokens.elevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) { Text(verbatim: title).font(Typography.bodyMedium); Text(verbatim: detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                Spacer()
                Button(label, action: perform).musicButton(.secondary, size: .compact).atlas("control.music.setupFolder")
            }
        }
    }

    private func extra(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button { finish(save: true); action() } label: {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: symbol).font(MusicTokens.iconSmall).frame(width: 30, height: 30).background(ColorTokens.elevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) { Text(verbatim: title).font(Typography.bodyMedium); Text(verbatim: detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                Spacer()
            }.padding(MusicSpace.sm).contentShape(Rectangle())
        }.buttonStyle(.plain).hoverHighlight().atlas("control.music.setupExtra")
    }

    // MARK: data

    /// Artists from the songs the discovery sources list for the chosen languages (JioSaavn's lists are per language); with no language chosen there are none.
    /// Artists already liked or followed are left out, and so are those of a source that is switched off (Recently Added never asks it, so they would count and show nothing).
    private func loadSuggestions() async {
        guard suggestions.isEmpty || suggestionsFor != flow.languages else { return }
        let languagesAsked = flow.languages
        loadingArtists = true
        defer { loadingArtists = false }
        let wanted = flow.languages.compactMap(MusicLanguage.init(rawValue:))
        var tracks: [MusicTrack] = []
        for p in hub.registry.discovery {
            guard let j = p as? any MusicLanguageDiscovery, !wanted.isEmpty else { continue }
            let sections = (try? await j.featured(region: "in", languages: Array(wanted.prefix(3)))) ?? []
            for s in sections { for item in s.items { if case .track(let t) = item { tracks.append(t) } } }
        }
        // No discovery source lists songs for these languages (a Spanish, Korean or French pick, or that source switched off): the active source's own search for
        // "<language> songs" is asked instead, the same words Recently Added uses, so any language gets suggestions.
        if tracks.isEmpty, let provider = hub.registry.activeMetadata {
            for lang in wanted.prefix(3) where !Task.isCancelled {
                let page = try? await MusicStreamResolver.withDeadline(8, { try await provider.searchTracks(lang.englishName + " songs", page: nil) })
                tracks += page?.items ?? []
            }
        }
        let known = Set(hub.library.followedArtists.map { MusicText.normalize($0.name) })
        if Task.isCancelled || languagesAsked != flow.languages { return }
        suggestions = MusicSetupFlow.suggestedArtists(fromTracks: tracks, excluding: known).filter { hub.registry.enabled.contains($0.providerID) }
        suggestionsFor = languagesAsked
    }

    /// Picking an artist brings up to three like it at the front of the suggestions: later suggestions follow what was just chosen.
    private func addSimilar(to a: MusicArtist) async {
        // Asked of the service that gave this artist (its id means nothing to another one).
        guard let p = hub.registry.metadataProvider(id: a.providerID), let rel = try? await p.relatedArtists(id: a.id) else { return }
        let have = Set(suggestions.map(\.uid) + flow.artists.map(\.uid) + found.map(\.uid))
        let fresh = rel.filter { !have.contains($0.uid) && hub.registry.enabled.contains($0.providerID) }.prefix(3)
        guard !fresh.isEmpty else { return }
        suggestions.insert(contentsOf: fresh, at: 0)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { found = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        var out: [MusicArtist] = []
        if let p = hub.registry.activeMetadata {
            do { out = try await p.searchArtists(q, page: nil).items } catch { out = [] }
        }
        // A newer word replaced this one while the source was answering: its answer must neither clear nor overwrite the list.
        if Task.isCancelled || q != query.trimmingCharacters(in: .whitespaces) { return }
        found = Array(out.prefix(12))
    }

    private func finish(save: Bool) {
        if save { MusicTastePreferences.shared.update { $0 = flow.applying(to: $0) } }
        UserDefaults.standard.set(true, forKey: MusicSetupGate.doneKey)
        close()
    }
}

/// A quiet card for a person who already listens: it offers the setup once and goes away on "Not now" or after the setup.
struct MusicSetupCard: View {
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Localized.string("Tell Music what you like")).font(Typography.bodyMedium)
                Text(Localized.string("Pick languages, genres and artists so suggestions fit you. It takes a minute and you can skip any step.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            Spacer()
            Button(Localized.string("Not now"), action: dismiss).musicButton(.secondary, size: .compact).atlas("control.music.setupCardDismiss")
            Button(Localized.string("Set up"), action: open).musicButton(.primary, size: .compact).atlas("control.music.setupCardOpen")
        }
        .padding(MusicSpace.sm)
        .background(ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
    }
}
