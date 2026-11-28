import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Tidy your local music: songs stored twice, and songs in your playlists whose file went missing. Nothing here deletes a file from your disk.
struct MusicLocalTidySheet: View {
    enum Tab: Hashable { case duplicates, missing }
    let hub: MusicHub
    let close: () -> Void
    @State var tab: Tab
    @State private var groups: [LocalLibraryTidy.DuplicateGroup] = []
    @State private var missing: [LocalLibraryTidy.MissingSong] = []
    @State private var loading = true

    init(hub: MusicHub, tab: Tab = .duplicates, close: @escaping () -> Void) {
        self.hub = hub; self.close = close; _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Tidy local music")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.tidyClose")
            }
            Picker("", selection: $tab) {
                Text(Localized.string("Repeated songs")).tag(Tab.duplicates)
                Text(Localized.string("Missing files")).tag(Tab.missing)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().atlas("control.music.tidyTab")
            if loading { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 160) }
            else if tab == .duplicates { duplicatesList } else { missingList }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
        .task { await load() }
    }

    private func load() async {
        loading = true
        let index = await LocalLibraryStore.shared.currentIndex()
        groups = await Task.detached(priority: .userInitiated) { LocalLibraryTidy.duplicates(index.entries) }.value
        reloadMissing()
        loading = false
    }

    private func reloadMissing() {
        missing = LocalLibraryTidy.missing(in: hub.library.playlists) { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: repeated songs

    private var duplicatesList: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if groups.isEmpty {
                Text(Localized.string("No song is stored twice in your music folders.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.lg)
            } else {
                HStack {
                    Text(Localized.plural(groups.count, one: "%@ song is stored more than once", other: "%@ songs are stored more than once")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                    Spacer()
                    Button(Localized.string("Remove all extras")) { removeExtras(groups) }.musicButton(.primary, size: .compact).atlas("control.music.tidyRemoveAllExtras")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.sm) {
                        ForEach(groups) { g in group(g) }
                    }
                }
                Text(Localized.string("Extras are taken out of StreamSetu's list. The files stay on your disk.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private func group(_ g: LocalLibraryTidy.DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.keeper.title).font(MusicTokens.rowTitle).lineLimit(1)
                Text(g.keeper.artist).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                Spacer()
                Button(Localized.string("Keep best")) { removeExtras([g]) }.musicButton(.secondary, size: .compact).atlas("control.music.tidyKeepBest")
            }
            ForEach(g.entries) { e in
                HStack(spacing: 6) {
                    Image(systemName: e.id == g.keeper.id ? "checkmark.circle.fill" : "circle").foregroundStyle(e.id == g.keeper.id ? ColorTokens.success : ColorTokens.textTertiary)
                    Text(verbatim: e.ext.uppercased()).font(Typography.captionMedium).frame(width: 44, alignment: .leading)
                    Text(verbatim: e.path).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(ColorTokens.lineStrong.opacity(0.15)))
    }

    private func removeExtras(_ list: [LocalLibraryTidy.DuplicateGroup]) {
        let ids = Set(list.flatMap { $0.extras.map(\.id) })
        Task {
            let n = await LocalLibraryStore.shared.forget(ids: ids)
            MusicToasts.shared.success(Localized.plural(n, one: "Removed %@ extra copy.", other: "Removed %@ extra copies."))
            await load()
        }
    }

    // MARK: missing files

    private var missingList: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if missing.isEmpty {
                Text(Localized.string("Every local song in your playlists still has its file.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.lg)
            } else {
                Text(Localized.plural(missing.count, one: "%@ song in your playlists has lost its file", other: "%@ songs in your playlists have lost their files")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.sm) { ForEach(missing) { m in row(m) } }
                }
                Text(Localized.string("Choose the file's new place inside one of your music folders, and the song is pointed there in every playlist.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private func row(_ m: LocalLibraryTidy.MissingSong) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.track.title).font(MusicTokens.rowTitle).lineLimit(1)
                Text(verbatim: m.path).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            #if os(macOS)
            Button(Localized.string("Locate…")) { locate(m) }.musicButton(.secondary, size: .compact).atlas("control.music.tidyLocate")
            #endif
            Button(Localized.string("Remove"), role: .destructive) { remove(m) }.musicButton(.destructive, size: .compact).atlas("control.music.tidyRemoveMissing")
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(ColorTokens.lineStrong.opacity(0.15)))
    }

    private func remove(_ m: LocalLibraryTidy.MissingSong) {
        for id in m.playlistIDs {
            guard let p = hub.library.playlist(id: id), let i = p.tracks.firstIndex(where: { $0.uid == m.track.uid }) else { continue }
            hub.library.remove(at: IndexSet(integer: i), from: id)
        }
        reloadMissing()
    }

    #if os(macOS)
    private func locate(_ m: LocalLibraryTidy.MissingSong) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = Localized.string("Choose the file for %@", m.track.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let index = await LocalLibraryStore.shared.currentIndex()
            guard let entry = index.entries.first(where: { $0.path == url.path }) else {
                MusicToasts.shared.show(Localized.string("Choose a file inside one of your music folders."), kind: .error); return
            }
            let new = LocalFilesProvider().track(entry)
            for id in m.playlistIDs {
                guard let p = hub.library.playlist(id: id) else { continue }
                hub.library.replaceTracks(LocalLibraryTidy.replacing(m.track, with: new, in: p.tracks), in: id)
            }
            MusicToasts.shared.success(Localized.string("Song found again."))
            reloadMissing()
        }
    }
    #endif
}
