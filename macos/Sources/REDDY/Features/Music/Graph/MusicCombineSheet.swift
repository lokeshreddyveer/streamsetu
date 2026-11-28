import SwiftUI

/// Find songs by combining people, a language and a decade: for example composed by one person, sung by another, in Telugu films of the 1990s. It looks only
/// at what Music's connected graph already holds, and says how much it could not place instead of guessing.
struct MusicCombineSheet: View {
    let hub: MusicHub
    let close: () -> Void
    /// People to start from (the artist page's "Combine" with a collaborator); nil opens the sheet empty.
    var initialPicks: MusicCombinePreset?

    init(hub: MusicHub, close: @escaping () -> Void, initialPicks: MusicCombinePreset? = nil) {
        self.hub = hub; self.close = close; self.initialPicks = initialPicks
    }

    struct Pick: Equatable { var id: MusicEntityID; var name: String }
    @State private var composer: Pick?
    @State private var singer: Pick?
    @State private var lyricist: Pick?
    @State private var language: String?
    @State private var decade: Int?
    @State private var kind: MusicSongKind?
    @State private var raga: String?
    @State private var ragaIndex: MusicRagaIndex?
    @State private var ragaOptions: [(raga: String, count: Int)] = []
    @State private var result: MusicCombineResult?
    @State private var running = false
    /// Bumped when a new run starts or the picks change, so an answer for picks the person already changed never lands.
    @State private var runToken = 0
    /// The lookup in flight, cancelled when the sheet closes or the picks change, so a closed sheet never keeps reading the graph.
    @State private var runTask: Task<Void, Never>?
    @State private var starting = false
    @Environment(\.reddyAccent) private var accent

    private static let languages: [(code: String, name: String)] = [("te", "Telugu"), ("hi", "Hindi"), ("ta", "Tamil"), ("ml", "Malayalam"), ("kn", "Kannada"),
                                                                    ("bn", "Bengali"), ("pa", "Punjabi"), ("mr", "Marathi"), ("gu", "Gujarati"), ("or", "Odia"), ("ur", "Urdu"), ("as", "Assamese"),
                                                                    ("bho", "Bhojpuri"), ("en", "English"), ("ko", "Korean"), ("ja", "Japanese"), ("es", "Spanish"), ("ar", "Arabic")]
    private static let decades = Array(stride(from: 2020, through: 1950, by: -10))

    static func kindName(_ k: MusicSongKind) -> String {
        switch k {
        case .devotional: Localized.string("Devotional")
        case .festival: Localized.string("Festival")
        case .folk: Localized.string("Folk")
        case .filmScore: Localized.string("Film score")
        case .classicalFusion: Localized.string("Classical fusion")
        case .classical: Localized.string("Classical")
        }
    }

