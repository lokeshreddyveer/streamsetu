import SwiftUI
import UniformTypeIdentifiers

// The screens of rule-based smart playlists and of playlist files, in the Playlists tab of Your library: a row to start one, the list of smart playlists, the
// editor where the rules are written (with a live count), the page that shows what matches now, and the sheet that reads a playlist file into a new playlist.

/// The row under the folders in the Playlists tab: smart playlists and "Import a playlist file".
struct MusicLibraryPlaylistToolsBar: View {
    let hub: MusicHub
    @State private var editing: MusicSmartPlaylist?
    @State private var opened: UUID?
    @State private var importing = false
    @State private var picked: URL?

    private var book: MusicSmartRuleBook { hub.library.smartRules }
    private static let types: [UTType] = [UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8"), .json, .plainText].compactMap { $0 }

    var body: some View {
        let _ = book.revision
        HStack(spacing: MusicSpace.xs) {
            Label(Localized.string("Smart playlists"), systemImage: "wand.and.stars").musicText(.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MusicSpace.xxs) {
                    ForEach(book.lists) { l in
                        MusicChip(title: l.name, selected: false) { opened = l.id }
                            .contextMenu {
                                Button(Localized.string("Edit…")) { editing = l }.atlas("control.music.smartEdit")
                                Button(Localized.string("Duplicate")) { book.duplicate(l.id) }.atlas("control.music.smartDuplicate")
                                Button(Localized.string("Delete"), role: .destructive) { book.delete(l.id) }.atlas("control.music.smartDelete")
                            }.atlas("control.music.smartChipMenu")
                    }
                    Button { editing = MusicSmartPlaylist(name: "", conditions: [MusicSmartCondition(field: .liked, op: .isTrue)]) } label: {
                        Label(Localized.string("New smart playlist"), systemImage: "plus")
                    }
                    .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Create a smart playlist from rules")).atlas("control.music.smartNew")
                }
            }
            Spacer(minLength: 0)
            Button { importing = true } label: { Label(Localized.string("Import playlist file"), systemImage: "square.and.arrow.down") }
                .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Make a playlist from an M3U, M3U8 or JSON file")).atlas("control.music.playlistImportFile")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
            if case .success(let url) = result { picked = url }
        }
        .sheet(item: $editing) { draft in MusicSmartRuleEditor(hub: hub, draft: draft) { editing = nil } }
        .sheet(item: Binding(get: { opened.map { SmartID(id: $0) } }, set: { opened = $0?.id })) { s in
            MusicSmartRulePage(hub: hub, id: s.id, edit: { l in opened = nil; editing = l }) { opened = nil }
        }
        .sheet(item: Binding(get: { picked.map { PickedFile(url: $0) } }, set: { picked = $0?.url })) { f in
            MusicPlaylistImportSheet(hub: hub, url: f.url) { picked = nil }
        }
    }

    private struct SmartID: Identifiable { var id: UUID }
    private struct PickedFile: Identifiable { var url: URL; var id: String { url.absoluteString } }
}

/// Where the rules are written: a name, "all/any", one row per rule, how to sort and how many to keep, and a live count of what matches.
struct MusicSmartRuleEditor: View {
    let hub: MusicHub
    let dismiss: () -> Void
    @State private var draft: MusicSmartPlaylist

    init(hub: MusicHub, draft: MusicSmartPlaylist, dismiss: @escaping () -> Void) { self.hub = hub; self.dismiss = dismiss; _draft = State(initialValue: draft) }

    private var matches: [MusicTrack] { hub.library.smartTracks(for: draft) }
    private var canSave: Bool { draft.conditions.contains(where: MusicSmartEvaluator.isComplete) }

