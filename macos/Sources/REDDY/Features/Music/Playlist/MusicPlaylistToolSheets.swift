import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// Sheets and actions for the playlist tools: merge with other playlists, find and remove repeated songs, the playlist's numbers, and writing a playlist to
// a file. The rules live in the Services layer; these views only ask the person and call them.

/// Pick other playlists to combine with this one into a new playlist.
struct MusicPlaylistMergeSheet: View {
    let hub: MusicHub
    let source: UUID
    let dismiss: () -> Void
    @State private var chosen: Set<UUID> = []
    @State private var name = ""
    @State private var dropRepeats = true
    @State private var deleteSources = false

    private var others: [LocalPlaylist] { hub.library.playlists.filter { $0.id != source } }
    private var current: LocalPlaylist? { hub.library.playlist(id: source) }
    private var ids: [UUID] { [source] + others.filter { chosen.contains($0.id) }.map(\.id) }
    private var preview: Int {
        let lists = ids.compactMap { id in hub.library.playlist(id: id)?.tracks }
        return MusicPlaylistMerge.merge(lists, dropRepeats: dropRepeats).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Merge playlists")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
            }
            Text(Localized.string("Choose the playlists to combine with “%@”. The originals stay as they are unless you choose to remove them.", current?.name ?? ""))
                .musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            if others.isEmpty {
                Text(Localized.string("You have no other playlists to merge with.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.md)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(others) { p in
                            Button {
                                if chosen.contains(p.id) { chosen.remove(p.id) } else { chosen.insert(p.id) }
                            } label: {
                                HStack(spacing: MusicSpace.sm) {
                                    Image(systemName: chosen.contains(p.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen.contains(p.id) ? ColorTokens.accentDefault : ColorTokens.textTertiary)
                                    Text(verbatim: p.name).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(Localized.plural(p.tracks.count, one: "%@ song", other: "%@ songs")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                                }
                                .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverHighlight()
                            .accessibilityAddTraits(chosen.contains(p.id) ? .isSelected : [])
                            .atlas("control.music.playlistMergeChoice")
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            TextField(Localized.string("Name of the new playlist"), text: $name).textFieldStyle(.roundedBorder)
            Toggle(Localized.string("Leave out songs that appear more than once"), isOn: $dropRepeats).atlas("control.music.playlistMergeDrop")
            Toggle(Localized.string("Remove the original playlists afterwards"), isOn: $deleteSources).atlas("control.music.playlistMergeDelete")
            HStack {
                Text(Localized.plural(preview, one: "%@ song in the new playlist", other: "%@ songs in the new playlist")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button(Localized.string("Cancel"), action: dismiss).musicButton(.secondary).atlas("control.music.playlistToolsCancel")
                Button(Localized.string("Merge")) {
                    if let made = hub.library.mergePlaylists(ids, name: name, dropRepeats: dropRepeats, deleteSources: deleteSources) {
                        MusicToasts.shared.show(Localized.string("Made “%@”.", made.name), kind: .success)
                        dismiss()
                        if deleteSources { hub.nav.select(.library) } else { hub.open(.localPlaylist(made.id)) }
                    }
                }
                .musicButton(.primary).disabled(chosen.isEmpty).atlas("control.music.playlistMerge")
            }
        }
        .padding(MusicSpace.lg).frame(width: 460)
    }
}

/// The repeated songs of a playlist, listed, with one button to take the extra copies out (Undo puts them back).
struct MusicPlaylistRepeatsSheet: View {
    let hub: MusicHub
    let id: UUID
    let dismiss: () -> Void

    private var tracks: [MusicTrack] { hub.library.playlist(id: id)?.tracks ?? [] }

    var body: some View {
        let groups = MusicPlaylistDuplicates.groups(tracks)
        let extra = groups.reduce(0) { $0 + $1.count - 1 }
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Repeated songs")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
            }
            if groups.isEmpty {
                MusicEmptyState(symbol: "checkmark.circle", title: Localized.string("No repeated songs"), message: Localized.string("Every song in this playlist appears once.")).frame(minHeight: 160)
            } else {
                Text(Localized.plural(extra, one: "%@ extra copy found. The first copy of each song stays.", other: "%@ extra copies found. The first copy of each song stays."))
                    .musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                            HStack(spacing: MusicSpace.sm) {
                                if let first = g.tracks.first {
                                    MusicArtwork(track: first, size: 40, corner: MusicCorner.control)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: first.title).musicText(.card).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                                        Text(verbatim: first.displayArtistLine).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(Localized.string("× %@", g.count.formatted())).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                HStack {
                    Spacer()
                    Button(Localized.string("Cancel"), action: dismiss).musicButton(.secondary).atlas("control.music.playlistToolsCancel")
                    Button(Localized.plural(extra, one: "Remove %@ copy", other: "Remove %@ copies")) {
                        MusicPlaylistUndo.perform(hub: hub, playlist: id, message: Localized.string("Removed repeated songs. Undo to put them back.")) { _ = hub.library.removeRepeats(in: id) }
                        dismiss()
                    }
                    .musicButton(.primary).atlas("control.music.playlistRemoveRepeats")
                }
            }
        }
        .padding(MusicSpace.lg).frame(width: 460)
    }
}

/// The playlist's numbers: size, length, artists, and how it has been listened to.
struct MusicPlaylistStatsSheet: View {
    let hub: MusicHub
    let id: UUID
    let dismiss: () -> Void

    var body: some View {
        let p = hub.library.playlist(id: id)
        let s = MusicPlaylistListening.summary(tracks: p?.tracks ?? [], history: hub.library.history)
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Statistics")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular).accessibilityLabel(Localized.string("Close")).atlas("control.music.playlistToolsClose")
            }
            VStack(spacing: 0) {
                row(Localized.string("Songs"), s.songs.formatted())
                row(Localized.string("Length"), MusicPlaylistListening.lengthWords(seconds: s.totalSeconds).isEmpty ? "—" : MusicPlaylistListening.lengthWords(seconds: s.totalSeconds))
                row(Localized.string("Artists"), s.artists.formatted())
                row(Localized.string("Albums"), s.albums.formatted())
                row(Localized.string("Times played"), s.plays.formatted())
                row(Localized.string("Songs played at least once"), "\(s.songsPlayed.formatted()) / \(s.songs.formatted())")
                row(Localized.string("Never played"), s.neverPlayed.formatted())
                if let d = s.lastPlayed { row(Localized.string("Last played"), d.formatted(.relative(presentation: .named))) }
                if s.longestSeconds > 0 { row(Localized.string("Longest song"), MusicPlaylistListening.lengthWords(seconds: s.longestSeconds)) }
                if s.repeats > 0 { row(Localized.string("Repeated songs"), s.repeats.formatted()) }
            }
            .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
            if !s.topArtists.isEmpty {
                Text(Localized.string("Most songs by")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                ForEach(Array(s.topArtists.enumerated()), id: \.offset) { _, a in
                    HStack { Text(verbatim: a.name).foregroundStyle(ColorTokens.textPrimary); Spacer(); Text(a.songs.formatted()).foregroundStyle(ColorTokens.textSecondary) }.musicText(.secondary)
                }
            }
        }
        .padding(MusicSpace.lg).frame(width: 420)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(verbatim: label).foregroundStyle(ColorTokens.textSecondary); Spacer(); Text(verbatim: value).foregroundStyle(ColorTokens.textPrimary) }
            .musicText(.secondary).padding(.horizontal, MusicSpace.md).frame(minHeight: 34)
    }
}

// MARK: - files

/// Writes a playlist to a file the person chooses. Mac: a save panel. Elsewhere the file is written to a temporary place and the system share sheet is not
/// offered from here, so the action says it needs the Mac app.
enum MusicPlaylistFileActions {
    static func contents(of p: LocalPlaylist, format: MusicPlaylistFileFormat, description: String?) -> Data? {
        switch format {
        case .m3u8, .m3u: return MusicPlaylistM3U.export(name: p.name, tracks: p.tracks).data(using: .utf8)
        case .json: return try? MusicPlaylistJSON.export(name: p.name, description: description, tracks: p.tracks)
        }
    }

    @MainActor static func export(_ p: LocalPlaylist, format: MusicPlaylistFileFormat, description: String?) {
        guard let data = contents(of: p, format: format, description: description) else {
            MusicToasts.shared.error(Localized.string("Could not write that file."))
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(p.name) + "." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            MusicDebugLog.log("playlist", "exported \(p.tracks.count) songs as \(format.rawValue)")
            MusicToasts.shared.show(Localized.string("Saved “%@”.", url.lastPathComponent), kind: .success)
        } catch {
            MusicDebugLog.log("playlist", "export failed: \(error.localizedDescription)")
            MusicToasts.shared.error(Localized.string("Could not save the file."))
        }
        #else
        MusicToasts.shared.show(Localized.string("Saving a playlist file needs the Mac app."), kind: .info)
        #endif
    }

    /// A file name without the characters a file system refuses.
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(80))
    }
}
