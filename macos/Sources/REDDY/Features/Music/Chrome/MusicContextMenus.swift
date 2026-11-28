import SwiftUI
import Observation

// MARK: - pure rules (no screen, so they can be tested)

/// Where a song menu is shown. The player bar and the mini player offer links-only items; a local file has no service behind it.
struct MusicTrackMenuContext: Equatable, Sendable {
    var isLocal = false
    var linksOnly = false
    var hasArtistID = false
    var hasArtistName = true
    var hasAlbumID = false
    /// The connected song page is on (`music.graph.pages`): rows then offer "Go to Song".
    var hasSongPage = false
    var scrobblerConnected = false
    var scrobblingOn = false
    var isRoomGuest = false
    var hostRemoveLabel: String?
    var removableFromPlayingPlaylist = false
    var canRadio = true
    var canRate = false
    var canToggleLibrary = false
    var inLibraryListView = false
    var isCompactPlayerBar = false
    /// Offered where a song is a suggestion (Home, Radio, autoplay, search suggestions) and from every song row, so it can be undone from the same place.
    var canHideRecommendation = true
}

enum MusicTrackMenuItem: Equatable, Sendable {
    case playNext, addToQueue, startRadio, like, dislike, saveToLibrary, goToArtist, blockArtist, goToAlbum, goToSong, share, editScrobble, effects
    case saveToPlaylist, download, chooseSource, neverPlay, hostRemove(String), removeFromThisPlaylist
    case viewLyrics, viewCredits, songInfo, trackMarks, visualizer, convert, lockFile, soundsLike, editMetadata, hideRecommendation, manageArtwork, fillDetails, identifyBySound
}

enum MusicMenuLogic {
    /// The song menu in order, each item only when its condition holds.
    static func trackItems(_ c: MusicTrackMenuContext) -> [MusicTrackMenuItem] {
        var out: [MusicTrackMenuItem] = []
        if !c.linksOnly { out.append(.playNext); out.append(.addToQueue) }
        if !c.linksOnly { out.append(.viewLyrics) }
        if !c.isLocal, c.canRadio { out.append(.startRadio) }
        if !c.isLocal, !(c.isCompactPlayerBar == false && c.linksOnly) || c.isCompactPlayerBar { out.append(.like) }
        if !c.isLocal, c.canRate { out.append(.dislike) }
        if !c.isLocal, c.canToggleLibrary, !c.inLibraryListView { out.append(.saveToLibrary) }
        if c.hasArtistID { out.append(.goToArtist) }
        if c.hasArtistName, !c.isLocal { out.append(.blockArtist) }
        if c.hasAlbumID, !c.isLocal { out.append(.goToAlbum) }
        if c.hasSongPage, !c.isLocal { out.append(.goToSong) }
        if !c.isLocal { out.append(.share) }
        if c.scrobblerConnected, c.scrobblingOn { out.append(.editScrobble) }
        if c.linksOnly { out.append(.effects) }
        out.append(.saveToPlaylist)
        if !c.linksOnly { out.append(.viewCredits) }
        out.append(.songInfo)
        if !c.linksOnly { out.append(.trackMarks); out.append(.visualizer) }
        if c.isLocal { out.append(.soundsLike); out.append(.convert); out.append(.lockFile) }
        if c.isLocal { out.append(.editMetadata); out.append(.fillDetails); out.append(.identifyBySound) }
        if !c.linksOnly { out.append(.manageArtwork) }
        if !c.isLocal, !c.linksOnly { out.append(.download) }
        if c.canHideRecommendation, !c.linksOnly { out.append(.hideRecommendation) }
        if !c.isLocal { out.append(.chooseSource); out.append(.neverPlay) }
        if let l = c.hostRemoveLabel, !c.linksOnly { out.append(.hostRemove(l)) }
        if c.removableFromPlayingPlaylist { out.append(.removeFromThisPlaylist) }
        return out
    }

    enum CardKind: Sendable { case album, playlist, artist }

    struct CardContext: Equatable, Sendable {
        var kind: CardKind
        var isLocal = false
        var isOnRepeat = false
        var isLiked = false
        var pinnedCount = 0
        var isPinned = false
        var libraryState: LibraryState = .notSaved
        var isOwned = false
        /// The card names an artist the person can open (an album or a song).
        var hasArtist = false
    }
    enum LibraryState: Sendable { case notSaved, savedLocally, savedOnService }

    enum CardItem: Equatable, Sendable {
        case playAndShuffle, pin, unpin, playNext, addToQueue, startRadio, saveToPlaylist, share, saveToLibrary, removeFromLibrary, inLibrary, blockArtist
        case playArtist, goToArtist
        case download, exportPlaylist, removeDuplicates, editPlaylist, sortTracks, selectMultiple, manageArtwork
    }
    static let maxPins = 3