    var body: some View {
        let found = matches
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Smart playlist")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
            }
            TextField(Localized.string("Name"), text: $draft.name).textFieldStyle(.roundedBorder)
            HStack(spacing: MusicSpace.xs) {
                Text(Localized.string("Songs that match")).foregroundStyle(ColorTokens.textSecondary)
                Picker("", selection: $draft.match) { ForEach(MusicSmartMatch.allCases) { Text($0.title).tag($0) } }.atlas("control.music.smartMatch").labelsHidden().fixedSize()
            }
            .musicText(.secondary)
            VStack(spacing: MusicSpace.xs) {
                ForEach($draft.conditions) { $c in ruleRow($c) }
            }
            Button { draft.conditions.append(MusicSmartCondition(field: .title, op: .contains)) } label: { Label(Localized.string("Add a rule"), systemImage: "plus.circle") }
                .musicButton(.tertiary, size: .compact).atlas("control.music.smartAddRule")
            HStack(spacing: MusicSpace.md) {
                HStack(spacing: MusicSpace.xs) {
                    Text(Localized.string("Sort by")).foregroundStyle(ColorTokens.textSecondary)
                    Picker("", selection: $draft.sort) { ForEach(MusicSmartSort.allCases) { Text($0.title).tag($0) } }.atlas("control.music.smartSort").labelsHidden().fixedSize()
                }
                Stepper(value: $draft.limit, in: 0...500, step: 25) {
                    Text(draft.limit == 0 ? Localized.string("No limit") : Localized.string("At most %@ songs", draft.limit.formatted()))
                }
            }
            .musicText(.secondary)
            Divider()
            HStack {
                Text(Localized.plural(found.count, one: "%@ song matches now", other: "%@ songs match now")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button(Localized.string("Cancel"), action: dismiss).musicButton(.secondary).atlas("control.music.playlistToolsCancel")
                Button(Localized.string("Save")) { hub.library.smartRules.save(draft); dismiss() }
                    .musicButton(.primary).disabled(!canSave).atlas("control.music.smartSave")
            }
        }
        .padding(MusicSpace.lg).frame(width: 560)
    }

    private func ruleRow(_ c: Binding<MusicSmartCondition>) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Picker("", selection: Binding(get: { c.wrappedValue.field }, set: { f in
                c.wrappedValue.field = f
                if !f.operators.contains(c.wrappedValue.op) { c.wrappedValue.op = f.operators[0] }
                if f.kind == .flag { c.wrappedValue.value = "" }
            })) { ForEach(MusicSmartField.allCases) { Text($0.title).tag($0) } }.atlas("control.music.smartField").labelsHidden().frame(width: 190)
            Picker("", selection: c.op) { ForEach(c.wrappedValue.field.operators) { Text($0.title).tag($0) } }.atlas("control.music.smartOperator").labelsHidden().frame(width: 140)
            if c.wrappedValue.field.kind != .flag {
                TextField(Localized.string("Value"), text: c.value).textFieldStyle(.roundedBorder)
            } else {
                Spacer(minLength: 0)
            }
            Button { draft.conditions.removeAll { $0.id == c.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(Localized.string("Remove this rule")).atlas("control.music.smartRemoveRule")
        }
    }
}

/// What a smart playlist holds now: Play, Shuffle, keep it as an ordinary playlist, edit the rules, delete.
struct MusicSmartRulePage: View {
    let hub: MusicHub
    let id: UUID
    let edit: (MusicSmartPlaylist) -> Void
    let dismiss: () -> Void
    @State private var seed: UInt64 = 1

