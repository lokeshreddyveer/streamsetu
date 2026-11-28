import SwiftUI

// The listening-insight screens: genre and language shares, the monthly and yearly recap (both shown in Statistics), and the Settings group where the
// person controls private listening, preferred languages, genres and artists, and resets what recommendations learned.

// MARK: - shares and recap in Statistics

struct MusicShareBars: View {
    let shares: [MusicInsightShare]
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shares) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(Localized.string(s.name)).font(Typography.row)
                        Spacer()
                        Text("\(Int((s.fraction * 100).rounded()))%").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit()
                    }
                    GeometryReader { g in
                        Capsule().fill(ColorTokens.lineStrong).overlay(alignment: .leading) { Capsule().fill(accent).frame(width: max(4, g.size.width * s.fraction)) }
                    }.frame(height: 5)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Genre and language shares for the chosen range, drawn as two panels. A panel with nothing to say is not shown.
struct MusicTasteMixPanels: View {
    let genres: [MusicInsightShare]
    let languages: [MusicInsightShare]

    var body: some View {
        if !genres.isEmpty || !languages.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if !genres.isEmpty { panel("Genres", MusicShareBars(shares: genres)) }
                if !languages.isEmpty { panel("Languages", MusicShareBars(shares: languages)) }
            }
        }
    }

    private func panel<C: View>(_ title: String, _ body: C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Localized.string(title)).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            body
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }
}

/// Your month or your year in music: time, favourites, what was new, busiest day and streak, with a step back and forward through periods.
struct MusicRecapView: View {
    let stats: MusicStats
    var onPlay: (([MusicTrack], Int) -> Void)?
    @State private var period = MusicRecapPeriod.month
    @State private var anchor = Date()
    @State private var recap: MusicRecap?
    @Environment(\.calendar) private var calendar

    private var title: String {
        guard let r = recap else { return "" }
        return period == .month ? r.start.formatted(.dateTime.month(.wide).year()) : r.start.formatted(.dateTime.year())
    }
    /// Later is allowed only when the next period has started: read from the date being shown, not from the recap, which arrives a moment after a click (two quick clicks
    /// would otherwise step into a month that has not happened).
    private var canGoForward: Bool {
        guard let next = calendar.date(byAdding: period.component, value: 1, to: anchor), let start = calendar.dateInterval(of: period.component, for: next)?.start else { return false }
        return start <= Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Localized.string("Recap")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("", selection: $period) { Text(Localized.string("Month")).tag(MusicRecapPeriod.month); Text(Localized.string("Year")).tag(MusicRecapPeriod.year) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().atlas("control.music.recapPeriod")
            }
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.musicButton(.glassIcon, size: .compact)
                    .accessibilityLabel(Localized.string("Earlier")).atlas("control.music.recapEarlier")
                Text(title).font(.system(size: 22, weight: .bold, design: .rounded)).frame(minWidth: 150)
                Button { step(1) } label: { Image(systemName: "chevron.right") }.musicButton(.glassIcon, size: .compact)
                    .disabled(!canGoForward).accessibilityLabel(Localized.string("Later")).atlas("control.music.recapLater")
            }
            if let r = recap {
                if r.isEmpty { Text(Localized.string("Nothing played in this period.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                else { details(r) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
        .task(id: "\(period.rawValue)|\(anchor.timeIntervalSince1970)|\(stats.revision)") { await load() }
    }

    private func load() async {
        let file = stats.file, p = period, a = anchor, cal = stats.calendar
        let made = await Task.detached(priority: .userInitiated) { MusicInsightsEngine.recap(file, period: p, anchor: a, calendar: cal) }.value
        // Stepping Month, Year or Earlier quickly: an older, slower recap must not land after the newer one and show the wrong period.
        guard !Task.isCancelled, p == period, a == anchor else { return }
        recap = made
    }

    private func step(_ n: Int) { anchor = calendar.date(byAdding: period.component, value: n, to: anchor) ?? anchor }

    @ViewBuilder private func details(_ r: MusicRecap) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MusicStatsFormat.duration(r.totalSecs)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            if let p = r.changePercent {
                Text(p >= 0 ? "▲ \(p)%" : "▼ \(-p)%").font(Typography.captionMedium).foregroundStyle(p >= 0 ? ColorTokens.success : ColorTokens.textSecondary)
            }
        }
        Text([Localized.plural(r.plays, one: "%@ play", other: "%@ plays"), Localized.plural(r.songs, one: "%@ song", other: "%@ songs"), Localized.plural(r.artists, one: "%@ artist", other: "%@ artists")].joined(separator: " · "))
            .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
            fact(Localized.string("New songs"), "\(r.newSongs)")
            fact(Localized.string("New artists"), "\(r.newArtists)")
            fact(Localized.string("Days you listened"), "\(r.listeningDays)")
            fact(Localized.string("Longest streak"), Localized.plural(r.longestStreak, one: "%@ day", other: "%@ days"))
            if let d = r.busiestDay { fact(Localized.string("Busiest day"), d.formatted(.dateTime.day().month(.abbreviated)) + " · " + MusicStatsFormat.duration(r.busiestDaySecs)) }
            if let i = r.favouriteDaypart { fact(Localized.string("You listen most in the"), Localized.string(MusicStatsFormat.daypartNames[i])) }
        }
        HStack(alignment: .top, spacing: 16) {
            list(Localized.string("Top songs"), r.topSongs.map { $0.track.title })
            list(Localized.string("Top artists"), r.topArtists.map(\.name))
            if !r.topAlbums.isEmpty { list(Localized.string("Top albums"), r.topAlbums.map(\.title)) }
        }
        if !r.genres.isEmpty || !r.languages.isEmpty {
            MusicTasteMixPanels(genres: r.genres, languages: r.languages)
        }
        if !r.topSongs.isEmpty, let onPlay {
            Button { onPlay(r.topSongs.map(\.track), 0) } label: { Label(Localized.string("Play this recap"), systemImage: "play.fill") }
                .musicButton(.primary, size: .compact).atlas("control.music.recapPlay")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(value).font(Typography.rowMedium)
        }.accessibilityElement(children: .combine)
    }