    static func cardItems(_ c: CardContext) -> [CardItem] {
        var out: [CardItem] = []
        let collection = c.kind != .artist
        if collection { out.append(.playAndShuffle) } else { out.append(.playArtist) }
        if c.kind == .playlist { out.append(c.isPinned ? .unpin : .pin) }
        if collection { out.append(.playNext); out.append(.addToQueue) }
        if !c.isLocal, !c.isOnRepeat { out.append(.startRadio) }
        if collection, !c.isOnRepeat { out.append(.saveToPlaylist) }
        if collection, !c.isLocal { out.append(.download) }
        if c.kind == .playlist, c.isLocal { out.append(contentsOf: [.editPlaylist, .sortTracks, .selectMultiple, .removeDuplicates]) }
        out.append(.manageArtwork)
        if collection { out.append(.exportPlaylist) }
        if !c.isLocal, !c.isOnRepeat { out.append(.share) }
        if c.hasArtist, c.kind != .artist { out.append(.goToArtist) }
        if c.kind != .artist {
            switch c.libraryState {
            case .notSaved: out.append(.saveToLibrary)
            case .savedLocally: out.append(.removeFromLibrary)
            case .savedOnService: out.append(.inLibrary)
            }
        }
        if c.kind == .artist { out.append(.blockArtist) }
        return out
    }

    static func canPin(count: Int) -> Bool { count < maxPins }

    // MARK: queue

    enum PlayNextPlan: Equatable, Sendable {
        /// Not in the queue ahead of the playing row: add it.
        case insert
        /// Already coming up: take the old row out, then add it again as a real play-next row, so it moves instead of repeating.
        case moveFrom(Int)
        /// It is already the very next row.
        case alreadyNext
    }

    static func playNextPlan(queue: [String], index: Int?, uid: String) -> PlayNextPlan {
        guard let cur = index, queue.indices.contains(cur) else { return .insert }
        guard let found = queue.indices.first(where: { $0 > cur && queue[$0] == uid }) else { return .insert }
        return found == cur + 1 ? .alreadyNext : .moveFrom(found)
    }

    /// The queue row to take out after awaited work, found again by song because positions may have shifted. The row nearest the old position wins.
    static func resolveRow(queue: [String], uid: String, near hint: Int) -> Int? {
        queue.indices.filter { queue[$0] == uid }.min { abs($0 - hint) < abs($1 - hint) }
    }

    /// Whether "Remove from this playlist" shows for a row playing out of a playlist: the queue came from that playlist, the row is one of its rows, and the playlist still holds it.
    static func canRemoveFromPlayingPlaylist(queueFromPlaylist: Bool, rowIsPlaylistRow: Bool, playlistHolds: Bool) -> Bool { queueFromPlaylist && rowIsPlaylistRow && playlistHolds }

    // MARK: add to playlist

    struct AddPlan: Equatable, Sendable {
        var duplicatesByPlaylist: [UUID: Int]
        var skipAdds: Int
        var anywayAdds: Int
        var needsDuplicateStep: Bool { duplicatesByPlaylist.values.contains { $0 > 0 } }
    }

    /// Counts what adding `tracks` to each chosen playlist would do. On-device playlists never hold a song twice, so "add anyway" adds nothing more there.
    static func addPlan(tracks: [MusicTrack], chosen: [LocalPlaylist]) -> AddPlan {
        let uids = Set(tracks.map(\.uid))
        var dupes: [UUID: Int] = [:]
        var skip = 0
        for p in chosen {
            let held = Set(p.tracks.map(\.uid))
            let d = uids.intersection(held).count
            dupes[p.id] = d
            skip += uids.count - d
        }
        return AddPlan(duplicatesByPlaylist: dupes, skipAdds: skip, anywayAdds: skip)
    }

    static func addToast(added: Int, duplicates: Int, playlists: [String], songCount: Int) -> String {
        if added == 0 {
            if playlists.count == 1 { return Localized.string("Everything is already in %@.", playlists[0]) }
            return Localized.string("Everything is already in the selected playlists.")
        }
        var text = playlists.count > 1 ? Localized.string("Added to %@ playlists.", "\(playlists.count)") : Localized.string("Added to %@.", playlists.first ?? "")
        if duplicates > 0 { text += " " + Localized.string("Duplicates skipped: %@.", "\(duplicates)") }
        return text
    }

    // MARK: selection bar

    struct SelectionBar: Equatable, Sendable {
        var selectedCount: Int
        var hiddenByFilter = 0
        var stillLoading = 0
        var armedRemove = false

        var label: String { selectedCount == 0 ? Localized.string("Select songs") : Localized.string("%@ selected", "\(selectedCount)") }
        /// A change of selection puts the remove button back to its first press.
        mutating func selectionChanged(to count: Int) { selectedCount = count; armedRemove = false }
        /// First press arms, second press runs. Returns true when the removal should run now.
        mutating func pressRemove() -> Bool { if armedRemove { armedRemove = false; return true }; armedRemove = true; return false }
    }
}

// MARK: - state shared by the chrome

