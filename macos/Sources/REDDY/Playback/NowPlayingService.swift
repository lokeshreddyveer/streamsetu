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
final class NowPlayingService {
    private weak var playback: PlaybackCoordinator?
    private let artwork: ArtworkService?
    private var task: Task<Void, Never>?
    private var last: NowPlayingSnapshot?
    private var artworkItem: MPMediaItemArtwork?
    private var artworkFor: String?
    private var targets: [(MPRemoteCommand, Any)] = []

    init(playback: PlaybackCoordinator, artwork: ArtworkService?) {
        self.playback = playback; self.artwork = artwork
        registerCommands()
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
        return NowPlayingSnapshot(title: p.isPrivate ? "Private viewing" : p.title, subtitle: p.isPrivate ? nil : (p.subtitle ?? p.currentChannel?.categoryName), isLive: p.isLive, isPlaying: p.state == .playing,
                                  position: p.position, duration: p.duration, rate: p.rate, hasQueue: p.queue.count > 1,
                                  hasNextEpisode: p.upNext != nil, artworkURL: p.isPrivate ? nil : p.current?.artworkURL)
    }

    /// Publishes changes only; the system extrapolates the elapsed time between updates.
    func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let s = snapshot() else {
            if last != nil { center.nowPlayingInfo = nil; center.playbackState = .stopped; last = nil; artworkItem = nil; artworkFor = nil }
            return
        }
        let drift = last.map { abs(($0.position + (($0.isPlaying ? $0.rate : 0) * 1)) - s.position) } ?? 99
        var changed = last.map { var a = $0, b = s; a.position = 0; b.position = 0; return a != b } ?? true
        if !s.isLive, drift > 2.5 { changed = true }
        guard changed else { last = s; return }
        var info = s.info
        if let artworkItem, artworkFor == s.artworkURL { info[MPMediaItemPropertyArtwork] = artworkItem }
        center.nowPlayingInfo = info
        center.playbackState = s.isPlaying ? .playing : .paused
        applyCommandAvailability(s.commands)
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
                guard let self, self.artworkFor == url else { return }
                self.artworkItem = item
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = item
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

    // MARK: commands

    private func applyCommandAvailability(_ c: NowPlayingSnapshot.Commands) {
        let r = MPRemoteCommandCenter.shared()
        r.playCommand.isEnabled = c.play; r.pauseCommand.isEnabled = c.pause; r.togglePlayPauseCommand.isEnabled = c.toggle
        r.nextTrackCommand.isEnabled = c.next; r.previousTrackCommand.isEnabled = c.previous
        r.skipForwardCommand.isEnabled = c.skip; r.skipBackwardCommand.isEnabled = c.skip
        r.changePlaybackPositionCommand.isEnabled = c.seek
    }

    private func registerCommands() {
        let r = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping @MainActor (PlaybackCoordinator, MPRemoteCommandEvent) -> Void) {
            let t = cmd.addTarget { [weak self] event in
                guard let p = self?.playback, p.current != nil else { return .noActionableNowPlayingItem }
                MainActor.assumeIsolated { handler(p, event) }
                return .success
            }
            targets.append((cmd, t))
        }
        add(r.playCommand) { p, _ in p.resume() }
        add(r.pauseCommand) { p, _ in p.pause() }
        add(r.togglePlayPauseCommand) { p, _ in p.togglePause() }
        add(r.nextTrackCommand) { p, _ in p.isLive ? p.nextChannel() : p.playNextEpisode() }
        add(r.previousTrackCommand) { p, _ in p.isLive ? p.previousChannelInList() : p.seek(to: 0) }
        r.skipForwardCommand.preferredIntervals = [15]; r.skipBackwardCommand.preferredIntervals = [15]
        add(r.skipForwardCommand) { p, e in p.seek(by: (e as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
        add(r.skipBackwardCommand) { p, e in p.seek(by: -((e as? MPSkipIntervalCommandEvent)?.interval ?? 15)) }
        add(r.changePlaybackPositionCommand) { p, e in if let e = e as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) } }
        applyCommandAvailability(NowPlayingSnapshot.Commands(play: true, pause: true, toggle: true))
    }
}
