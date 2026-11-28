import SwiftUI

// The sheets a song's menu opens: Song Information, Credits and the metadata editor for local files. What goes in them is worked out by plain functions
// (`MusicSongInfo`, `MusicSongCreditGroups`, `MusicMetadataDraft`) so it is tested without a screen; the views only draw it. A row with no value is not shown.

// MARK: - rules

struct MusicInfoRow: Equatable, Sendable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

enum MusicSongInfo {
    /// The rows of Song Information, in reading order. Anything the song does not carry is left out.
    static func rows(track t: MusicTrack, plays: Int, lastPlayed: Date?, local: LocalEntry?, providerName: String?, now: Date = Date()) -> [MusicInfoRow] {
        var out: [MusicInfoRow] = []
        func add(_ label: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            out.append(MusicInfoRow(label: Localized.string(label), value: v))
        }
        add("Title", t.title)
        add("Artist", t.artistLine)
        add("Album", t.album?.title)
        add("Album artist", local?.albumArtist)
        if let n = t.trackNumber ?? local?.trackNumber, n > 0 { add("Track", t.discNumber.map { $0 > 1 ? "\($0)-\(n)" : "\(n)" } ?? "\(n)") }
        if t.durationMs > 0 { add("Length", clock(seconds: Int(t.durationMs / 1000))) }
        add("Genre", local?.genre ?? t.creditBundle?.hints?.genre)
        if let y = local?.year ?? t.creditBundle?.hints?.year, y > 0 { add("Year", "\(y)") }
        add("Language", t.creditBundle?.hints?.language)
        add("Film", t.creditBundle?.hints?.film)
        add("ISRC", t.isrc)
        if t.explicit { add("Content", Localized.string("Explicit")) }
        if let l = local {
            add("Format", l.ext.uppercased())
            add("File", (l.path as NSString).lastPathComponent)
            add("Folder", l.folderPath)
        }
        add("Plays", plays > 0 ? "\(plays)" : Localized.string("Not played yet"))
        if let d = lastPlayed { add("Last played", d.formatted(date: .abbreviated, time: .shortened)) }
        return out
    }

    static func clock(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum MusicSongCreditGroups {
    struct Group: Equatable, Sendable, Identifiable {
        var title: String
        var names: [String]
        var id: String { title }
    }

    static func title(for role: MusicCreditRole) -> String {
        switch role {
        case .primary: Localized.string("Main artist")
        case .featured: Localized.string("Featured")
        case .singer: Localized.string("Singer")
        case .performer: Localized.string("Performer")
        case .music: Localized.string("Music by")
        case .composer: Localized.string("Composer")
        case .lyricist: Localized.string("Lyricist")
        case .writer: Localized.string("Writer")
        case .starring: Localized.string("Starring")
        case .producer: Localized.string("Producer")
        case .conductor: Localized.string("Conductor")
        case .arranger: Localized.string("Arranger")
        case .remixer: Localized.string("Remixer")
        case .albumArtist: Localized.string("Album artist")
        case .other: Localized.string("Also credited")
        }
    }

    /// People grouped by the role the source gave them, in a fixed order. When the source sent no credits, the song's own artists stand as the main artists.
    static func groups(for t: MusicTrack) -> [Group] {
        var byRole: [MusicCreditRole: [String]] = [:]
        for c in t.creditBundle?.credits ?? [] where c.level != .film || c.role == .starring {
            let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let line = (c.instrument?.isEmpty == false) ? "\(name) · \(c.instrument!)" : name
            if !(byRole[c.role] ?? []).contains(line) { byRole[c.role, default: []].append(line) }
        }
        if byRole[.primary] == nil, byRole[.singer] == nil {
            let names = t.artists.map(\.name).filter { !MusicArtistFiller.isFiller($0) }
            if !names.isEmpty { byRole[.primary] = names }
        }
        let order: [MusicCreditRole] = [.primary, .featured, .singer, .performer, .albumArtist, .music, .composer, .lyricist, .writer, .arranger, .producer, .conductor, .remixer, .starring, .other]
        return order.compactMap { r in byRole[r].map { Group(title: title(for: r), names: $0) } }
    }
}

/// What the tag editor starts from and what it saves. Songs that disagree on a field show "Different values" and keep each value unless the person types one.
struct MusicMetadataDraft: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var text = ""
        var mixed = false
    }
    var title = Field(), artist = Field(), album = Field(), albumArtist = Field(), genre = Field(), year = Field(), track = Field(), disc = Field()