/// What is open above the page: the share dialog, the add-to-playlist steps, the open-link box, the palette and Settings.
@MainActor @Observable
final class MusicChromeState {
    static let shared = MusicChromeState()
    var sharing: MusicShareSubject?
    var addToPlaylist: [MusicTrack]?
    var showOpenLink = false
    var showPalette = false
    var showSettings = false
    var settingsRoute = MusicSettingsRoute()
    var comments: MusicTrack?
    var credits: MusicTrack?
    var songInfo: MusicTrack?
    var editMetadata: [MusicTrack]?
    var identify: [MusicTrack]?
    var soundsLike: MusicTrack?
    /// The song navigation window (loop, bookmarks, start and end, skips) for the song that is playing.
    var marksOpen = false
    /// The library health window (report, rename, changes, locks).
    var healthOpen = false
    /// The visualizer window.
    var visualizerOpen = false
    /// The command palette.
    var paletteOpen = false
    /// The listening modes window.
    var modesOpen = false
    /// The automation settings window.
    var automationOpen = false
    /// The audio tools window, opened with these files already chosen.
    var convertFiles: MusicConvertRequest?
    /// Opens the Ragas window on this raga (from a song's information, a composer's page or a raga chip).
    var ragaRequest: MusicRagaRequest?
    /// The first-run "Tell Music what you like" window.
    var setupOpen = false
    /// A local playlist whose edit sheet (name, description, cover) is open.
    var editPlaylist: UUID?
    /// A playlist page that should open already picking songs.
    var selectOnOpen: UUID?
    /// The View menu asks the shell to show or hide the sidebar or the details panel by bumping these; the shell does it, because only it knows the window width.
    var sidebarToggleRequest = 0
    var panelToggleRequest = 0
    /// What the shell shows now and whether each can change, so the menu can say "Collapse" or "Expand" and grey the item out when it cannot act.
    var sidebarIsExpanded = true
    var canToggleSidebar = false
    var canTogglePanel = false
    /// True while the side panel is on screen (inline or as an overlay); the View menu's Show or Hide item reads it.
    var panelShown = false
    /// How wide the side panel is on screen now (0 when none), and how tall the player bar (or its thin line or restore pill) is at the bottom. The shell publishes them so the
    /// Setu button can keep clear of both instead of sitting over the lyrics, the queue rows and the volume.
    var panelOccupiedWidth: CGFloat = 0
    var barInset: CGFloat = 0

    func openSettings(_ tab: MusicSettingsTab, anchor: String? = nil) {
        settingsRoute = MusicSettingsRoute(tab: tab, anchor: anchor)
        showSettings = true
    }
}

// MARK: - song menu

/// The song menu used by every row, queue row and player surface.
struct MusicTrackMenuContent: View {
    let track: MusicTrack
    let hub: MusicHub
    var linksOnly = false
    var compactPlayerBar = false
    var hostRemove: (label: String, action: () -> Void)?
    /// The local playlist this row is playing out of, when it is.
    var fromPlaylist: UUID?
    var inLibraryListView = false

    private var context: MusicTrackMenuContext {
        let local = track.providerID == MusicStatsRules.localProviderID
        let held = fromPlaylist.flatMap { hub.library.playlist(id: $0) }?.tracks.contains { $0.uid == track.uid } ?? false
        let signedIn = YouTubeMusicAccountBuiltIns.manager?.isSignedIn == true && track.providerID == YTM.providerID
        return MusicTrackMenuContext(
            isLocal: local, linksOnly: linksOnly, hasArtistID: MusicCompilationArtist.primary(in: track.artists) != nil,
            hasArtistName: MusicCompilationArtist.primary(in: track.artists) != nil, hasAlbumID: track.album != nil, hasSongPage: MusicGraphKeys.pagesOn,
            scrobblerConnected: !hub.registry.scrobblers.isEmpty, scrobblingOn: hub.library.settings.scrobbleEnabled,
            isRoomGuest: hub.player.isRoomGuest, hostRemoveLabel: hostRemove?.label,
            removableFromPlayingPlaylist: MusicMenuLogic.canRemoveFromPlayingPlaylist(queueFromPlaylist: fromPlaylist != nil, rowIsPlaylistRow: fromPlaylist != nil, playlistHolds: held),
            canRadio: hub.registry.provider(id: track.providerID) is any MusicMetadataProvider,
            canRate: signedIn, canToggleLibrary: signedIn && track.libraryToggle != nil, inLibraryListView: inLibraryListView, isCompactPlayerBar: compactPlayerBar)
    }

    var body: some View {
        let ctx = context
        ForEach(Array(MusicMenuLogic.trackItems(ctx).enumerated()), id: \.offset) { _, item in row(item, ctx) }
        if !ctx.isLocal, MusicGraphKeys.pagesOn { Divider(); MusicGoToMenu(track: track, hub: hub) }
    }

