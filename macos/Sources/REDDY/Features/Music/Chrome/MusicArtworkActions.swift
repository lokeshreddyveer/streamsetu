import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// Choosing and resetting a picture from a menu, filling in what a local file's tags left blank, and the picture cache's row in Settings.

@MainActor
enum MusicArtworkActions {
    /// Asks for a picture file and uses it for `subject`. The picture stays on this device.
    static func choose(for subject: MusicArtworkSubject) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = Localized.string("Choose a picture")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if MusicArtworkOverrides.shared.setImage(from: url, for: subject) { MusicToasts.shared.success(Localized.string("Artwork changed.")) }
        else { MusicToasts.shared.show(Localized.string("That file is not a picture."), kind: .error) }
        #else
        MusicToasts.shared.show(Localized.string("Choosing artwork needs the Mac app."))
        #endif
    }

    static func reset(_ subject: MusicArtworkSubject) {
        MusicArtworkOverrides.shared.reset(subject)
        MusicToasts.shared.show(Localized.string("Artwork put back."))
    }

    /// For each local song: ask the sources for the same recording and fill only what the file left blank (album, year, genre, track number, a picture).
    static func fillMissing(_ tracks: [MusicTrack], hub: MusicHub) async {
        let local = tracks.filter { $0.providerID == MusicStatsRules.localProviderID }
        guard !local.isEmpty else { return }
        guard MusicEntityArtwork.shared.networkAllowed() else {
            MusicToasts.shared.show(Localized.string("Finding details needs online lookups to be on in Settings."))
            return
        }
        let index = await LocalLibraryStore.shared.currentIndex()
        let providers = hub.registry.metadata.filter { $0.id != MusicStatsRules.localProviderID }
        var filled = 0
        for t in local {
            guard let entry = index.entry(id: t.id) else { continue }
            let query = [entry.title, MusicMetadataFill.isBlank(entry.artist) ? "" : LocalLibraryIndex.primaryArtist(of: entry)].filter { !$0.isEmpty }.joined(separator: " ")
            var match: MusicTrack?
            for p in providers {
                guard let page = try? await p.searchTracks(query, page: nil), let hit = MusicMetadataFill.best(for: entry, in: page.items) else { continue }
                match = hit; break
            }
            guard let match else { continue }
            let patch = MusicMetadataFill.patch(for: entry, from: match)
            var changed = false
            if !patch.isEmpty, await LocalLibraryStore.shared.edit(ids: [entry.id], patch: patch) > 0 { changed = true }
            if entry.artworkFile == nil, let pic = MusicArtworkService.pickThumbnail(match.thumbnails, neededPixels: 600) ?? match.album.flatMap({ MusicArtworkService.pickThumbnail($0.thumbnails, neededPixels: 600) }) {
                let subject = MusicArtworkSubject.derive(t)
                if !MusicArtworkOverrides.shared.has(subject) { MusicArtworkOverrides.shared.set(address: pic, for: subject); changed = true }
            }
            if changed { filled += 1 }
        }
        MusicToasts.shared.show(filled == 0 ? Localized.string("Nothing new was found.") : Localized.plural(filled, one: "Filled in %@ song.", other: "Filled in %@ songs."), kind: filled == 0 ? .info : .success)
    }
}

/// The Manage Artwork submenu: choose a picture, put the automatic one back, and for your own playlists the cover settings.
struct MusicManageArtworkMenu: View {
    let subject: MusicArtworkSubject
    var onCoverSettings: (() -> Void)?

    var body: some View {
        Menu {
            Button("Choose Picture…", systemImage: "photo.on.rectangle") { MusicArtworkActions.choose(for: subject) }.atlas("control.music.artworkChoose")
            Button("Use Automatic Artwork", systemImage: "arrow.uturn.backward") { MusicArtworkActions.reset(subject) }
                .disabled(!MusicArtworkOverrides.shared.has(subject)).atlas("control.music.artworkReset")
            if let onCoverSettings { Divider(); Button("Cover Settings…", systemImage: "slider.horizontal.3") { onCoverSettings() }.atlas("control.music.artworkCoverSettings") }
        } label: { Label("Manage Artwork", systemImage: "photo") }.atlas("control.music.artworkMenu")
    }
}

/// Settings row for the picture cache: how much disk it uses, its limit, and a way to empty it.
struct MusicArtworkCacheRow: View {
    @State private var used = 0
    @State private var confirm = false

    var body: some View {
        MusicButtonRow(title: "Picture cache", atlas: "control.music.artworkCacheClear",
                       detail: Localized.string("%@ used", Self.megabytes(used)) + " · " + Localized.string("limit %@", Self.megabytes(MusicArtworkStore.defaultDiskCap)),
                       info: "Covers are kept on this Mac so they load at once. The oldest are removed when the limit is reached. Clearing also forgets which pictures were not found.",
                       button: "Clear", disabled: used == 0) { confirm = true }
            .task { used = await MusicArtworkService.shared.diskBytes() }
            .confirmationDialog("Clear the picture cache?", isPresented: $confirm) {
                Button("Clear cache", role: .destructive) {
                    Task { await MusicArtworkService.shared.clear(); MusicEntityArtwork.shared.clear(); used = await MusicArtworkService.shared.diskBytes() }
                }.atlas("control.music.artworkCacheConfirm")
            }
    }

    static func megabytes(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
}