    static func initial(_ entries: [LocalEntry]) -> MusicMetadataDraft {
        func field(_ value: (LocalEntry) -> String?) -> Field {
            let all = Set(entries.map { value($0) ?? "" })
            if all.count == 1 { return Field(text: all.first ?? "", mixed: false) }
            return Field(text: "", mixed: true)
        }
        return MusicMetadataDraft(title: field { $0.title }, artist: field { $0.artist }, album: field { $0.album }, albumArtist: field { $0.albumArtist },
                                  genre: field { $0.genre }, year: field { $0.year.map(String.init) }, track: field { $0.trackNumber.map(String.init) },
                                  disc: field { $0.discNumber.map(String.init) })
    }

    /// Only what the person typed changes; an untouched "Different values" field is left alone.
    func patch() -> LocalEntryPatch {
        func text(_ f: Field) -> String? { f.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : f.text }
        func number(_ f: Field) -> Int? { Int(f.text.trimmingCharacters(in: .whitespaces)) }
        return LocalEntryPatch(title: text(title), artist: text(artist), album: text(album), albumArtist: text(albumArtist), genre: text(genre),
                               year: number(year), trackNumber: number(track), discNumber: number(disc))
    }
}

/// Carries a saved edit into the copies of a song kept in playlists, so they read the same as the library does.
enum MusicTrackEdit {
    static func applying(_ p: LocalEntryPatch, to t: MusicTrack) -> MusicTrack {
        var out = t
        if let v = p.title?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { out.title = v }
        if let v = p.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, let first = out.artists.first { out.artists[0] = MusicArtistRef(id: first.id, name: v, thumbnails: first.thumbnails, externalURL: first.externalURL) }
        if let v = p.album?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, var al = out.album { al.title = v; out.album = al }
        if let n = p.trackNumber, n > 0 { out.trackNumber = n }
        if let n = p.discNumber, n > 0 { out.discNumber = n }
        return out
    }
}

// MARK: - sheets

private struct MusicSheetFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(title).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.trackSheetClose")
            }
            content
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 280)
    }
}