    @ViewBuilder private func row(_ item: MusicTrackMenuItem, _ ctx: MusicTrackMenuContext) -> some View {
        let liked = hub.library.isLiked(track)
        let blocked = hub.library.isBlacklisted(track)
        switch item {
        case .playNext:
            Button(ctx.isRoomGuest ? Localized.string("Suggest to Room") : Localized.string("Play Next"), systemImage: "text.insert") { MusicQueueActions.playNext(track, hub: hub) }.atlas("control.music.songMenusSuggestToRoom")
        case .addToQueue:
            // A guest follows the host's queue: only "Suggest to Room" is offered.
            if !ctx.isRoomGuest { Button("Add to Queue", systemImage: "text.append") { hub.player.enqueue([track]) }.atlas("control.music.songMenusAddToQueue") }
        case .startRadio: Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { Task { await MusicQueueActions.startRadio(track, hub: hub) } }.atlas("control.music.songMenusStartRadio")
        case .like:
            Button(liked ? "Remove from Liked Songs" : "Add to Liked Songs", systemImage: liked ? "heart.slash" : "heart") { hub.library.toggleLike(track) }.atlas("control.music.songMenusRemoveFromLikedSongs")
        case .dislike:
            Button(track.rating == .dislike ? "Remove Dislike" : "Dislike", systemImage: "hand.thumbsdown") { Task { await MusicQueueActions.rate(track, dislike: track.rating != .dislike) } }.atlas("control.music.songMenusRemoveDislike")
        case .saveToLibrary:
            let inLib = track.libraryToggle?.inLibrary == true
            Button(inLib ? "Remove from Library" : "Save to Library", systemImage: inLib ? "minus.circle" : "plus.circle") { Task { await MusicQueueActions.toggleLibrary(track) } }.atlas("control.music.songMenusRemoveFromLibrary")
        case .goToArtist:
            if let a = MusicCompilationArtist.primary(in: track.artists) { Button("Go to \(a.name)", systemImage: "person.crop.circle") { hub.open(.artist(hub.artist(from: a, providerID: track.providerID))) }.atlas("control.music.songMenusGoTo") }
        case .blockArtist:
            if let a = MusicCompilationArtist.primary(in: track.artists) {
                let b = hub.library.isBlacklisted(artist: a)
                Button(b ? "Unblock \(a.name)" : "Block \(a.name)", systemImage: "nosign") {
                    hub.library.toggleBlacklist(artist: a)
                    MusicToasts.shared.show(b ? Localized.string("Unblocked %@.", a.name) : Localized.string("Blocked %@.", a.name))
                }.atlas("control.music.songMenusUnblock")
            }
        case .goToAlbum:
            if let al = track.album, al.hasPage { Button("Go to \(al.title)", systemImage: "square.stack") { hub.open(.album(hub.album(from: al, providerID: track.providerID))) }.atlas("control.music.songMenusGoTo") }
        case .goToSong:
            Button("Go to Song", systemImage: "music.note") { hub.open(MusicEntityID.provisional(kind: .recording, providerUID: track.uid)) }.atlas("control.music.songMenusGoToSong")
        case .share: Button("Share…", systemImage: "square.and.arrow.up") { MusicChromeState.shared.sharing = .track(track, playing: hub.player.current?.uid == track.uid) }.atlas("control.music.songMenusShare")
        case .editScrobble: Button("Edit Scrobble…", systemImage: "waveform.badge.magnifyingglass") { MusicChromeState.shared.openSettings(.plugins, anchor: "plugins.scrobbling") }.atlas("control.music.songMenusEditScrobble")
        case .effects: Button("Tempo, Pitch and Reverb…", systemImage: "slider.horizontal.3") { MusicChromeState.shared.openSettings(.playback, anchor: "playback.automix") }.atlas("control.music.songMenusTempoPitchAndReverb")
        case .saveToPlaylist: Button("Add to Playlist…", systemImage: "music.note.list") { MusicChromeState.shared.addToPlaylist = [track] }.atlas("control.music.songMenusAddToPlaylist")
        case .viewLyrics: Button(Localized.string(hub.player.current?.uid == track.uid ? "View Lyrics" : "Play and View Lyrics"), systemImage: "quote.bubble") { MusicTrackActions.viewLyrics(track, hub: hub) }.atlas("control.music.songMenusViewLyrics")
        case .viewCredits: Button("View Credits", systemImage: "person.2") { MusicChromeState.shared.credits = track }.atlas("control.music.songMenusViewCredits")
        case .songInfo: Button("Song Information", systemImage: "info.circle") { MusicChromeState.shared.songInfo = track }.atlas("control.music.songMenusSongInformation")
        case .editMetadata: Button("Edit Details…", systemImage: "pencil") { MusicChromeState.shared.editMetadata = [track] }.atlas("control.music.songMenusEditDetails")
        case .hideRecommendation: MusicHideRecommendationMenu(track: track)
        case .manageArtwork: MusicManageArtworkMenu(subject: MusicArtworkSubject.derive(track))
        case .trackMarks:
            if hub.player.current?.uid == track.uid { Button("Loop, Bookmarks and Skips…", systemImage: "repeat.1") { MusicChromeState.shared.marksOpen = true }.atlas("control.music.songMenusTrackMarks") }
        case .visualizer:
            if hub.player.current?.uid == track.uid, !MusicAccessibilityPrefs.visualizersDisabled { Button("Visualizer…", systemImage: "waveform") { MusicChromeState.shared.visualizerOpen = true }.atlas("control.music.songMenusVisualizer") }
        case .convert:
            if let path = LocalLibraryTidy.filePath(of: track) { Button("Convert…", systemImage: "arrow.triangle.2.circlepath") { MusicChromeState.shared.convertFiles = MusicConvertRequest(urls: [URL(fileURLWithPath: path)]) }.atlas("control.music.songMenusConvert") }
        case .lockFile:
            if let path = LocalLibraryTidy.filePath(of: track) {
                let locked = MusicCollectionSafety.isLocked(path)
                Button(locked ? "Unlock File" : "Lock File Against Changes", systemImage: locked ? "lock.open" : "lock") { MusicCollectionSafety.setLocked([path], !locked) }.atlas("control.music.songMenusLockFile")
            }
        case .soundsLike: Button("Sounds Like…", systemImage: "waveform.path") { MusicChromeState.shared.soundsLike = track }.atlas("control.music.songMenusSoundsLike")
        case .identifyBySound: Button("Identify by Sound…", systemImage: "waveform.badge.magnifyingglass") { MusicChromeState.shared.identify = [track] }.atlas("control.music.songMenusIdentifyBySound")
        case .fillDetails: Button("Find Missing Details", systemImage: "text.magnifyingglass") { Task { await MusicArtworkActions.fillMissing([track], hub: hub) } }.atlas("control.music.songMenusFindMissingDetails")
        case .download: Button("Download", systemImage: "arrow.down.circle") { hub.downloads.enqueue(track) }.atlas("control.music.songMenusDownload")
        case .chooseSource: Button("Choose Another Audio Source…", systemImage: "waveform.badge.magnifyingglass") { hub.chooseAudioSource(for: track) }.atlas("control.music.songMenusChooseAnotherAudioSource")
        case .neverPlay:
            Button(blocked ? "Allow This Track Again" : "Never Play This Track", systemImage: blocked ? "checkmark.circle" : "nosign") { hub.library.toggleBlacklist(track) }.atlas("control.music.songMenusAllowThisTrackAgain")
        case .hostRemove(let label):
            Button(role: .destructive) { hostRemove?.action() } label: { Label(LocalizedStringKey(label), systemImage: "minus.circle") }.atlas("control.music.songMenusMinusCircle")
        case .removeFromThisPlaylist:
            Button(role: .destructive) { MusicQueueActions.removeFromPlayingPlaylist(track, playlist: fromPlaylist, hub: hub) } label: { Label("Remove from This Playlist", systemImage: "minus.circle") }.atlas("control.music.songMenusRemoveFromThisPlaylist")
        }
        if item == .startRadio || item == .goToAlbum || item == .saveToPlaylist { Divider() }
    }
}

