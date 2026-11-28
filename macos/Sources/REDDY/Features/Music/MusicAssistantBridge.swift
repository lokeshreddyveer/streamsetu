#if os(macOS)
import Foundation

/// Connects Setu to Music: the assistant reads what is playing and the current Music screen, searches the Music source, and carries out controls on the one player (the same
/// `MusicPlayer` the bar, the panel and the system media keys use; there is no second player). Registered by the Music shell when it opens.
@MainActor
final class MusicAssistantBridge: MusicAssistantHandling {
    private weak var hub: MusicHub?
    /// Brings the Music destination to the front (the shell supplies it: the assistant may be asked from any tab).
    private let showMusic: () -> Void

    init(hub: MusicHub, showMusic: @escaping () -> Void) { self.hub = hub; self.showMusic = showMusic }

    func summary() -> String? {
        guard let hub else { return nil }
        let screen = hub.nav.section.title
        guard let t = hub.player.current else { return "Music is open on \(screen); nothing is playing in Music." }
        return "Music (\(screen)): \(describe(t))"
    }

    func nowPlaying() -> String {
        guard let hub, let t = hub.player.current else { return "Nothing is playing in Music." }
        return describe(t) + ". Queue: \(hub.player.queue.count) song(s)."
    }

    private func describe(_ t: MusicTrack) -> String {
        guard let hub else { return t.title }
        var s = "“\(t.title)” by \(t.artistLine)" + (t.album.map { ", from \($0.title)" } ?? "")
        s += hub.player.isPlaying ? " [playing]" : " [paused]"
        s += hub.player.shuffle ? ", shuffle on" : ", shuffle off"
        s += ", repeat \(hub.player.repeatMode.rawValue)"
        return s
    }

    func search(_ query: String) async -> String {
        guard let hub, let p = hub.registry.activeMetadata else { return "No Music source is switched on." }
        var lines: [String] = []
        if let songs = try? await p.searchTracks(query, page: nil).items { lines += songs.prefix(6).map { "song: \($0.title) — \($0.artistLine)" } }
        if let artists = try? await p.searchArtists(query, page: nil).items { lines += artists.prefix(3).map { "artist: \($0.name)" } }
        if let albums = try? await p.searchAlbums(query, page: nil).items { lines += albums.prefix(3).map { "album: \($0.title) — \($0.artists.first?.name ?? "")" } }
        return lines.isEmpty ? "Music found nothing for “\(query)”." : lines.joined(separator: "\n")
    }

    func run(_ action: MusicAssistantAction) async -> AssistantOutcome {
        guard let hub else { return .failed("Music is not open.") }
        switch action {
        case .control(let a): return control(a, hub: hub)
        case .play(let query, let kind, let shuffle): return await play(query: query, kind: kind, shuffle: shuffle, hub: hub)
        case .radio(let query):
            if let query, !query.isEmpty {
                guard let seed = await firstTrack(for: query, hub: hub) else { return .failed("Music found no song for “\(query)”.") }
                await MusicQueueActions.startRadio(seed, hub: hub); return .done("Started a radio from “\(seed.title)”.")
            }
            guard let cur = hub.player.current else { return .failed("Nothing is playing to start a radio from.") }
            await MusicQueueActions.startRadio(cur, hub: hub); return .done("Started a radio from “\(cur.title)”.")
        case .open(let id):
            guard let s = Self.section(for: id) else { return .failed("I do not know a Music screen called “\(id)”.") }
            showMusic(); hub.expandedPlayer = false; if s == .library { hub.openLibrary() } else { hub.nav.select(s) }; return .done("Opened \(s.title).")
        case .country(let c):
            let code = c.lowercased() == "worldwide" ? "" : c.lowercased()
            guard MusicRegionChoice.shared.set(code) else { return .done("Already showing that.") }
            return .done("Showing " + MusicDiscoveryRegion.name(code) + ".")
        }
    }