private struct MusicTrackHeadline: View {
    let hub: MusicHub
    let track: MusicTrack
    var body: some View {
        HStack(spacing: MusicSpace.md) {
            MusicCoverImage(thumbs: track.thumbnails, size: 64, corner: MusicCorner.card)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(MusicTokens.rowTitle).lineLimit(2)
                Text(track.displayArtistLine).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Song Information: the facts the app holds about a song.
struct MusicSongInfoSheet: View {
    let hub: MusicHub
    let track: MusicTrack
    let close: () -> Void
    @State private var local: LocalEntry?
    @State private var sonic: SonicProfile?
    @State private var ragas: [String] = []

    private var rows: [MusicInfoRow] {
        base + (ragas.isEmpty ? [] : [MusicInfoRow(label: Localized.string("Raga"), value: ragas.joined(separator: ", "))]) + MusicSonicRows.rows(sonic)
    }

    private var base: [MusicInfoRow] {
        let uidRecords = hub.library.history.filter { $0.track.uid == track.uid }
        return MusicSongInfo.rows(track: track, plays: uidRecords.count, lastPlayed: uidRecords.map(\.at).max(), local: local,
                                  providerName: hub.registry.provider(id: track.providerID)?.info.name)
    }

    var body: some View {
        MusicSheetFrame(title: Localized.string("Song information"), close: close) {
            MusicTrackHeadline(hub: hub, track: track)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.label).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).frame(width: 110, alignment: .leading)
                            if r.id == Localized.string("Raga"), let first = ragas.first {
                                // The raga opens the Ragas window on it, to see the other songs set in it.
                                Button { close(); MusicChromeState.shared.ragaRequest = MusicRagaRequest(raga: first) } label: {
                                    Text(r.value).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(ColorTokens.textPrimary).underline().atlas("control.music.songInfoRaga")
                            } else {
                                Text(r.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 7)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .task {
            // The raga documented for the song (Wikipedia's list of film songs based on ragas), matched on title together with the film or an artist.
            let rows = await MusicRagaCatalog.shared.songs(online: MusicEntityArtwork.shared.networkAllowed())
            ragas = MusicRagaIndex(rows).ragas(title: track.title, film: track.album?.title, artists: track.artists.map(\.name))
            guard track.providerID == MusicStatsRules.localProviderID else { return }
            local = await LocalLibraryStore.shared.currentIndex().entry(id: track.id)
            sonic = await SonicStore.shared.profile(for: track.id)
        }
    }
}

/// Credits: who made the song, as the source named them.
struct MusicCreditsSheet: View {
    let hub: MusicHub
    let track: MusicTrack
    let close: () -> Void

    var body: some View {
        let groups = MusicSongCreditGroups.groups(for: track)
        MusicSheetFrame(title: Localized.string("Credits"), close: close) {
            MusicTrackHeadline(hub: hub, track: track)
            if groups.isEmpty {
                Text(Localized.string("This song has no credits yet.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.lg)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.md) {
                        ForEach(groups) { g in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(g.title).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                                ForEach(g.names, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Edit local metadata for one song or several at once. The changes live in StreamSetu's library; the files are not rewritten.
struct MusicMetadataEditorSheet: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    let close: () -> Void
    @State private var draft = MusicMetadataDraft()
    @State private var ready = false
    @State private var writeToFiles = false

    private var ids: Set<String> { Set(tracks.map(\.id)) }

    var body: some View {
        MusicSheetFrame(title: tracks.count > 1 ? Localized.plural(tracks.count, one: "Edit %@ song", other: "Edit %@ songs") : Localized.string("Edit song details"), close: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.sm) {
                    field("Title", $draft.title, "control.music.metaTitle")
                    field("Artist", $draft.artist, "control.music.metaArtist")
                    field("Album", $draft.album, "control.music.metaAlbum")
                    field("Album artist", $draft.albumArtist, "control.music.metaAlbumArtist")
                    field("Genre", $draft.genre, "control.music.metaGenre")
                    HStack(spacing: MusicSpace.sm) {
                        field("Year", $draft.year, "control.music.metaYear")
                        field("Track", $draft.track, "control.music.metaTrack")
                        field("Disc", $draft.disc, "control.music.metaDisc")
                    }
                }
            }
            Toggle(Localized.string("Also write these changes into the music files"), isOn: $writeToFiles).toggleStyle(.switch).atlas("control.music.metaWriteFiles")
            Text(Localized.string(writeToFiles ? "The files are updated too (MP3 and M4A). Covers, lyrics and other tags stay as they are." : "Changes are saved in StreamSetu. Your music files are not changed.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            HStack {
                Spacer()
                Button(Localized.string("Cancel"), action: close).musicButton(.secondary).atlas("control.music.metaCancel")
                Button(Localized.string("Save")) { save() }.musicButton(.primary).keyboardShortcut(.defaultAction).disabled(draft.patch().isEmpty).atlas("control.music.metaSave")
            }
        }
        .task {
            let index = await LocalLibraryStore.shared.currentIndex()
            draft = MusicMetadataDraft.initial(tracks.compactMap { index.entry(id: $0.id) })
            ready = true
        }
    }

    private func field(_ label: String, _ f: Binding<MusicMetadataDraft.Field>, _ atlas: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Localized.string(label)).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            TextField(f.wrappedValue.mixed ? Localized.string("Different values") : "", text: f.text).textFieldStyle(.roundedBorder).atlas(atlas)
        }
    }

    private func save() {
        let patch = draft.patch()
        let chosen = ids
        Task { @MainActor in
            let n = await LocalLibraryStore.shared.edit(ids: chosen, patch: patch)
            if writeToFiles {
                let r = await LocalLibraryStore.shared.writeTags(ids: chosen, patch: patch)
                var parts = [Localized.plural(r.written, one: "Wrote %@ file.", other: "Wrote %@ files.")]
                if r.unsupported > 0 { parts.append(Localized.plural(r.unsupported, one: "%@ file is in a format that cannot be tagged.", other: "%@ files are in a format that cannot be tagged.")) }
                if r.failed > 0 { parts.append(Localized.plural(r.failed, one: "%@ file could not be written.", other: "%@ files could not be written.")) }
                if r.blocked > 0 { parts.append(Localized.plural(r.blocked, one: "%@ file was left alone (read-only collection or locked).", other: "%@ files were left alone (read-only collection or locked).")) }
                MusicToasts.shared.show(parts.joined(separator: " "), kind: r.failed > 0 ? .error : .success)
            }
            for p in hub.library.playlists where p.tracks.contains(where: { chosen.contains($0.id) && $0.providerID == MusicStatsRules.localProviderID }) {
                hub.library.replaceTracks(p.tracks.map { chosen.contains($0.id) && $0.providerID == MusicStatsRules.localProviderID ? MusicTrackEdit.applying(patch, to: $0) : $0 }, in: p.id)
            }
            MusicToasts.shared.success(Localized.plural(n, one: "Saved %@ song.", other: "Saved %@ songs."))
            close()
        }
    }
}