@MainActor
enum MusicQueueActions {
    /// Play next moves a song that is already coming up instead of adding a second copy.
    static func playNext(_ t: MusicTrack, hub: MusicHub) {
        let p = hub.player
        // A guest cannot edit the queue: the menu's "Suggest to Room" asks the host instead of doing nothing.
        if p.isRoomGuest {
            hub.room.suggest(t)
            if let note = hub.room.suggestionNote { MusicToasts.shared.show(note) }
            return
        }
        switch MusicMenuLogic.playNextPlan(queue: p.queue.map(\.uid), index: p.index, uid: t.uid) {
        case .alreadyNext: MusicToasts.shared.show(Localized.string("Already playing next."))
        case .moveFrom(let i): p.moveToPlayNext(from: i)
        case .insert: p.playNext([t])
        }
    }

    static func startRadio(_ t: MusicTrack, hub: MusicHub) async {
        guard hub.canReplaceQueue() else { return }
        guard let provider = hub.registry.provider(id: t.providerID) as? any MusicMetadataProvider else {
            MusicToasts.shared.show(Localized.string("A radio is not available for this song."))
            return
        }
        let queueAtStart = hub.player.queueEpoch
        do {
            let hidden = MusicHiddenRecommendations.shared.set
            let more = try await provider.recommendations(seedTrackIDs: [t.id], limit: 25)
                .filter { $0.uid != t.uid && !hidden.hides($0) && !hub.library.isBlacklisted($0) }   // songs the person hid or blocked are not played back to them
            // Nothing came back: the queue is left as it is, not replaced by the one song.
            guard !more.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
            // Something else was started while the songs were being asked for: that stays, and the radio does not cut it off.
            guard hub.player.queueEpoch == queueAtStart, hub.canReplaceQueue() else { return }
            hub.player.play([t] + more, startAt: 0, sourceName: t.title, sourceID: t.uid, radioSeed: t.uid, isRadio: true)
        } catch { MusicToasts.shared.error(error) }
    }

    static func rate(_ t: MusicTrack, dislike: Bool) async {
        guard let m = YouTubeMusicAccountBuiltIns.manager, m.isSignedIn, let vid = t.videoID ?? Optional(t.id) else { return }
        do { try await m.writer.rate(dislike ? .dislike : .none, videoID: vid) }
        catch { MusicToasts.shared.error(error) }
    }

    static func toggleLibrary(_ t: MusicTrack) async {
        guard let m = YouTubeMusicAccountBuiltIns.manager, m.isSignedIn, let toggle = t.libraryToggle else { return }
        do {
            try await m.writer.setLibrary(toggle, add: !toggle.inLibrary)
            MusicToasts.shared.success(toggle.inLibrary ? Localized.string("Removed from library.") : Localized.string("Saved to library."))
        } catch { MusicToasts.shared.error(error) }
    }

    /// Takes the song out of the playlist first; only when that worked is it taken out of the queue (skipping first when it is the playing row).
    static func removeFromPlayingPlaylist(_ t: MusicTrack, playlist: UUID?, hub: MusicHub) {
        guard let id = playlist, let p = hub.library.playlist(id: id), let i = p.tracks.firstIndex(where: { $0.uid == t.uid }) else { return }
        let hint = hub.player.queue.firstIndex { $0.uid == t.uid } ?? 0
        hub.library.remove(at: IndexSet(integer: i), from: id)
        MusicToasts.shared.show(Localized.string("Removed from playlist."))
        let uids = hub.player.queue.map(\.uid)
        guard let row = MusicMenuLogic.resolveRow(queue: uids, uid: t.uid, near: hint) else { return }
        if hub.player.index == row { hub.player.next() }
        if let again = MusicMenuLogic.resolveRow(queue: hub.player.queue.map(\.uid), uid: t.uid, near: row) { hub.player.remove(at: again) }
    }
}

