import Foundation
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import MediaPlayer

/// What macOS needs to know about the current playback: the title, how far along it is, and whether it can be skipped.
/// Built as plain values first, so the rules (what is shown, which keys do something) are testable without the system.
struct NowPlayingSnapshot: Equatable {
    var title: String
    var subtitle: String?
    var isLive: Bool
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval?
    var rate: Double
    var hasQueue: Bool           // more than one channel to skip between
    var hasNextEpisode: Bool
    var artworkURL: String?

    /// Keys a media remote may use, for this kind of content.
    struct Commands: Equatable { var play = true, pause = true, toggle = true, next = false, previous = false, skip = false, seek = false }

    var commands: Commands {
        var c = Commands()
        if isLive { c.next = hasQueue; c.previous = hasQueue }
        else { c.skip = true; c.seek = (duration ?? 0) > 0; c.next = hasNextEpisode; c.previous = true }
        return c
    }

    var info: [String: Any] {
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? max(rate, 0.1) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let subtitle, !subtitle.isEmpty { d[MPMediaItemPropertyArtist] = subtitle }
        if !isLive {
            d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position)
            if let duration, duration > 0 { d[MPMediaItemPropertyPlaybackDuration] = duration }
        }
        return d
    }
}

/// Connects playback to the macOS media keys, Control Centre's Now Playing and the lock screen. Media keys go to whichever app is
/// the current "Now Playing" app, so REDDY registers its commands and publishes what it is playing.
@MainActor
final class NowPlayingService: RemoteCommandHandling {
    private weak var playback: PlaybackCoordinator?
    private let artwork: ArtworkService?
    private var task: Task<Void, Never>?
    private var last: NowPlayingSnapshot?
    private var artworkItem: MPMediaItemArtwork?
    private var artworkFor: String?
    private let router: MediaCommandRouter
    private var lastCommands: NowPlayingSnapshot.Commands?

    /// True while App Lock covers the app: the title and picture are hidden, as for a private watch, and the media keys and the system's playback controls do nothing.
    var isLocked: () -> Bool = { false }

    init(playback: PlaybackCoordinator, artwork: ArtworkService?, router: MediaCommandRouter = .shared) {
        self.playback = playback; self.artwork = artwork; self.router = router
        router.register(self, for: .nativePlayer)          // the one registration with the system lives in the router; commands reach this player only while it owns the audio
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    deinit { task?.cancel() }

    func snapshot() -> NowPlayingSnapshot? {
        guard let p = playback, p.current != nil, p.state.isActive else { return nil }
        // A private watch shows no title or picture on the lock screen, in Control Centre or on a paired device.
        let hidden = p.isPrivate || isLocked()
        return NowPlayingSnapshot(title: hidden ? "Private viewing" : p.title, subtitle: hidden ? nil : (p.subtitle ?? p.currentChannel?.categoryName), isLive: p.isLive, isPlaying: p.state == .playing,
                                  position: p.position, duration: p.duration, rate: p.rate, hasQueue: p.queue.count > 1,
                                  hasNextEpisode: p.upNext != nil, artworkURL: hidden ? nil : p.current?.artworkURL)
    }

    /// Publishes changes only; the system extrapolates the elapsed time between updates. Published only while the library player owns the audio.
    func refresh() {
        guard let s = snapshot() else {
            if last != nil { router.ownerStopped(.nativePlayer); last = nil; lastCommands = nil; artworkItem = nil; artworkFor = nil }
            return
        }
        // enabled-state is event driven: only a change of what the keys may do is told to the router
        if lastCommands != s.commands { lastCommands = s.commands; router.supportChanged(for: .nativePlayer) }
        let drift = last.map { abs(($0.position + (($0.isPlaying ? $0.rate : 0) * 1)) - s.position) } ?? 99
        var changed = last.map { var a = $0, b = s; a.position = 0; b.position = 0; return a != b } ?? true
        if !s.isLive, drift > 2.5 { changed = true }
        guard changed else { last = s; return }
        var info = s.info
        if let artworkItem, artworkFor == s.artworkURL { info[MPMediaItemPropertyArtwork] = artworkItem }
        guard router.publish(info, playing: s.isPlaying, from: .nativePlayer) else { return }          // not the owner: nothing is published, and it is tried again next time
        if artworkFor != s.artworkURL { loadArtwork(s.artworkURL) }
        last = s
    }

    private func loadArtwork(_ url: String?) {
        artworkFor = url; artworkItem = nil
        guard let url, !url.isEmpty, let artwork else { return }
        Task { [weak self] in
            guard let image = await artwork.image(url, kind: .poster) else { return }
            let item = Self.makeArtwork(image)
            await MainActor.run {
                guard let self, self.artworkFor == url, let s = self.last else { return }
                self.artworkItem = item
                var info = s.info
                info[MPMediaItemPropertyArtwork] = item
                self.router.publish(info, playing: s.isPlaying, from: .nativePlayer)
            }
        }
    }

    // MARK: artwork

    private struct ImageBox: @unchecked Sendable { let image: PlatformImage }

    /// macOS calls an artwork's image handler on its own background queue. The handler therefore must not be tied to the main
    /// actor: a closure written inside this main-actor class would be, and Swift stops the app when the system calls it from
    /// another thread. Built in a nonisolated function so it is an ordinary thread-safe closure.
    nonisolated static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        #if canImport(AppKit)
        let box = ImageBox(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        #else
        let box = ImageBox(image: UIImage(cgImage: image))
        #endif
        return MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
    }

    // MARK: commands (RemoteCommandHandling; the router owns the registration)

    var remoteSupport: RemoteCommandSupport {
        let c = snapshot()?.commands ?? NowPlayingSnapshot.Commands()
        var set: Set<RemoteCommandKind> = []
        if c.play { set.insert(.play) }; if c.pause { set.insert(.pause) }; if c.toggle { set.insert(.toggle) }
        if c.next { set.insert(.next) }; if c.previous { set.insert(.previous) }
        if c.skip { set.formUnion([.skipForward, .skipBackward]) }; if c.seek { set.insert(.seek) }
        return RemoteCommandSupport(enabled: set, skipForward: 15, skipBackward: 15)
    }

    func remoteOwnershipChanged(isOwner: Bool) {
        if isOwner { last = nil; refresh() }          // it owns the audio again: publish what is playing
        else { last = nil; artworkItem = nil; artworkFor = nil }
    }

    func handleRemote(_ event: RemoteCommandEvent) -> RemoteCommandResult {
        guard let p = playback, p.current != nil else { return .noActionable }
        if isLocked() { return .failed }          // locked: media keys and the system's controls do nothing
        switch event.kind {
        case .play: p.resume()
        case .pause: p.pause()
        case .toggle: p.togglePause()
        case .next: p.isLive ? p.nextChannel() : p.playNextEpisode()
        case .previous: p.isLive ? p.previousChannelInList() : p.seek(to: 0)
        case .skipForward: p.seek(by: event.interval ?? 15)
        case .skipBackward: p.seek(by: -(event.interval ?? 15))
        case .seek: if let t = event.position { p.seek(to: t) }
        }
        return .success
    }
}