    private func list(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, t in Text("\(i + 1). \(t)").font(Typography.row).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - settings

/// Private listening, the things you like, and a way to start recommendations over.
struct MusicTasteGroup: View {
    let hub: MusicHub
    @State private var confirmReset = false
    /// What the listening statistics say, worked out when they change (not on every pass of `body`).
    @State private var statsTopArtists: [MusicTopArtist] = []
    @State private var statsGenres: [String] = []
    private let privateMode = MusicPrivateListening.shared
    private let store = MusicTastePreferences.shared

    private var prefs: MusicTastePrefs { store.prefs }

    var body: some View {
        MusicSettingsGroup(title: "Listening and recommendations", footer: "What you choose here shapes Recently Added, Radio and autoplay. Songs in genres you marked not for me are left out of them.") {
            MusicToggleRow(title: "Private listening", atlas: "control.music.settingsPrivateListening",
                           info: "While on, nothing you play is counted, kept in history, sent to a scrobbler or used for recommendations. It turns itself off when the app restarts.",
                           isOn: Binding(get: { privateMode.isOn }, set: { privateMode.isOn = $0 }))
            MusicButtonRow(title: "Set up Music again", atlas: "control.music.settingsRedoSetup", detail: nil,
                           info: "Pick languages, genres and artists again. Your earlier choices are shown, and you can change or clear any of them.", button: "Open") { MusicChromeState.shared.setupOpen = true }
            languagesRow
            genresRow
            artistsRow
            MusicButtonRow(title: "Reset recommendations", atlas: "control.music.settingsResetRecommendations", detail: MusicTasteReset.cutoff.map { Localized.string("Last reset %@", $0.formatted(date: .abbreviated, time: .omitted)) },
                           info: "Home, Radio and autoplay forget what your past plays taught them and start fresh. Your history, statistics, likes and playlists stay as they are.",
                           button: "Reset", role: .destructive) { confirmReset = true }
        }
        .task(id: MusicStats.shared.revision) { refreshStatsOptions() }
        .confirmationDialog("Reset recommendations?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }.atlas("control.music.settingsResetConfirm")
        } message: { Text("Suggestions start fresh from now. Nothing you saved is deleted.") }
    }

    private var languagesRow: some View {
        MusicSettingsRow(title: "Languages you like", atlas: "control.music.settingsPreferredLanguages", detail: summary(prefs.languages.compactMap { MusicLanguage(rawValue: $0)?.englishName }), info: nil) {
            Menu("Choose") {
                ForEach(MusicLanguage.allCases.filter { $0 != .latin }, id: \.self) { l in
                    Toggle(Localized.string(l.englishName), isOn: Binding(get: { prefs.languages.contains(l.rawValue) },
                        set: { on in store.update { if on { $0.languages.insert(l.rawValue) } else { $0.languages.remove(l.rawValue) } } }))
                }
            }.menuStyle(.button).fixedSize()
        }
    }

    private var genresRow: some View {
        let options = genreOptions
        return MusicSettingsRow(title: "Genres you like", atlas: "control.music.settingsPreferredGenres", detail: summary(Array(prefs.genres).sorted()), info: nil) {
            Menu("Choose") {
                if options.isEmpty { Text("Listen to some music first").foregroundStyle(ColorTokens.textTertiary) }
                ForEach(options, id: \.self) { g in
                    Toggle(g, isOn: Binding(get: { prefs.genres.contains(g) },
                        set: { on in store.update { if on { $0.genres.insert(g); $0.dislikedGenres.remove(g) } else { $0.genres.remove(g); $0.lovedGenres.remove(g) } } }))
                }
                if !prefs.dislikedGenres.isEmpty {
                    Divider()
                    Text("Not for me").foregroundStyle(ColorTokens.textTertiary)
                    ForEach(Array(prefs.dislikedGenres).sorted(), id: \.self) { g in
                        Toggle(g, isOn: Binding(get: { prefs.dislikedGenres.contains(g) }, set: { on in store.update { if !on { $0.dislikedGenres.remove(g) } } }))
                    }
                }
            }.menuStyle(.button).fixedSize()
        }
    }

    private var artistsRow: some View {
        MusicSettingsRow(title: "Artists you like", atlas: "control.music.settingsPreferredArtists", detail: summary(prefs.artists.map(\.name)), info: nil) {
            Menu("Choose") {
                ForEach(artistOptions, id: \.uid) { a in
                    Toggle(a.name, isOn: Binding(get: { prefs.artists.contains { $0.uid == a.uid } },
                        set: { on in store.update { p in if on { if !p.artists.contains(where: { $0.uid == a.uid }) { p.artists.append(a) } } else { p.artists.removeAll { $0.uid == a.uid } } } }))
                }
                if artistOptions.isEmpty { Text("Follow or play some artists first").foregroundStyle(ColorTokens.textTertiary) }
            }.menuStyle(.button).fixedSize()
        }
    }

    private func summary(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).map { Localized.string($0) }.joined(separator: ", ")
        return names.count > 3 ? shown + " +\(names.count - 3)" : shown
    }

    private func refreshStatsOptions() {
        store.repairArtistSources(MusicStats.shared.file, library: hub.library)
        statsTopArtists = MusicStatsEngine.report(MusicStats.shared.file, since: nil, now: Date()).topArtists
        var seen = Set<String>(), out: [String] = []
        for t in MusicStats.shared.file.songs.values.map(\.track) { for g in MusicInsightsEngine.genreLabels(t) where seen.insert(MusicText.normalize(g)).inserted { out.append(g) } }
        statsGenres = out
    }

    /// Genres seen in what the person plays and likes, plus the ones already chosen.
    private var genreOptions: [String] {
        var seen = Set<String>(prefs.genres.map { MusicText.normalize($0) })
        var out = Array(prefs.genres)
        for g in statsGenres where seen.insert(MusicText.normalize(g)).inserted { out.append(g) }
        for t in hub.library.liked { for g in MusicInsightsEngine.genreLabels(t) where seen.insert(MusicText.normalize(g)).inserted { out.append(g) } }
        // A person who has not played much can still choose from the setup's own list of genres.
        for g in MusicSetupFlow.genreVocabulary where seen.insert(MusicText.normalize(g)).inserted { out.append(g) }
        return out.sorted()
    }

    private var artistOptions: [MusicArtist] {
        MusicTasteOptions.artists(chosen: prefs.artists, followed: hub.library.followedArtists, top: statsTopArtists, usable: { hub.registry.metadataProvider(id: $0) != nil })
    }

    private func reset() {
        MusicTasteReset.mark()
        MusicHiddenRecommendations.shared.clear()
        RadioService.shared.forgetLearned()
        Task {
            // The learned affinity goes first, so the feed composed next cannot be built from it.
            await MusicRecommenderRuntime.shared.resetAffinity()
            MusicHomeFeedModel.shared.clearAll()
            MusicToasts.shared.success(Localized.string("Recommendations start fresh."))
        }
    }
}

/// The artists offered in Settings' "Artists you like" menu, each once.
enum MusicTasteOptions {
    /// The chosen artists first, then the followed ones, then the ones played most. One entry per `uid` (provider and id together), so a followed artist who is also
    /// the most played is listed once and two services' artists with one id are not mixed up. A played artist keeps the source their songs came from (an id means
    /// nothing to another one) and is offered only while that source is `usable`.
    static func artists(chosen: [MusicArtist], followed: [MusicArtist], top: [MusicTopArtist], usable: (String) -> Bool = { _ in true }) -> [MusicArtist] {
        var out = chosen
        var seen = Set(out.map(\.uid))
        for a in followed where seen.insert(a.uid).inserted { out.append(a) }
        for t in top {
            guard let id = t.linkedID, !t.providerID.isEmpty, usable(t.providerID) else { continue }
            let artist = MusicArtist(id: id, providerID: t.providerID, name: t.name, thumbnails: t.thumbnails)
            if seen.insert(artist.uid).inserted { out.append(artist) }
        }
        return out
    }

