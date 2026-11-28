import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Classical music in the raga browser: the ragas a curated dataset (Saraga) documents, and the recordings that document each. The data is never shipped with the
/// app: the person points the app at a copy they downloaded, and only its metadata files are read. Each recording shows exactly what the dataset says; nothing is
/// added. A song gets a raga from this layer only through a matching MusicBrainz recording id.
struct MusicClassicalPane: View {
    let hub: MusicHub
    @State private var index = ClassicalIndex()
    @State private var loaded = false
    @State private var tradition: ClassicalTradition?
    @State private var query = ""
    @State private var showTalas = false
    @State private var selected: String?
    @State private var importing = false
    @State private var scanned = 0
    @State private var note: String?
    @State private var playing: String?
    @State private var importTask: Task<Void, Never>?
    @Environment(\.reddyAccent) private var accent

    @State private var ragas: [ClassicalRagaEntry] = []
    private var current: ClassicalRagaEntry? { ragas.first { $0.id == selected } ?? ragas.first }
    /// The list is worked out when what it depends on changes, not on every redraw.
    private func refresh() { ragas = index.search(query, talas: showTalas).filter { tradition == nil || $0.tradition == tradition } }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if !loaded { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 160) }
            else if index.recordings.isEmpty { emptyState }
            else { content }
        }
        .task { index = await ClassicalCatalog.shared.current(); loaded = true; refresh() }
        .onChange(of: index) { _, _ in refresh() }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: showTalas) { _, _ in refresh() }
        .onChange(of: tradition) { _, _ in refresh() }
        .onDisappear { importTask?.cancel() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("Classical ragas and talas come from the Saraga dataset of Carnatic and Hindustani recordings. It is not part of the app. Download it from its project page, then choose its folder here; only the annotation files are read, never the audio.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            importRow
        }.padding(.vertical, MusicSpace.md)
    }

    @ViewBuilder private var importRow: some View {
        #if os(macOS)
        HStack {
            Button(Localized.string("Choose dataset folder…")) { chooseFolder() }.musicButton(.primary, size: .compact).disabled(importing).atlas("control.music.classicalImport")
            if importing {
                Text(Localized.plural(scanned, one: "Read %@ file", other: "Read %@ files")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                Button(Localized.string("Stop")) { importTask?.cancel() }.musicButton(.secondary, size: .compact).atlas("control.music.classicalImportStop")
            }
        }
        #endif
        if let note { Text(verbatim: note).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: MusicSpace.md) {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicChoiceChips(options: [(value: ClassicalTradition?.none, title: Localized.string("Both")), (value: Optional(ClassicalTradition.carnatic), title: Localized.string("Carnatic")),
                                           (value: Optional(ClassicalTradition.hindustani), title: Localized.string("Hindustani"))], selection: $tradition)
                    .atlas("control.music.classicalTradition")
                MusicChoiceChips(options: [(value: false, title: Localized.string("Ragas")), (value: true, title: Localized.string("Talas"))], selection: $showTalas)
                    .atlas("control.music.classicalKind")
                MusicSheetField(placeholder: Localized.string(showTalas ? "Search talas" : "Search ragas"), text: $query, atlas: "control.music.classicalSearch")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ragas) { e in
                            Button { selected = e.id } label: {
                                HStack {
                                    Text(verbatim: e.name).font(Typography.bodyMedium).lineLimit(1)
                                    Spacer()
                                    Text(verbatim: "\(e.recordings.count)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit()
                                }.padding(.horizontal, 8).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                                    .background(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).fill(e.id == current?.id ? accent.opacity(0.16) : .clear))
                            }.buttonStyle(.plain).atlas("control.music.classicalChoose")
                        }
                    }
                }
                importRow
            }.frame(width: 220)
            recordingList
        }
    }

    @ViewBuilder private var recordingList: some View {
        if let e = current {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(verbatim: ([Localized.string(e.tradition == .carnatic ? "Carnatic" : "Hindustani")] + e.aliases).joined(separator: " · ")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(e.recordings) { r in
                            Button { play(r) } label: {
                                HStack(spacing: MusicSpace.sm) {
                                    Image(systemName: playing == r.id ? "waveform" : "play.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: r.title).font(Typography.bodyMedium).lineLimit(1)
                                        Text(verbatim: detail(r)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }.buttonStyle(.plain).hoverHighlight().atlas("control.music.classicalPlay")
                        }
                    }
                }
            }
        }
    }

    private func detail(_ r: ClassicalRecording) -> String {
        let people = r.artists.prefix(3).map(\.name).joined(separator: ", ")
        let talas = r.talas.map(\.name).joined(separator: ", ")
        return [people, talas.isEmpty ? "" : Localized.string("Tala: %@", talas), r.forms.joined(separator: ", "), r.concert ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Finds the recording on the person's own sources, accepting only a close match of title and lead artist.
    private func play(_ r: ClassicalRecording) {
        playing = r.id
        Task {
            let lead = r.artists.first?.name ?? ""
            for p in hub.registry.metadata {
                guard let page = try? await p.searchTracks(r.title + " " + lead, page: nil) else { continue }
                if let hit = page.items.first(where: { MusicRelatedMatch.titleScore(r.title, $0.title) >= MusicRelatedMatch.accept && (lead.isEmpty || $0.artists.contains { MusicRelatedMatch.nameScore(lead, $0.name) >= MusicRelatedMatch.accept }) })
                { hub.play([hit], at: 0); return }
            }
            MusicToasts.shared.show(Localized.string("Could not find “%@” to play.", r.title))
            playing = nil
        }
    }

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = Localized.string("Choose the folder of the downloaded Saraga dataset")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true; scanned = 0; note = nil
        importTask = Task.detached(priority: .utility) {
            let report = await ClassicalCatalog.shared.importDataset(from: url) { n in Task { @MainActor in scanned = n } }
            let fresh = await ClassicalCatalog.shared.current()
            await MainActor.run {
                importing = false
                index = fresh
                note = report.cancelled ? Localized.string("Stopped. Nothing was changed.")
                    : (report.imported == 0 ? Localized.string("No annotation files were found in that folder.") : Localized.plural(report.imported, one: "Imported %@ recording.", other: "Imported %@ recordings."))
            }
        }
    }
    #endif
}