    private var filter: MusicCombineFilter { MusicCombineFilter(composer: composer?.id, singer: singer?.id, lyricist: lyricist?.id, language: language, decade: decade, kind: kind, raga: raga) }
    private var graph: any MusicGraphStoring { MusicEntityRuntime.shared.center.store.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localized.string("Combine")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                    Text(Localized.string("Pick people, a language and a decade. Only songs that match everything you chose are shown.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.combineClose")
            }
            MusicSheetCard {
                VStack(alignment: .leading, spacing: MusicSpace.sm) {
                    MusicCombinePersonPicker(title: "Composed by", pick: $composer, graph: graph, atlas: "control.music.combineComposer")
                    MusicCombinePersonPicker(title: "Sung by", pick: $singer, graph: graph, atlas: "control.music.combineSinger")
                    MusicCombinePersonPicker(title: "Written by", pick: $lyricist, graph: graph, atlas: "control.music.combineLyricist")
                }
            }
            MusicChipFlow(spacing: MusicSpace.xs) {
                MusicMenuChip(label: Localized.string("Language"), anyTitle: Localized.string("Any language"),
                              options: Self.languages.map { (value: $0.code, title: label($0)) }, selection: $language, atlas: "control.music.combineLanguage")
                MusicMenuChip(label: Localized.string("Decade"), anyTitle: Localized.string("Any decade"),
                              options: Self.decades.map { (value: $0, title: MusicPersonWording.filterDecade($0)) }, selection: $decade, atlas: "control.music.combineDecade")
                MusicMenuChip(label: Localized.string("Raga"), anyTitle: Localized.string("Any raga"),
                              options: ragaOptions.map { (value: $0.raga, title: "\($0.raga) · \($0.count)") }, selection: $raga, atlas: "control.music.combineRaga")
                MusicMenuChip(label: Localized.string("Kind of music"), anyTitle: Localized.string("Any kind"),
                              options: MusicSongKind.allCases.map { (value: $0, title: Self.kindName($0)) }, selection: $kind, atlas: "control.music.combineKind")
            }
            HStack(spacing: MusicSpace.sm) {
                if !filter.isRunnable { Text(Localized.string("Choose at least one person to start from.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary) }
                Spacer()
                Button(Localized.string("Find songs")) { run() }.musicButton(.primary, size: .large).disabled(!filter.isRunnable || running).atlas("control.music.combineRun")
            }
            resultView
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, maxHeight: .infinity, alignment: .top)
        // The list on screen belongs to the picks that made it: changing a pick or a filter clears it until Find songs is pressed again.
        .onChange(of: filter) { _, _ in runTask?.cancel(); runToken += 1; result = nil; running = false }
        .onDisappear { runTask?.cancel(); runTask = nil }
        .onAppear {
            guard let p = initialPicks, composer == nil, singer == nil, lyricist == nil else { return }
            composer = p.composer.map { Pick(id: $0.id, name: $0.name) }
            singer = p.singer.map { Pick(id: $0.id, name: $0.name) }
            lyricist = p.lyricist.map { Pick(id: $0.id, name: $0.name) }
        }
        .task {
            let rows = await MusicRagaCatalog.shared.songs(online: MusicEntityArtwork.shared.networkAllowed())
            let idx = MusicRagaIndex(rows)
            ragaIndex = idx; ragaOptions = idx.allRagas(limit: 80)
        }
    }

    @ViewBuilder private var resultView: some View {
        if running { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 80) }
        else if let r = result {
            if r.songs.isEmpty && r.possible.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localized.string("No songs matched everything.")).font(MusicTokens.rowTitle)
                    Text(coverage(r)).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                    Text(Localized.string("Try removing the language or the decade, or one of the people.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
            } else {
                HStack {
                    Text(Localized.plural(r.songs.count, one: "%@ song", other: "%@ songs")).font(MusicTokens.rowTitle)
                    Spacer()
                    Button { play(r) } label: { Label(Localized.string("Play all"), systemImage: "play.fill") }.musicButton(.secondary, size: .compact).disabled(r.songs.isEmpty || starting).atlas("control.music.combinePlayAll")
                }
                if r.songs.count > MusicPersonPlaySource.maxSongs {
                    Text(verbatim: Localized.string("Play all starts with the first %1$d of these songs.", MusicPersonPlaySource.maxSongs)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(r.songs) { e in
                            Button { close(); hub.open(e.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: e.name).font(Typography.bodyMedium).lineLimit(1)
                                        if let f = e.filmTitle { Text(verbatim: f ).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let y = e.year { Text(verbatim: String(y)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                                }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }.buttonStyle(.plain).hoverHighlight().atlas("control.music.combineOpenSong")
                        }
                        summarySection(r).padding(.top, MusicSpace.sm)
                        possibleSection(r)
                        Text(coverage(r)).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.top, MusicSpace.sm)
                    }
                }
            }
        }
    }

    /// What the people made together: the years of their songs and the films those songs come from, each film opening its page.
    @ViewBuilder private func summarySection(_ r: MusicCombineResult) -> some View {
        let sum = MusicCombineSummary.build(r.songs)
        if !sum.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if let a = sum.firstYear, let b = sum.lastYear {
                    Text(verbatim: a == b ? Localized.string("Together in %1$@", "\(a)") : Localized.string("Together from %1$@ to %2$@", "\(a)", "\(b)")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                }
                if !sum.languages.isEmpty {
                    Text(verbatim: Localized.string("In %1$@", sum.languages.map { MusicPersonReader.languageName($0) }.joined(separator: ", "))).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                }
                if !sum.films.isEmpty {
                    Text(Localized.string("Films with these songs")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    MusicChipFlow(spacing: MusicSpace.xs) {
                        ForEach(sum.films) { f in
                            MusicChip(title: f.title + " · \(f.songs)", selected: false) { close(); hub.open(f.id) }.atlas("control.music.combineOpenFilm")
                        }
                    }
                }
            }
        }
    }

    /// Songs placed only by their film's language or year, shown apart and worded as possible.
    @ViewBuilder private func possibleSection(_ r: MusicCombineResult) -> some View {
        if !r.possible.isEmpty {
            DisclosureGroup(Localized.plural(r.possible.count, one: "%@ possible match (language or year from the film)", other: "%@ possible matches (language or year from the film)")) {
                ForEach(r.possible) { e in
                    Button { close(); hub.open(e.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: e.name).font(Typography.bodyMedium).lineLimit(1)
                                if let f = e.filmTitle { Text(verbatim: f).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                            }
                            Spacer()
                            if let y = e.year { Text(verbatim: String(y)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                        }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                    }.buttonStyle(.plain).hoverHighlight().atlas("control.music.combineOpenPossible")
                }
            }.font(Typography.captionMedium)
        }
    }

    /// What the answer could not cover, in plain words.
    private func coverage(_ r: MusicCombineResult) -> String {
        var parts = [Localized.plural(r.checked, one: "Looked through %@ song.", other: "Looked through %@ songs.")]
        if r.withoutLanguage > 0 { parts.append(Localized.plural(r.withoutLanguage, one: "%@ song has no language recorded.", other: "%@ songs have no language recorded.")) }
        if r.withoutYear > 0 { parts.append(Localized.plural(r.withoutYear, one: "%@ song has no year recorded.", other: "%@ songs have no year recorded.")) }
        if r.withoutKind > 0 { parts.append(Localized.plural(r.withoutKind, one: "%@ song has no genre tag to say what kind of music it is.", other: "%@ songs have no genre tag to say what kind of music they are.")) }
        if r.withoutRaga > 0 { parts.append(Localized.plural(r.withoutRaga, one: "%@ song has no raga documented.", other: "%@ songs have no raga documented.")) }
        if r.cut { parts.append(Localized.string("The list was cut at its limit.")) }
        return parts.joined(separator: " ")
    }

    private func label(_ l: (code: String, name: String)) -> String {
        guard let i = MusicCombineRules.industry(forLanguage: l.code) else { return Localized.string(l.name) }
        return Localized.string(l.name) + " · " + Localized.string(i)
    }

    private func run() {
        let f = filter, g = graph, idx = ragaIndex
        let names = [composer?.name, singer?.name, lyricist?.name].compactMap { $0 }
        runTask?.cancel()
        runToken += 1
        let mine = runToken
        running = true
        runTask = Task {
            let r = await MusicCombine.run(f, store: g, ragas: idx, artistNames: names)
            await MainActor.run { if runToken == mine, !Task.isCancelled { result = r; running = false } }
        }
    }

    private func play(_ r: MusicCombineResult) {
        guard let anchor = (singer ?? composer ?? lyricist)?.id else { return }
        let playback = MusicPersonPlayback(hub: hub, person: anchor, graph: graph)
        let names = [singer, composer, lyricist].compactMap { $0?.name }
        playback.sourceName = names.isEmpty ? Localized.string("Combine") : names.joined(separator: " + ")   // "Playing from" says whose songs these are
        let ids = r.songs.prefix(MusicPersonPlaySource.maxSongs).map(\.id)
        // A second press while the first is still resolving its songs does nothing (it would queue the same songs twice).
        guard !starting else { return }
        starting = true
        Task { await playback.play(.songs(Array(ids)), shuffle: false); starting = false }
    }
}

/// A name box that finds people and groups in the graph and shows what was chosen.
struct MusicCombinePersonPicker: View {
    let title: String
    @Binding var pick: MusicCombineSheet.Pick?
    let graph: any MusicGraphStoring
    let atlas: String
    @State private var text = ""
    @State private var hits: [MusicSearchHit] = []
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: MusicSpace.sm) {
            Text(Localized.string(title)).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: 96, alignment: .leading).frame(minHeight: MusicTokens.hitTarget + MusicSpace.xxs, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let p = pick {
                    HStack(spacing: 6) {
                        Text(verbatim: p.name).font(Typography.bodyMedium).lineLimit(1)
                        Button { pick = nil; text = ""; hits = [] } label: { Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall) }.buttonStyle(.plain)
                            .accessibilityLabel(Localized.string("Remove")).atlas("control.music.combineClear")
                    }
                    .padding(.horizontal, MusicSpace.sm).frame(height: MusicTokens.hitTarget + MusicSpace.xxs)
                    .background(accent.opacity(0.16), in: Capsule()).overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
                } else {
                    MusicSheetField(placeholder: Localized.string("Search by name"), text: $text, atlas: atlas)
                        .task(id: text) {
                            let q = text.trimmingCharacters(in: .whitespaces)
                            guard q.count >= 2 else { hits = []; return }
                            try? await Task.sleep(for: .milliseconds(250))
                            if Task.isCancelled { return }
                            let found = (try? await graph.search(q, kinds: [.person, .group], limit: 6)) ?? []
                            if Task.isCancelled || pick != nil || text.trimmingCharacters(in: .whitespaces) != q { return }   // a late answer must not show under a pick or newer words
                            hits = found
                        }
                    if !hits.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(hits, id: \.id) { h in
                                Button { pick = .init(id: h.id, name: h.name); hits = []; text = "" } label: {
                                    HStack { Text(verbatim: h.name); if let y = h.year { Text(verbatim: "(\(y))").foregroundStyle(ColorTokens.textTertiary) }; Spacer() }
                                        .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                                }.buttonStyle(.plain).hoverHighlight().atlas("control.music.combinePickPerson")
                            }
                        }
                        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
                    }
                }
            }
        }
    }
}
