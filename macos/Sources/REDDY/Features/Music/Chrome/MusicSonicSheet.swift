import SwiftUI

/// Music that sounds like a song: similar sound, songs that mix in key, songs with the same rhythm, a journey to another song, or a session that gets calmer or
/// more energetic. It works only on songs the person's own library has analysed (Settings, Music, Sound analysis), and says how many that is.
struct MusicSonicSheet: View {
    enum Mode: String, CaseIterable { case similar, key, rhythm, journey, energy }

    let hub: MusicHub
    let track: MusicTrack
    let close: () -> Void
    @State private var mode: Mode = .similar
    @State private var items: [SonicSimilarity.Item] = []
    @State private var names: [String: LocalEntry] = [:]
    @State private var own: SonicProfile?
    @State private var loaded = false
    @State private var target: SonicSimilarity.Item?
    @State private var search = ""
    @State private var calmer = false

    private func title(_ m: Mode) -> String {
        switch m {
        case .similar: Localized.string("Sounds like")
        case .key: Localized.string("Mixes in key")
        case .rhythm: Localized.string("Same rhythm")
        case .journey: Localized.string("Journey")
        case .energy: Localized.string("Energy")
        }
    }

    private var result: [SonicSimilarity.Item] {
        guard let own else { return [] }
        let me = SonicSimilarity.Item(key: track.id, profile: own)
        switch mode {
        case .similar: return SonicSimilarity.similar(to: own, excluding: track.id, in: items)
        case .key: return SonicSimilarity.compatible(with: own, excluding: track.id, in: items)
        case .rhythm: return SonicSimilarity.rhythmSimilar(to: own, excluding: track.id, in: items)
        case .journey: return target.map { SonicSimilarity.journey(from: me, to: $0, in: items, steps: 8) } ?? []
        case .energy: return SonicSimilarity.energyProgression(from: own.energy, to: calmer ? 0.15 : 0.9, count: 10, in: items.filter { $0.key != track.id })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Sounds like")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.sonicClose")
            }
            Text(verbatim: track.title).font(MusicTokens.rowTitle).lineLimit(1)
            if !loaded { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 120) }
            else if own == nil {
                Text(Localized.string("This song has not been analysed yet. Turn on sound analysis in Settings, under Music, and it is done in the background.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            } else {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text(title($0)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().atlas("control.music.sonicMode")
                Text(Localized.plural(items.count, one: "%@ analysed song in your library.", other: "%@ analysed songs in your library.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                if mode == .journey { journeyPicker }
                if mode == .energy {
                    Picker("", selection: $calmer) { Text(Localized.string("More energetic")).tag(false); Text(Localized.string("Calmer")).tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().atlas("control.music.sonicEnergy")
                }
                list
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520)
        .task { await load() }
    }

    @ViewBuilder private var journeyPicker: some View {
        if let t = target {
            HStack {
                Text(Localized.string("To: %@", names[t.key]?.title ?? "")).font(Typography.bodyMedium).lineLimit(1)
                Spacer()
                Button(Localized.string("Choose another")) { target = nil }.musicButton(.secondary, size: .compact).atlas("control.music.sonicJourneyChange")
            }
        } else {
            TextField(Localized.string("Search for the song to travel to"), text: $search).textFieldStyle(.roundedBorder).atlas("control.music.sonicJourneySearch")
            let q = MusicText.normalize(search)
            let matches = items.filter { !q.isEmpty && $0.key != track.id && MusicText.normalize((names[$0.key]?.title ?? "") + " " + (names[$0.key]?.artist ?? "")).contains(q) }.prefix(6)
            ForEach(Array(matches), id: \.key) { m in
                Button { target = m } label: { Text(verbatim: line(m)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(.plain).hoverHighlight().atlas("control.music.sonicJourneyPick")
            }
        }
    }

    private func line(_ i: SonicSimilarity.Item) -> String {
        guard let e = names[i.key] else { return i.key }
        return e.artist.isEmpty ? e.title : e.title + " · " + e.artist
    }

    private func detail(_ i: SonicSimilarity.Item) -> String {
        var parts: [String] = []
        if let b = i.profile.bpm { parts.append(Localized.string("%@ BPM", String(Int(b.rounded())))) }
        if let c = i.profile.camelot { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var list: some View {
        let r = result
        if r.isEmpty, mode != .journey || target != nil {
            Text(Localized.string("Nothing matched yet. More analysed songs make this fuller.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
        } else if !r.isEmpty {
            HStack {
                Spacer()
                Button { playAll(r) } label: { Label(Localized.string("Play all"), systemImage: "play.fill") }.musicButton(.secondary, size: .compact).atlas("control.music.sonicPlayAll")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(r, id: \.key) { i in
                        Button { play([i]) } label: {
                            HStack {
                                Text(verbatim: line(i)).font(Typography.bodyMedium).lineLimit(1)
                                Spacer()
                                Text(verbatim: detail(i)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                            }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().atlas("control.music.sonicPlay")
                    }
                }
            }
        }
    }

    private func playAll(_ r: [SonicSimilarity.Item]) { play(r) }

    private func play(_ r: [SonicSimilarity.Item]) {
        let entries = r.compactMap { names[$0.key] }
        guard !entries.isEmpty else { return }
        Task {
            var tracks: [MusicTrack] = []
            if let p = hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider { for e in entries { tracks.append(p.track(e)) } }
            if !tracks.isEmpty { hub.play(tracks, at: 0) }
        }
    }

    private func load() async {
        let records = await SonicStore.shared.all()
        let index = await LocalLibraryStore.shared.currentIndex()
        var map: [String: LocalEntry] = [:]
        for e in index.entries { map[e.id] = e }
        names = map
        own = records.first { $0.key == track.id }?.profile
        items = records.filter { !$0.profile.vector.isEmpty && map[$0.key] != nil }.map { SonicSimilarity.Item(key: $0.key, profile: $0.profile) }
        loaded = true
    }
}

/// Settings rows for sound analysis: the switch, the progress, and forgetting what was measured.
struct MusicSonicSettingsRows: View {
    let hub: MusicHub
    @State private var on = SonicJobs.isEnabled
    @State private var status = SonicJobs.Status()
    @State private var count = 0

    var body: some View {
        MusicSettingsRow(title: "Sound analysis", atlas: "control.music.settingsSonic",
                         detail: detail,
                         info: "Measures tempo, key, energy and loudness of your own songs in the background, one at a time, only while nothing is playing and the Mac is not in Low Power Mode. It lets Music find songs that sound alike. Nothing leaves your Mac.") {
            HStack {
                Toggle("", isOn: Binding(get: { on }, set: { set($0) })).toggleStyle(.switch).labelsHidden().atlas("control.music.settingsSonicToggle")
                if count > 0 {
                    Button(Localized.string("Forget")) { Task { await SonicStore.shared.clear(); count = 0 } }.atlas("control.music.settingsSonicForget")
                }
            }
        }
        .task { await refresh() }
    }

    private var detail: String {
        if !on { return Localized.string("Off") }
        if status.running, status.total > 0 {
            let line = Localized.string("%1$@ of %2$@ analysed", String(status.done), String(status.total))
            return status.waiting ? line + " · " + Localized.string("Waiting") : line
        }
        return Localized.plural(count, one: "%@ song analysed", other: "%@ songs analysed")
    }

    private func set(_ v: Bool) {
        on = v; SonicJobs.isEnabled = v
        Task {
            if v { await SonicJobs.shared.resumeIfEnabled { await MainActor.run { hub.player.isPlaying } } } else { await SonicJobs.shared.stop() }
            await refresh()
        }
    }

    private func refresh() async {
        // Polled lightly while the row is on screen.
        while !Task.isCancelled {
            status = await SonicJobs.shared.currentStatus()
            count = await SonicStore.shared.count()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
