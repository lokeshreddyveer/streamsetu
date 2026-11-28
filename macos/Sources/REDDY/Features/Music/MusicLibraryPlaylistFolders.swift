import SwiftUI

// The folder row of the Playlists tab: "All", one chip per folder with its count, and "New folder". The chosen folder has a small menu to choose its
// playlists, rename it or delete it (the playlists stay in the library). Playlists are put in a folder from a sheet that lists every playlist.

struct MusicLibraryPlaylistFolderBar: View {
    let hub: MusicHub
    @Binding var selected: UUID?
    @State private var creating = false
    @State private var renaming = false
    @State private var managing = false
    @State private var name = ""

    private var book: MusicPlaylistFolderBook { hub.library.playlistFolders }
    private var current: MusicPlaylistFolder? { selected.flatMap { id in book.folders.first { $0.id == id } } }

    var body: some View {
        let _ = book.revision
        HStack(spacing: MusicSpace.xs) {
            Label(Localized.string("Folders"), systemImage: "folder").musicText(.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MusicSpace.xxs) {
                    if !book.folders.isEmpty {
                        MusicChip(title: Localized.string("All playlists"), selected: current == nil) { choose(nil) }
                    }
                    ForEach(book.folders) { f in
                        MusicChip(title: f.name + " · " + f.playlistIDs.count.formatted(), selected: f.id == selected) { choose(f.id == selected ? nil : f.id) }
                    }
                    Button { name = ""; creating = true } label: { Label(Localized.string("New folder"), systemImage: "folder.badge.plus") }
                        .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Create a folder for playlists")).atlas("control.music.libraryFolderNew")
                }
                .padding(.vertical, 1)
            }
            if let f = current {
                Menu {
                    Button(Localized.string("Choose playlists…"), systemImage: "checklist") { managing = true }.atlas("control.music.libraryFolderChoose")
                    Button(Localized.string("Rename folder…"), systemImage: "pencil") { name = f.name; renaming = true }.atlas("control.music.libraryFolderRename")
                    Divider()
                    Button(Localized.string("Delete folder"), systemImage: "trash", role: .destructive) { delete(f) }.atlas("control.music.libraryFolderDelete")
                } label: {
                    Image(systemName: "ellipsis.circle").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                        .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
                .accessibilityLabel(Text(verbatim: Localized.string("Folder actions: %@", f.name))).atlasCovers("control.music.libraryFolderChoose")
            }
        }
        .alert(Localized.string("New folder"), isPresented: $creating) {
            TextField(Localized.string("Name"), text: $name)
            Button(Localized.string("Cancel"), role: .cancel) {}.atlas("control.music.libraryFolderCancel")
            Button(Localized.string("Create")) { create() }.atlas("control.music.libraryFolderCreate")
        }
        .alert(Localized.string("Rename folder"), isPresented: $renaming) {
            TextField(Localized.string("Name"), text: $name)
            Button(Localized.string("Cancel"), role: .cancel) {}.atlas("control.music.libraryFolderCancel")
            Button(Localized.string("Rename")) { if let f = current { book.rename(f.id, to: name); MusicDebugLog.log("library", "folder renamed") } }.atlas("control.music.libraryFolderRename")
        }
        .sheet(isPresented: $managing) {
            if let f = current { MusicPlaylistFolderPicker(hub: hub, folder: f, onClose: { managing = false }) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(Text(verbatim: Localized.string("Folders")))
    }

    private func choose(_ id: UUID?) {
        selected = id
        MusicDebugLog.log("library", "playlist folder chosen: \(id?.uuidString ?? "all")")
    }

    private func create() {
        let before = Set(book.folders.map(\.id))
        book.create(name)
        if let made = book.folders.first(where: { !before.contains($0.id) }) { choose(made.id); managing = true }
        else { MusicDebugLog.log("library", "folder not created (blank or duplicate name)") }
    }

    private func delete(_ f: MusicPlaylistFolder) {
        book.delete(f.id)
        selected = nil
        MusicDebugLog.log("library", "folder deleted, \(f.playlistIDs.count) playlists kept")
    }
}

/// Every playlist with a check for "in this folder". Ticking one that sits in another folder moves it here; unticking puts it outside any folder.
struct MusicPlaylistFolderPicker: View {
    let hub: MusicHub
    let folder: MusicPlaylistFolder
    var onClose: () -> Void

    private var book: MusicPlaylistFolderBook { hub.library.playlistFolders }

    var body: some View {
        let _ = book.revision
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(verbatim: Localized.string("Playlists in %@", folder.name)).font(Typography.heading).accessibilityAddTraits(.isHeader)
            if hub.library.playlists.isEmpty {
                MusicEmptyState(symbol: "music.note.list", title: Localized.string("No playlists yet"), message: Localized.string("Make a playlist, or bring ones you already have."))
            } else {
                ScrollView {
                    LazyVStack(spacing: MusicSpace.xxs) {
                        ForEach(hub.library.playlists) { p in row(p) }
                    }
                }
            }
            HStack { Spacer(); Button(Localized.string("Done"), action: onClose).atlas("control.music.libraryFolderDone").musicButton(.primary, size: .compact).keyboardShortcut(.defaultAction) }
        }
        .padding(MusicSpace.lg).frame(minWidth: 380, minHeight: 360)
    }

    private func row(_ p: LocalPlaylist) -> some View {
        let here = book.folders.first { $0.id == folder.id }?.playlistIDs.contains(p.id) ?? false
        let elsewhere = MusicPlaylistFolderRules.folder(of: p.id, in: book.folders).flatMap { $0.id == folder.id ? nil : $0.name }
        return Button { book.move(p.id, to: here ? nil : folder.id); MusicDebugLog.log("library", "playlist \(here ? "left" : "joined") folder") } label: {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: here ? "checkmark.circle.fill" : "circle").font(MusicTokens.iconMedium).foregroundStyle(here ? ColorTokens.textPrimary : ColorTokens.textTertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: p.name).musicText(.body).lineLimit(1)
                    if let elsewhere { Text(verbatim: Localized.string("In folder %@", elsewhere)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(Text(verbatim: p.name)).accessibilityAddTraits(here ? .isSelected : [])
        .atlas("control.music.libraryFolderToggle")
    }
}