// MARK: - card menu (album, playlist, artist)

enum MusicCardItem: Hashable {
    case album(MusicAlbum), playlist(MusicPlaylist), artist(MusicArtist)

    var isLocal: Bool {
        switch self {
        case .album(let a): a.providerID == MusicStatsRules.localProviderID
        case .playlist(let p): p.providerID == MusicStatsRules.localProviderID
        case .artist(let a): a.providerID == MusicStatsRules.localProviderID
        }
    }
    var shareSubject: MusicShareSubject {
        switch self { case .album(let a): .album(a); case .playlist(let p): .playlist(p); case .artist(let a): .artist(a) }
    }
}

struct MusicCardMenuContent: View {
    let item: MusicCardItem
    let hub: MusicHub

    private var entity: MusicEntity {
        switch item { case .album(let a): .album(a); case .playlist(let p): .playlist(p); case .artist(let a): .artist(a) }
    }

    private var context: MusicMenuLogic.CardContext {
        let hasArtist = MusicEntityActions.artistRoute(entity, hub: hub) != nil
        switch item {
        case .album(let a): return MusicMenuLogic.CardContext(kind: .album, isLocal: item.isLocal, libraryState: hub.library.isSaved(a) ? .savedLocally : .notSaved, hasArtist: hasArtist)
        case .playlist: return MusicMenuLogic.CardContext(kind: .playlist, isLocal: item.isLocal)
        case .artist: return MusicMenuLogic.CardContext(kind: .artist, isLocal: item.isLocal)
        }
    }

    var body: some View {
        ForEach(Array(MusicMenuLogic.cardItems(context).enumerated()), id: \.offset) { _, i in row(i) }
    }

    @ViewBuilder private func row(_ i: MusicMenuLogic.CardItem) -> some View {
        switch i {
        case .playAndShuffle:
            Button("Play", systemImage: "play.fill") { Task { await MusicEntityActions.play(entity, hub: hub) } }.atlas("control.music.songMenusPlay")
            Button("Shuffle", systemImage: "shuffle") { Task { await MusicEntityActions.play(entity, shuffle: true, hub: hub) } }.atlas("control.music.songMenusShuffle")
        case .playArtist: Button("Play", systemImage: "play.fill") { Task { await MusicEntityActions.play(entity, hub: hub) } }.atlas("control.music.songMenusPlay")
        case .pin, .unpin: EmptyView()
        case .playNext: Button("Play Next", systemImage: "text.insert") { Task { await MusicEntityActions.playNext(entity, hub: hub) } }.atlas("control.music.songMenusPlayNext")
        case .addToQueue: Button("Add to Queue", systemImage: "text.append") { Task { await MusicEntityActions.addToQueue(entity, hub: hub) } }.atlas("control.music.songMenusAddToQueue")
        case .startRadio: Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { Task { await MusicEntityActions.startRadio(entity, hub: hub) } }.atlas("control.music.songMenusStartRadio")
        case .saveToPlaylist: Button("Add to Playlist…", systemImage: "music.note.list") { Task { await MusicEntityActions.addToPlaylist(entity, hub: hub) } }.atlas("control.music.songMenusAddToPlaylist")
        case .share: Button("Share…", systemImage: "square.and.arrow.up") { MusicEntityActions.share(entity, hub: hub) }.atlas("control.music.songMenusShare")
        case .goToArtist:
            if let a = MusicEntityActions.artistRoute(entity, hub: hub) { Button("Go to \(a.name)", systemImage: "person.crop.circle") { hub.open(.artist(a)) }.atlas("control.music.songMenusGoTo") }
        case .saveToLibrary, .removeFromLibrary:
            if case .album(let a) = item {
                Button(i == .saveToLibrary ? "Save to Your Library" : "Remove from Your Library", systemImage: i == .saveToLibrary ? "plus.circle" : "minus.circle") { MusicEntityActions.toggleSave(a, hub: hub) }.atlas("control.music.songMenusSaveToYourLibrary")
            }
        case .download: Button("Download", systemImage: "arrow.down.circle") { Task { await MusicCollectionActions.download(entity, hub: hub) } }.atlas("control.music.collectionMenuDownload")
        case .exportPlaylist: MusicCollectionActions.exportMenu(entity, hub: hub)
        case .removeDuplicates: Button("Remove Duplicates", systemImage: "square.on.square.dashed") { MusicCollectionActions.removeDuplicates(entity, hub: hub) }.atlas("control.music.collectionMenuRemoveDuplicates")
        case .editPlaylist: Button("Edit Playlist…", systemImage: "pencil") { MusicCollectionActions.edit(entity) }.atlas("control.music.collectionMenuEdit")
        case .manageArtwork: MusicManageArtworkMenu(subject: MusicArtworkSubject.derive(entity), onCoverSettings: MusicCollectionActions.isLocalPlaylist(entity) ? { MusicCollectionActions.edit(entity) } : nil)
        case .sortTracks: MusicCollectionActions.sortMenu(entity, hub: hub)
        case .selectMultiple: Button("Select Multiple", systemImage: "checkmark.circle") { MusicCollectionActions.select(entity, hub: hub) }.atlas("control.music.collectionMenuSelect")
        case .inLibrary: Button("In Your Library", systemImage: "checkmark.circle") {}.disabled(true).atlas("control.music.songMenusInYourLibrary")
        case .blockArtist:
            if case .artist(let a) = item {
                let b = hub.library.isBlacklisted(artist: MusicArtistRef(id: a.id, name: a.name))
                Button(b ? "Allow \(a.name) Again" : "Never Play \(a.name)", systemImage: "nosign") { MusicEntityActions.neverPlay(entity, hub: hub) }.atlas("control.music.songMenusAllowAgain")
            }
        }
    }
}

