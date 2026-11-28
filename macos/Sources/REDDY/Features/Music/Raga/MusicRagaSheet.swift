import SwiftUI

/// Browse film songs by raga: the ragas on the left with how many songs each has, the songs of the chosen raga on the right. Tap a song to find it and play it.
struct MusicRagaSheet: View {
    let hub: MusicHub
    var initialRaga: String? = nil
    let close: () -> Void
    @State private var groups: [MusicRagaGroup] = []
    @State private var query = ""
    @State private var selected: String?
    @State private var loading = true
    @State private var language: String?
    @State private var playing: String?
    @State private var playingUID: String?
    /// The lookup of the last tap; a new tap cancels it, so quick taps never race.
    @State private var lookup: Task<Void, Never>?
    @State private var classical = false
    @Environment(\.reddyAccent) private var accent

    private var shown: [MusicRagaGroup] { MusicRagaTable.filter(groups, query: query) }
    private var current: MusicRagaGroup? { shown.first { $0.id == selected } ?? shown.first }
    private var songs: [MusicRagaSong] {
        guard let g = current else { return [] }
        return language.map { l in g.songs.filter { $0.language?.caseInsensitiveCompare(l) == .orderedSame } } ?? g.songs
    }
    private var languages: [String] {
        Array(Set((current?.songs ?? []).compactMap(\.language))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localized.string("Ragas")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                    Text(Localized.string("Songs and recordings by the raga they are set in, as documented.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.ragaClose")
            }
            MusicChoiceChips(options: [(value: false, title: Localized.string("Film songs")), (value: true, title: Localized.string("Classical"))], selection: $classical)
                .atlas("control.music.ragaMode")
            if classical { MusicClassicalPane(hub: hub) }
            else if loading { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 200) }
            else if groups.isEmpty {
                Text(Localized.string("The raga list could not be loaded. Check your connection and try again.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.lg)
            } else {
                HStack(alignment: .top, spacing: MusicSpace.md) { ragaList.frame(width: 220); songList }
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 540, maxHeight: .infinity, alignment: .top)
        .task { await load() }
        .onChange(of: current?.id) { _, _ in language = nil }   // a language chosen for another raga must not empty this one's list with its chip hidden
        .onChange(of: hub.player.current?.uid) { _, now in if playingUID != nil, now != playingUID { playing = nil; playingUID = nil } }   // only once the song is known: a track change during the lookup is not the answer
        .onDisappear { lookup?.cancel() }
    }

    private func load() async {
        loading = true
        let all = await MusicRagaCatalog.shared.songs(online: MusicEntityArtwork.shared.networkAllowed())
        groups = await Task.detached(priority: .userInitiated) { MusicRagaTable.groups(all) }.value
        if let want = initialRaga, selected == nil, let g = groups.first(where: { MusicRagaTable.key($0.name) == MusicRagaTable.key(want) || $0.aliases.contains { MusicRagaTable.key($0) == MusicRagaTable.key(want) } }) { selected = g.id; query = "" }
        loading = false
    }

    private var ragaList: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSheetField(placeholder: Localized.string("Search ragas"), text: $query, atlas: "control.music.ragaSearch")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { g in
                        Button { selected = g.id; language = nil } label: {
                            let on = g.id == current?.id
                            HStack {
                                Text(verbatim: g.name).font(on ? Typography.bodyMedium.weight(.semibold) : Typography.bodyMedium).lineLimit(1)
                                Spacer()
                                Text(verbatim: "\(g.songs.count)").font(Typography.caption).foregroundStyle(on ? accent : ColorTokens.textSecondary).monospacedDigit()
                            }
                            .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).fill(on ? accent.opacity(0.16) : .clear))
                        }.buttonStyle(.plain).atlas("control.music.ragaChoose")
                    }
                }
            }
        }
    }

    @ViewBuilder private var songList: some View {
        if let g = current {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: g.name).font(.system(size: 20, weight: .bold, design: .rounded))
                        if !g.aliases.isEmpty { Text(verbatim: g.aliases.joined(separator: " · ")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                    }
                    Spacer()
                    if languages.count > 1 {
                        MusicMenuChip(label: Localized.string("Language"), anyTitle: Localized.string("Any language"),
                                      options: languages.map { (value: $0, title: $0) }, selection: $language, atlas: "control.music.ragaLanguage")
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(songs) { s in
                            Button { play(s) } label: {
                                HStack(spacing: MusicSpace.sm) {
                                    Image(systemName: playing == s.id ? "waveform" : "play.fill").font(MusicTokens.iconSmall).foregroundStyle(playing == s.id ? accent : ColorTokens.textSecondary)
                                        .frame(width: 30, height: 30).background(ColorTokens.elevated, in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: s.title).font(Typography.bodyMedium).lineLimit(1)
                                        Text(verbatim: line(s)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let l = s.language { Text(verbatim: l).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 8).padding(.vertical, 2).background(ColorTokens.elevated, in: Capsule()) }
                                }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }.buttonStyle(.plain).hoverHighlight().atlas("control.music.ragaPlaySong")
                        }
                    }
                }
            }
        }
    }

    private func line(_ s: MusicRagaSong) -> String {
        [s.film + (s.year.map { " (\($0))" } ?? ""), s.composer, s.singers.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Finds the song with the music sources that are on and plays the recording that matches its title and, when the table documents them, its film, composer and singers.
    private func play(_ s: MusicRagaSong) {
        lookup?.cancel()
        playing = s.id
        playingUID = nil
        lookup = Task {
            let query = s.title + " " + s.film
            for p in hub.registry.metadata {
                if Task.isCancelled { return }
                // Each source gets 8 seconds: one that hangs must not leave the row spinning until the network gives up.
                guard let page = try? await MusicStreamResolver.withDeadline(8, { try await p.searchTracks(query, page: nil) }) else { continue }
                if Task.isCancelled { return }
                if let hit = MusicRagaMatch.best(for: s, in: page.items) {
                    playingUID = hit.uid
                    hub.play([hit], at: 0); return
                }
            }
            if Task.isCancelled { return }
            MusicToasts.shared.show(Localized.string("Could not find “%@” to play.", s.title))
            playing = nil
        }
    }
}

/// On a composer's or singer's page: the ragas their documented film songs are set in, most used first. Each opens the Ragas window on that raga. Hidden when the
/// list has nothing for the person.
struct MusicPersonRagaChips: View {
    let name: String
    @State private var ragas: [(raga: String, count: Int)] = []

    var body: some View {
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !ragas.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(Localized.string("Ragas in their songs")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    MusicChipFlow(spacing: MusicSpace.xs) {
                        ForEach(ragas, id: \.raga) { r in
                            MusicChip(title: "\(r.raga) · \(r.count)", selected: false) { MusicChromeState.shared.ragaRequest = MusicRagaRequest(raga: r.raga) }.atlas("control.music.personRagaChip")
                        }
                    }
                }
            }
        }
        .padding(.bottom, ragas.isEmpty ? -MusicSpace.lg : 0)
        .task(id: name) {
            let rows = await MusicRagaCatalog.shared.songs(online: false)
            ragas = MusicRagaIndex(rows).ragas(ofPerson: name, limit: 10)
        }
    }
}