    private func control(_ a: String, hub: MusicHub) -> AssistantOutcome {
        let p = hub.player
        func needsSong() -> AssistantOutcome? { p.current == nil ? .failed("Nothing is playing in Music.") : nil }
        // A guest follows the room host: the same transport lock the buttons and shortcuts honour.
        let lockedActions: Set<String> = ["play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "repeat_off", "repeat_all", "repeat_one"]
        if lockedActions.contains(a), hub.room.controlsLocked { return .failed("This device is following the room host.") }
        switch a {
        case "play": if let f = needsSong() { return f }; if !p.isPlaying { p.resume() }; return .done("Playing.")
        case "pause": if let f = needsSong() { return f }; p.pause(); return .done("Paused.")
        case "next": if let f = needsSong() { return f }; p.next(); return .done("Next song.")
        case "previous": if let f = needsSong() { return f }; p.previous(); return .done("Previous song.")
        case "shuffle_on": p.shuffle = true; return .done("Shuffle is on.")
        case "shuffle_off": p.shuffle = false; return .done("Shuffle is off.")
        case "repeat_off": p.repeatMode = .off; return .done("Repeat is off.")
        case "repeat_all": p.repeatMode = .all; return .done("Repeating the queue.")
        case "repeat_one": p.repeatMode = .one; return .done("Repeating this song.")
        case "like", "unlike":
            guard let t = p.current else { return .failed("Nothing is playing in Music.") }
            let liked = hub.library.isLiked(t)
            if (a == "like") != liked { hub.library.toggleLike(t) }
            return .done(a == "like" ? "Liked “\(t.title)”." : "Removed the like from “\(t.title)”.")
        case "volume_up": p.volume = min(1, p.volume + 0.1); return .done("Volume up.")
        case "volume_down": p.volume = max(0, p.volume - 0.1); return .done("Volume down.")
        case "mute": if p.volume > 0 { p.toggleMute() }; return .done("Muted.")
        case "unmute": if p.volume == 0 { p.toggleMute() }; return .done("Unmuted.")
        case "show_lyrics": if let f = needsSong() { return f }; showMusic(); MusicContextPanelState.shared.showPanel(.lyrics); return .done("Showing the lyrics.")
        case "show_queue": if let f = needsSong() { return f }; showMusic(); MusicContextPanelState.shared.showPanel(.queue); return .done("Showing the queue.")
        default: return .failed("I cannot do “\(a)” in Music.")
        }
    }

    private func firstTrack(for query: String, hub: MusicHub) async -> MusicTrack? {
        guard let p = hub.registry.activeMetadata else { return nil }
        return (try? await p.searchTracks(query, page: nil))?.items.first { !hub.library.isBlacklisted($0) }
    }

    private func play(query: String, kind: String, shuffle: Bool, hub: MusicHub) async -> AssistantOutcome {
        guard let p = hub.registry.activeMetadata else { return .failed("No Music source is switched on.") }
        var tracks: [MusicTrack] = []
        switch kind {
        case "artist":
            if let a = (try? await p.searchArtists(query, page: nil))?.items.first { tracks = (try? await p.artistTopTracks(id: a.id)) ?? [] }
        case "album":
            if let al = (try? await p.searchAlbums(query, page: nil))?.items.first { tracks = (try? await p.albumTracks(id: al.id, page: nil))?.items ?? [] }
        case "playlist":
            if let pl = (try? await p.searchPlaylists(query, page: nil))?.items.first { tracks = (try? await p.playlistTracks(id: pl.id, page: nil))?.items ?? [] }
        default:
            tracks = (try? await p.searchTracks(query, page: nil))?.items ?? []
        }
        tracks = tracks.filter { !hub.library.isBlacklisted($0) }
        guard !tracks.isEmpty else { return .failed("Music found nothing to play for “\(query)”.") }
        showMusic()
        if shuffle { hub.playShuffled(tracks, sourceName: query) } else { hub.play(tracks, at: 0, sourceName: query) }
        return .done((shuffle ? "Shuffling " : "Playing ") + "“\(query)” in Music.")
    }

    static func section(for id: String) -> MusicSection? {
        switch id {
        case "listen_now": .home
        case "explore": .explore
        case "recently_added": .recentlyAdded
        case "search": .search
        case "library": .library
        case "radio": .radio
        case "downloads": .downloads
        case "devices": .devices
        case "listen_together": .room
        case "settings": .settings
        default: nil
        }
    }
}
#endif