// MARK: - add to playlist

/// Two steps: pick playlists, then (only when some already hold some of the songs) choose what to do about duplicates.
struct MusicAddToPlaylistSheet: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    let dismiss: () -> Void
    @State private var chosen: Set<UUID> = []
    @State private var filter = ""
    @State private var step = 1
    @FocusState private var filterFocused: Bool
    @Environment(\.reddyAccent) private var accent

    private var targets: [LocalPlaylist] {
        let all = hub.library.playlists
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var chosenLists: [LocalPlaylist] { hub.library.playlists.filter { chosen.contains($0.id) } }
    private var plan: MusicMenuLogic.AddPlan { MusicMenuLogic.addPlan(tracks: tracks, chosen: chosenLists) }
    private var subtitle: String { tracks.count == 1 ? tracks[0].title : Localized.string("%@ songs", "\(tracks.count)") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                if step == 2 { Button { step = 1 } label: { Image(systemName: "chevron.left").frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget) }.buttonStyle(.plain).accessibilityLabel("Back").atlas("control.music.songMenusBack") }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Playlist").font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                    if step == 2 { Text(verbatim: subtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget) }
                    .buttonStyle(.plain).accessibilityLabel("Close").atlas("control.music.songMenusClose")
            }
            if step == 1 { pick } else { duplicates }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.sheetWidth)
        .onExitCommand { if step == 2 { step = 1 } else { dismiss() } }
        .onAppear { filterFocused = true }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button { newPlaylist() } label: { Label("New Playlist", systemImage: "plus").frame(maxWidth: .infinity, minHeight: MusicTokens.hitTarget, alignment: .leading) }
                .buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.songMenusNewPlaylist")
            if tracks.contains(where: { $0.providerID == MusicStatsRules.localProviderID }) {
                Text("Local files can only go to playlists on this Mac.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            if hub.library.playlists.count > 1 {
                TextField("Filter playlists", text: $filter).textFieldStyle(.roundedBorder).focused($filterFocused)
                    .onSubmit { if let f = targets.first { toggle(f.id) } }
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(targets) { p in
                        Button { toggle(p.id) } label: {
                            HStack(spacing: Spacing.md) {
                                Image(systemName: "music.note.list").frame(width: 28).foregroundStyle(ColorTokens.textSecondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: p.name).font(Typography.bodyMedium).lineLimit(1)
                                    Text(verbatim: Localized.plural(p.tracks.count, one: "%@ song", other: "%@ songs")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                                }
                                Spacer()
                                if chosen.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(accent) }
                            }
                            .padding(.horizontal, Spacing.sm).frame(minHeight: MusicTokens.hitTarget + 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverHighlight().accessibilityAddTraits(chosen.contains(p.id) ? .isSelected : []).atlas("control.music.songMenusMusicaddtoplaylistsheetpickButton")
                    }
                    if targets.isEmpty { Text(hub.library.playlists.isEmpty ? "You have no playlists yet." : "No playlist matches.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary).padding(Spacing.md) }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Text(verbatim: Localized.plural(chosen.count, one: "%@ playlist chosen", other: "%@ playlists chosen")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    .contentTransition(.numericText())
                Spacer()
                Button("Add") { if plan.needsDuplicateStep { step = 2 } else { commit(skipping: true) } }
                    .musicButton(.primary).atlas("control.music.addToPlaylist").disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var duplicates: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Some of these songs are already there.").font(Typography.body)
            ForEach(chosenLists.filter { (plan.duplicatesByPlaylist[$0.id] ?? 0) > 0 }) { p in
                Text(verbatim: "\(p.name): " + Localized.plural(plan.duplicatesByPlaylist[p.id] ?? 0, one: "%@ already there", other: "%@ already there")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            HStack {
                Spacer()
                Button(Localized.string("Add anyway (%@)", "\(plan.anywayAdds)")) { commit(skipping: false) }.musicButton(.secondary).atlas("control.music.songMenusAddAnyway")
                Button(Localized.string("Skip duplicates (%@)", "\(plan.skipAdds)")) { commit(skipping: true) }.musicButton(.primary).keyboardShortcut(.defaultAction).atlas("control.music.songMenusSkipDuplicates")
            }
        }
    }

    private func toggle(_ id: UUID) { if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) } }

    private func newPlaylist() {
        // One song is named after the song; songs that all come from one album are named after the album; anything else is "New Playlist".
        let albums = Set(tracks.compactMap { $0.album?.title })
        let name = tracks.count == 1 ? tracks[0].title : (albums.count == 1 && tracks.allSatisfy { $0.album != nil } ? (albums.first ?? "") : Localized.string("New Playlist"))
        let p = hub.library.createPlaylist(name: name, tracks: tracks)
        MusicToasts.shared.success(Localized.string("Added to %@.", p.name))
        dismiss()
    }

    /// Local playlists never hold a song twice, so skipping and adding anyway end the same way.
    private func commit(skipping: Bool) {
        let lists = chosenLists
        let before = plan
        var added = 0
        for p in lists { added += hub.library.add(tracks, to: p.id) }
        let dupes = before.duplicatesByPlaylist.values.reduce(0, +)
        MusicToasts.shared.show(MusicMenuLogic.addToast(added: added, duplicates: dupes, playlists: lists.map(\.name), songCount: tracks.count), kind: added == 0 ? .info : .success)
        dismiss()
    }
}

// MARK: - selection bar

struct MusicSelectionBar: View {
    let hub: MusicHub
    let selected: [MusicTrack]
    var total: Int
    var hiddenByFilter = 0
    var stillLoading = 0
    var onRemove: (() -> Void)?
    var selectAll: () -> Void
    var clear: () -> Void
    var exit: () -> Void
    @State private var bar = MusicMenuLogic.SelectionBar(selectedCount: 0)
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: bar.label).font(Typography.bodyMedium)
                if hiddenByFilter > 0 { Text(verbatim: Localized.string("%@ hidden by filter", "\(hiddenByFilter)")).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary) }
                if stillLoading > 0 { Text(verbatim: Localized.string("%@ still loading", "\(stillLoading)")).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary) }
            }
            Spacer(minLength: Spacing.md)
            let none = selected.isEmpty
            icon("play.fill", "Play", none) { hub.play(selected, at: 0) }
            icon("text.insert", "Play next", none) { hub.player.playNext(selected) }
            icon("text.append", "Add to queue", none) { hub.player.enqueue(selected) }
            icon("music.note.list", "Add to playlist", none) { MusicChromeState.shared.addToPlaylist = selected }
            icon(allLiked ? "heart.slash" : "heart", allLiked ? "Unlike" : "Like", none) { likeSelected() }
            icon("arrow.down.circle", "Download", none || downloadable.isEmpty) { downloadSelected() }
            if onRemove != nil {
                Button { if bar.pressRemove() { onRemove?() } } label: {
                    Label(bar.armedRemove ? Localized.string("Remove %@?", "\(selected.count)") : Localized.string("Remove"), systemImage: "minus.circle").font(Typography.captionMedium).foregroundStyle(ColorTokens.danger)
                        .frame(minHeight: MusicTokens.hitTarget)
                }
                .buttonStyle(.plain).disabled(none).accessibilityLabel(bar.armedRemove ? "Confirm remove from this playlist" : "Remove from this playlist").atlas("control.music.songMenusMusicselectionbarbodyButton")
            }
            if !hub.player.isRoomGuest {
                icon("repeat", "Play on repeat", none) {
                    // Repeat is set first: with it off, a short queue would let autoplay add songs before the replace.
                    hub.player.repeatMode = .all
                    hub.play(selected, at: 0)
                }
            }
            Button("Select all \(total)", action: selectAll).buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.songMenusSelectAll")
            Button("Clear", action: clear).buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).disabled(none).atlas("control.music.songMenusClear")
            Button("Cancel", action: exit).buttonStyle(.plain).font(Typography.captionMedium).frame(minHeight: MusicTokens.hitTarget).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel selection").atlas("control.music.songMenusCancelSelection")
        }
        .padding(.horizontal, Spacing.lg).frame(minHeight: 48)
        .glass(radius: MusicTokens.radiusPanel)
        .onAppear { bar.selectionChanged(to: selected.count) }
        .onChange(of: selected.map(\.uid)) { _, _ in bar.selectionChanged(to: selected.count) }
    }

    private var allLiked: Bool { !selected.isEmpty && selected.allSatisfy { hub.library.isLiked($0) } }
    private var downloadable: [MusicTrack] { selected.filter { $0.providerID != MusicStatsRules.localProviderID } }

    /// Likes every picked song; when they are all liked already it takes the likes back.
    private func likeSelected() {
        let unlike = allLiked
        var changed = 0
        for t in selected where hub.library.isLiked(t) == unlike { hub.library.toggleLike(t); changed += 1 }
        MusicToasts.shared.success(unlike ? Localized.plural(changed, one: "Removed %@ song from Liked Songs.", other: "Removed %@ songs from Liked Songs.")
                                          : Localized.plural(changed, one: "Added %@ song to Liked Songs.", other: "Added %@ songs to Liked Songs."))
    }

    private func downloadSelected() {
        let list = downloadable
        for t in list { hub.downloads.enqueue(t) }
        MusicToasts.shared.success(Localized.plural(list.count, one: "Downloading %@ song.", other: "Downloading %@ songs."))
    }

    private func icon(_ symbol: String, _ label: String, _ disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(MusicTokens.iconMedium).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(disabled).hoverHighlight().accessibilityLabel(LocalizedStringKey(label)).help(LocalizedStringKey(label)).atlas("control.music.songMenusMusicselectionbariconButton")
    }
}

/// Files to open the audio tools window with.
struct MusicConvertRequest: Identifiable { var id = UUID(); var urls: [URL] }
