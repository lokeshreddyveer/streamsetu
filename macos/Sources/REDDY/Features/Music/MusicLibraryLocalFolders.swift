import SwiftUI

// The "Folders" view of the Local files tab: a breadcrumb, the sub-folders of the folder you are in, and its files, with Play folder and Shuffle folder.
// It reads the folders the person chose and the paths the scan indexed; the folder names on disk come through the same security-scoped access the scan uses.

struct MusicLibraryLocalFolderView: View {
    let hub: MusicHub
    /// Every local track, for turning an indexed file into a playable song.
    let tracks: [MusicTrack]

    @State private var roots: [LocalFolderInfo] = []
    @State private var loadedRoots = false
    @State private var rootID: String?
    @State private var path: [String] = []
    @State private var listing: LocalFolderListing?
    @State private var entries: [(path: String, id: String)] = []

    private var store: LocalLibraryStore { (hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider)?.store ?? LocalLibraryStore.shared }
    private var root: LocalFolderInfo? { roots.first { $0.id == rootID } }
    private var byID: [String: MusicTrack] { Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    private struct Key: Equatable { var root: String?; var path: [String]; var tracks: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if !loadedRoots { MusicLibrarySkeleton(mode: .list) }
            else if roots.isEmpty {
                MusicEmptyState(glyph: .emptyLibrary, title: Localized.string("No local files yet"),
                                message: Localized.string("Add a music folder to play files stored on this Mac. Nothing is uploaded."),
                                actionTitle: Localized.string("Add local files")) { MusicChromeState.shared.openSettings(.data) }
            } else if let root {
                crumbs(root)
                if let listing { content(listing, root: root) } else { MusicLibrarySkeleton(mode: .list) }
            } else {
                rootList
            }
        }
        .task { await loadRoots() }
        .task(id: Key(root: rootID, path: path, tracks: tracks.count)) { await loadListing() }
    }

    // MARK: roots

    private var rootList: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            ForEach(roots) { r in
                folderRow(name: r.name, count: r.trackCount) { rootID = r.id; path = [] }
            }
        }
    }

    // MARK: breadcrumb

    private func crumbs(_ root: LocalFolderInfo) -> some View {
        let list = LocalFolderTree.breadcrumbs(rootName: root.name, path: path)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MusicSpace.xxs) {
                if roots.count > 1 {
                    Button { rootID = nil; path = []; listing = nil } label: { Label(Localized.string("Folders"), systemImage: "folder") }
                        .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("All music folders")).atlas("control.music.libraryLocalCrumbRoot")
                    Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                    let last = i == list.count - 1
                    Button { path = c.path } label: { Text(verbatim: c.name).lineLimit(1) }
                        .musicButton(last ? .secondary : .tertiary, size: .compact).disabled(last)
                        .accessibilityLabel(Text(verbatim: Localized.string("Open folder %@", c.name))).atlas("control.music.libraryLocalCrumb")
                    if !last { Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true) }
                }
            }
        }
    }

    // MARK: content

    @ViewBuilder private func content(_ l: LocalFolderListing, root: LocalFolderInfo) -> some View {
        let here = l.files.compactMap { byID[$0.trackID] }
        HStack(spacing: MusicSpace.xs) {
            Text(verbatim: Localized.plural(l.trackCount, one: "%@ song", other: "%@ songs")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            Spacer(minLength: MusicSpace.xs)
            Button { play(shuffled: false) } label: { Label(Localized.string("Play folder"), systemImage: "play.fill") }
                .musicButton(.primary, size: .compact).disabled(l.isEmpty).accessibilityLabel(Localized.string("Play every song in this folder")).atlas("control.music.libraryLocalPlayFolder")
            Button { play(shuffled: true) } label: { Label(Localized.string("Shuffle folder"), systemImage: "shuffle") }
                .musicButton(.secondary, size: .compact).disabled(l.isEmpty).accessibilityLabel(Localized.string("Shuffle every song in this folder")).atlas("control.music.libraryLocalShuffleFolder")
        }
        if l.folders.isEmpty && l.files.isEmpty {
            MusicEmptyState(symbol: "folder", title: Localized.string("This folder has no music"),
                            message: Localized.string("Add songs to it and rescan, or go back and choose another folder."),
                            actionTitle: path.isEmpty ? nil : Localized.string("Back")) { path.removeLast() }
                .frame(minHeight: MusicSpace.huge * 4)
        } else {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                ForEach(l.folders) { f in folderRow(name: f.name, count: f.trackCount) { path.append(f.name) } }
            }
            if !here.isEmpty {
                MusicTrackList(hub: hub, tracks: here, listKey: nil, showsTools: false, numbered: false, canSort: false, presorted: true, prefetchOwner: "library:local:folders")
            }
        }
    }

    private func folderRow(name: String, count: Int, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: "folder.fill").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: MusicSpace.xl)
                Text(verbatim: name).musicText(.body).lineLimit(1)
                Spacer(minLength: MusicSpace.xs)
                Text(verbatim: count == 0 ? Localized.string("No songs") : Localized.plural(count, one: "%@ song", other: "%@ songs"))
                    .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget + MusicSpace.xs).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel(Text(verbatim: Localized.string("Open folder %@", name))).atlas("control.music.libraryLocalFolderRow")
    }

    // MARK: loading and playing

    private func loadRoots() async {
        let r = await store.snapshot()
        roots = r
        loadedRoots = true
        if r.count == 1, rootID == nil { rootID = r[0].id }
        MusicDebugLog.log("local", "folder view: \(r.count) chosen folders")
    }

    private func spellings(of info: LocalFolderInfo) -> [String] {
        [info.path, URL(fileURLWithPath: info.path).resolvingSymlinksInPath().standardizedFileURL.path]
    }

    private func loadListing() async {
        guard let info = root else { listing = nil; return }
        let files = await store.indexedFiles(folderID: info.id)
        let disk = await store.subfolderNames(folderID: info.id, relative: path)
        if Task.isCancelled { return }
        entries = files
        let l = LocalFolderTree.listing(roots: spellings(of: info), entries: files, at: path, diskFolders: disk)
        listing = l
        let here = path.joined(separator: "/")
        MusicDebugLog.log("local", "folder scan /\(here): \(l.folders.count) folders, \(l.files.count) files, \(l.trackCount) songs below, \(disk.count) on disk")
    }

    private func play(shuffled: Bool) {
        guard let info = root else { return }
        let ids = LocalFolderTree.trackIDs(roots: spellings(of: info), entries: entries, at: path)
        let lookup = byID
        let list = ids.compactMap { lookup[$0] }
        MusicDebugLog.log("local", "\(shuffled ? "shuffle" : "play") folder: \(list.count) of \(ids.count) songs found")
        guard !list.isEmpty else { return }
        let folder = path.last ?? Localized.string("Folders")
        if shuffled { hub.playShuffled(list, sourceName: folder) } else { hub.play(list, at: 0, sourceName: folder) }
    }
}