    var body: some View {
        if let list = hub.library.smartRules.list(id: id) {
            let tracks = hub.library.smartTracks(for: list, seed: seed)
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        Text(verbatim: list.name).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                        Text(verbatim: MusicSmartEvaluator.summary(list)).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                        Text(Localized.plural(tracks.count, one: "%@ song", other: "%@ songs")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                    Spacer()
                    Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
                }
                HStack(spacing: MusicSpace.sm) {
                    MusicPlayShuffleButtons(hub: hub, tracks: tracks)
                    Button(Localized.string("Keep as playlist")) {
                        let made = hub.library.createPlaylist(name: list.name, tracks: tracks)
                        MusicToasts.shared.show(Localized.string("Made “%@”.", made.name), kind: .success)
                    }
                    .musicButton(.secondary).disabled(tracks.isEmpty).atlas("control.music.smartKeep")
                    Button(Localized.string("Edit rules…")) { edit(list) }.musicButton(.secondary).atlas("control.music.smartEdit")
                    if list.sort == .random { Button { seed &+= 1 } label: { Image(systemName: "shuffle") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Draw again")).atlas("control.music.smartRedraw") }
                }
                if tracks.isEmpty {
                    MusicEmptyState(symbol: "wand.and.stars", title: Localized.string("Nothing matches yet"), message: Localized.string("Change the rules, or listen to more music, and this list fills itself."))
                        .frame(minHeight: 180)
                } else {
                    MusicTrackList(hub: hub, tracks: tracks, listKey: "smart:" + id.uuidString, showsAlbumByDefault: true, presorted: true)
                        .frame(minHeight: 300)
                }
            }
            .padding(MusicSpace.lg).frame(width: 760, height: 640)
        } else {
            MusicEmptyState(symbol: "wand.and.stars", title: Localized.string("This smart playlist is gone"), message: "").frame(width: 420, height: 240)
        }
    }
}

/// Reads one playlist file, finds each song, and makes a playlist from what was found. Songs that could not be found are listed, never dropped silently.
struct MusicPlaylistImportSheet: View {
    let hub: MusicHub
    let url: URL
    let dismiss: () -> Void
    private enum Phase { case reading, looking, done, failed }
    @State private var phase = Phase.reading
    @State private var file = MusicPlaylistFile(name: nil, description: nil, entries: [])
    @State private var found: [MusicTrack] = []
    @State private var missing: [MusicPlaylistFileEntry] = []
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Import a playlist")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
            }
            Text(verbatim: url.lastPathComponent).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            switch phase {
            case .reading, .looking:
                HStack(spacing: MusicSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text(phase == .reading ? Localized.string("Reading the file…") : Localized.plural(file.entries.count, one: "Finding %@ song…", other: "Finding %@ songs…"))
                        .foregroundStyle(ColorTokens.textSecondary)
                }
                .padding(.vertical, MusicSpace.lg)
            case .failed:
                MusicEmptyState(symbol: "exclamationmark.triangle", title: Localized.string("No songs in this file"), message: Localized.string("The file has no songs this app can read. M3U, M3U8 and JSON playlists work.")).frame(minHeight: 160)
            case .done:
                TextField(Localized.string("Name"), text: $name).textFieldStyle(.roundedBorder)
                Text(Localized.plural(found.count, one: "%@ song found.", other: "%@ songs found.")).foregroundStyle(ColorTokens.textPrimary)
                if !missing.isEmpty {
                    Text(Localized.plural(missing.count, one: "%@ song was not found:", other: "%@ songs were not found:")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(missing.enumerated()), id: \.offset) { _, e in
                                Text(verbatim: e.searchText).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                HStack {
                    Spacer()
                    Button(Localized.string("Cancel"), action: dismiss).musicButton(.secondary).atlas("control.music.playlistToolsCancel")
                    Button(Localized.string("Create playlist")) {
                        let made = hub.library.makePlaylist(fromImport: name, tracks: found)
                        MusicToasts.shared.show(Localized.string("Made “%@”.", made.name), kind: .success)
                        dismiss(); hub.open(.localPlaylist(made.id))
                    }
                    .musicButton(.primary).disabled(found.isEmpty).atlas("control.music.playlistImportCreate")
                }
            }
        }
        .padding(MusicSpace.lg).frame(width: 480)
        .task { await load() }
    }

    private func load() async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { phase = .failed; return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed: MusicPlaylistFile
        switch MusicPlaylistFileFormat.detect(fileName: url.lastPathComponent, text: text) {
        case .json: parsed = MusicPlaylistJSON.parse(data)
        case .m3u8, .m3u: parsed = MusicPlaylistM3U.parse(text)
        }
        MusicDebugLog.log("playlist", "import read \(parsed.entries.count) entries from \(url.pathExtension)")
        guard !parsed.entries.isEmpty else { phase = .failed; return }
        file = parsed
        name = parsed.name ?? (url.deletingPathExtension().lastPathComponent)
        phase = .looking
        let provider = hub.registry.activeMetadata
        let result = await MusicPlaylistImporter.resolve(parsed.entries, search: { q in
            guard let provider, let page = try? await provider.searchTracks(q, page: nil) else { return [] }
            return page.items
        })
        found = result.found; missing = result.missing
        MusicDebugLog.log("playlist", "import found \(found.count) of \(parsed.entries.count)")
        phase = .done
    }
}