    /// Picks saved with the wrong source (an earlier version gave a played artist the source that was active) put back on the source their songs came from. A pick
    /// is moved only when nothing the person has shows it under its own source and exactly one other source has an artist with that id and name.
    static func repairingSources(_ picked: [MusicArtist], tracks: [MusicTrack], followed: [MusicArtist] = []) -> [MusicArtist] {
        guard !picked.isEmpty else { return picked }
        let ids = Set(picked.map(\.id))
        var sources: [String: Set<String>] = [:]   // "id|name" to the sources that credit it
        var known = Set(followed.map(\.uid))
        for t in tracks where !MusicStatsRules.isLocal(t) {
            for r in t.artists where ids.contains(r.id) {
                known.insert(t.providerID + ":" + r.id)
                sources[r.id + "|" + MusicText.normalize(r.name), default: []].insert(t.providerID)
            }
        }
        var seen = Set<String>()
        return picked.compactMap { a in
            var out = a
            if !known.contains(a.uid), let found = sources[a.id + "|" + MusicText.normalize(a.name)], found.count == 1, let provider = found.first {
                out = MusicArtist(id: a.id, providerID: provider, name: a.name, thumbnails: a.thumbnails, genres: a.genres)
            }
            return seen.insert(out.uid).inserted ? out : nil
        }
    }
}

extension MusicTastePreferences {
    /// Repairs the saved artist picks from what the person has played (see `MusicTasteOptions.repairingSources`). Does nothing when they are already right.
    func repairArtistSources(_ stats: MusicStatsFile, library: MusicLibrary) {
        guard !prefs.artists.isEmpty else { return }
        let fixed = MusicTasteOptions.repairingSources(prefs.artists, tracks: stats.songs.values.map(\.track) + library.liked, followed: library.followedArtists)
        if fixed != prefs.artists { update { $0.artists = fixed } }
    }
}
